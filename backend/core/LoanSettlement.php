<?php
/**
 * Closing a loan early, for the money that is actually fair today.
 *
 * A borrower who has paid five of ten weekly instalments and wants to finish
 * now should not pay for the five weeks she is not going to use. Until this
 * existed there was no way to do it except to work the figure out by hand and
 * edit rows, which is exactly the sort of arithmetic that goes wrong quietly.
 *
 * ── The rule ──────────────────────────────────────────────────────────────
 *
 * Interest is earned in proportion to the instalments actually paid. Five of
 * ten instalments on a loan charging ₹2,000 of interest has earned ₹1,000;
 * the other ₹1,000 is unearned and comes off the closing figure.
 *
 * Both interest regimes fall out of one line, because they differ only in
 * *when* the interest was taken:
 *
 *     settlement = principal + interestEarned − interestAlreadyTaken − paid
 *
 *   weekly, 100-day daily — interest held back at disbursement, so
 *   `interestAlreadyTaken` is the whole of it and the unearned part comes
 *   back as a discount on what is left to pay:
 *
 *       ₹20,000 over 10 weeks, 10% held back → she received ₹18,000
 *       paid 5 × ₹2,000 = ₹10,000
 *       20,000 + 1,000 − 2,000 − 10,000      = ₹9,000 to close
 *       she repays ₹19,000 for ₹18,000       = ₹1,000 interest, for 5 weeks
 *
 *   monthly, 60-day daily — interest added on top, so nothing has been taken
 *   in advance and the unearned part is simply never charged:
 *
 *       ₹10,000 over 5 months, ₹1,000 interest → she received ₹10,000
 *       paid 2 × ₹2,200 = ₹4,400
 *       10,000 + 400 − 0 − 4,400             = ₹6,000 to close
 *       she repays ₹10,400 for ₹10,000       = ₹400 interest, for 2 months
 *
 * Note what survives in both: `disbursed = total_repayment − total_interest`.
 * That invariant is what the Account Book and Interest Revenue are built on,
 * so settling a loan rewrites both figures rather than leaving the loan
 * claiming interest it gave back.
 *
 * An outstanding penalty is added on top. A penalty is earned by a missed
 * week that has already happened, so closing early does not undo it.
 */
class LoanSettlement
{
    private static function r2(float $n): float
    {
        return round($n, 2);
    }

    /**
     * What it would cost to close this loan today, and how that was reached.
     *
     * Pure arithmetic, no writes — the screen shows this before anyone
     * commits to it, and `settle()` recomputes it rather than trusting a
     * figure that came back from a browser.
     *
     * @return array<string,mixed>
     */
    public static function quote(string $loanId): array
    {
        $pdo = Database::pdo();

        $stmt = $pdo->prepare('SELECT * FROM `loans` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$loanId]);
        $loan = $stmt->fetch();
        if (!$loan) {
            json_error('Loan not found', 404);
        }

        // Derived figures first: a loan written before `total_repayment` was
        // stored would otherwise settle against a zero and give away the farm.
        $loan = Loan::deriveTotals($loan) + $loan;

        $status = strtolower(trim((string)($loan['status'] ?? '')));
        if ($status === 'closed') {
            json_error('This loan is already closed', 409);
        }
        if ($status === 'pending') {
            json_error('This loan has not been disbursed yet, so there is nothing to settle', 409);
        }

        $principal = self::r2((float)($loan['loan_amount'] ?? 0));
        $interest  = self::r2((float)($loan['total_interest'] ?? 0));
        $repayable = self::r2((float)($loan['total_repayment'] ?? 0));
        if ($repayable <= 0) $repayable = $principal;

        // What has actually come off the loan. Counted from the receipts
        // rather than from `outstanding_balance`, because the receipts are the
        // record and the balance is a cache of them — but net of any late fee
        // riding on the same receipt, because a fine is not a repayment. A
        // settlement that counted the fees as repayment would hand the
        // borrower her own penalties back as a discount on closing.
        $stmt = $pdo->prepare(
            'SELECT COALESCE(SUM(GREATEST(`collection_amount` - GREATEST(COALESCE(`penalty_amount`, 0), 0), 0)), 0)
               FROM `collections`
              WHERE `loan_id` = ? AND `delflag` = 0'
        );
        $stmt->execute([$loanId]);
        $paid = self::r2((float)$stmt->fetchColumn());

        // The schedule says how many instalments there are and how far along
        // she is. Falling back to the loan's own duration covers a loan whose
        // schedule was never generated.
        $stmt = $pdo->prepare(
            'SELECT COUNT(*) c, COALESCE(SUM(`emi_amount`), 0) t, COALESCE(SUM(`penalty_amount`), 0) p
               FROM `repayment_schedule` WHERE `loan_id` = ? AND `delflag` = 0'
        );
        $stmt->execute([$loanId]);
        $sched = $stmt->fetch() ?: ['c' => 0, 't' => 0, 'p' => 0];

        $total = (int)($sched['c'] ?? 0);
        if ($total <= 0) $total = (int)($loan['loan_duration'] ?? 0);
        if ($total <= 0) $total = 1;

        $emi = self::r2((float)($loan['emi'] ?? 0));
        if ($emi <= 0) $emi = self::r2($repayable / $total);

        // Instalments paid, counted as money rather than as rows: a half-paid
        // instalment has earned half an instalment's interest, and counting
        // whole rows only would hand that half back.
        $paidInstalments = $emi > 0 ? min((float)$total, $paid / $emi) : 0.0;
        $paidInstalments = max(0.0, round($paidInstalments, 4));

        $upfront = self::isUpfrontPlan($loan);
        $earned  = self::r2($interest * ($paidInstalments / $total));
        $taken   = $upfront ? $interest : 0.0;
        $rebate  = self::r2(max(0.0, $interest - $earned));

        $penalty = self::r2((float)($loan['penalty_amount'] ?? 0));
        if ($penalty <= 0) $penalty = self::r2((float)($sched['p'] ?? 0));

        $amount = self::r2($principal + $earned - $taken - $paid + $penalty);
        // An overpaid loan settles at nothing rather than at a refund. Money
        // going back out of the door is a different decision from closing a
        // loan, and it is not one this screen should make by accident.
        $amount = max(0.0, $amount);

        // What the borrower was handed on day one never changes, whatever is
        // agreed today — it is the anchor the rewritten totals hang off.
        $disbursed = self::r2(Loan::disbursedAmount($loan));

        return [
            'loan_id'            => $loanId,
            'loan_number'        => $loan['loan_number'] ?? '',
            'customer_id'        => $loan['customer_id'] ?? null,
            'customer_name'      => $loan['customer_name'] ?? '',
            'loan_type'          => $loan['loan_type'] ?? '',
            'interest_upfront'   => $upfront,
            'principal'          => $principal,
            'disbursed'          => $disbursed,
            'interest_total'     => $interest,
            'total_repayment'    => $repayable,
            'instalments_total'  => $total,
            'instalments_paid'   => $paidInstalments,
            'emi'                => $emi,
            'paid_so_far'        => $paid,
            'outstanding'        => self::r2(max(0.0, $repayable - $paid)),
            'interest_earned'    => $earned,
            'interest_taken'     => self::r2($taken),
            'interest_rebate'    => $rebate,
            'penalty'            => $penalty,
            'settlement_amount'  => $amount,
            // What closing at this figure means for the loan's own totals,
            // so the caller can show the borrower what she will have paid.
            'repayment_after'    => self::r2($paid + $amount),
            'interest_after'     => self::r2(max(0.0, $paid + $amount - $disbursed)),
        ];
    }

    /**
     * Close the loan: take the money, rewrite the totals, end the schedule.
     *
     * Four writes in one transaction, because a settlement half-applied is
     * worse than one not applied at all — a receipt with no closure leaves the
     * borrower paying a loan she has settled.
     *
     *   1. a collection, so the money appears in the book and the day's cash
     *   2. the unpaid tail of the schedule removed, and one final instalment
     *      written in its place for the amount actually taken
     *   3. `total_repayment` and `total_interest` cut to what was really paid,
     *      so Interest Revenue stops counting interest that was given back
     *   4. the usual recalculation, which finds nothing outstanding and closes
     *
     * @param array{loan_id:string,amount?:mixed,payment_method?:string,
     *              collection_date?:string,reason?:string,notes?:string} $in
     */
    public static function settle(array $in, array $actor): array
    {
        $loanId = trim((string)($in['loan_id'] ?? ''));
        if ($loanId === '') {
            json_error('Which loan?', 400);
        }

        // Recomputed here rather than trusted from the request: the browser
        // showed a figure, but the figure that matters is the one the rule
        // produces at the moment the money is taken.
        $q = self::quote($loanId);

        $calculated = (float)$q['settlement_amount'];
        $amount     = $calculated;
        $reason     = trim((string)($in['reason'] ?? ''));
        $overridden = false;
        $interestSet = null;

        /**
         * Setting the interest instead of the closing figure.
         *
         * The rule earns interest in proportion to the instalments paid, which
         * means a borrower who has paid none owes none — she closes for exactly
         * what she was handed and the lender makes nothing. That is what the
         * rule says and it is sometimes not what the business wants, so the
         * interest itself can be set and the closing figure follows from it:
         *
         *     amount = principal + interest − interestAlreadyTaken − paid + penalty
         *
         * Computed here rather than in the browser so one piece of arithmetic
         * decides the money. `interest` wins over `amount` when both arrive,
         * because it is the more specific statement of intent.
         */
        if (array_key_exists('interest', $in) && $in['interest'] !== null && $in['interest'] !== '') {
            $wanted = round((float)$in['interest'], 2);
            if ($wanted < 0) {
                json_error('The interest cannot be negative', 422);
            }
            $fromInterest = self::r2(
                (float)$q['principal'] + $wanted - (float)$q['interest_taken']
                - (float)$q['paid_so_far'] + (float)$q['penalty']
            );
            $fromInterest = max(0.0, $fromInterest);
            if (abs($fromInterest - $calculated) >= 0.01) {
                if (($actor['role'] ?? '') !== 'admin') {
                    json_error('Only an admin can change the interest', 403);
                }
                if ($reason === '') {
                    json_error('A reason is required to close for a different amount', 422);
                }
                $amount      = $fromInterest;
                $interestSet = $wanted;
                $overridden  = true;
            }
            // Said explicitly and matching the rule: nothing to override.
            $in['amount'] = null;
        }

        if (array_key_exists('amount', $in) && $in['amount'] !== null && $in['amount'] !== '') {
            $asked = round((float)$in['amount'], 2);
            if (abs($asked - $calculated) >= 0.01) {
                // Only an admin may close a loan for something other than what
                // it is owed, and only with a reason — the account book has to
                // be able to say why it differed.
                if (($actor['role'] ?? '') !== 'admin') {
                    json_error('Only an admin can change the closing amount', 403);
                }
                if ($reason === '') {
                    json_error('A reason is required to close for a different amount', 422);
                }
                if ($asked < 0) {
                    json_error('The closing amount cannot be negative', 422);
                }
                $amount     = $asked;
                $overridden = true;
            }
        }

        $method = strtolower(trim((string)($in['payment_method'] ?? 'cash')));
        if (!in_array($method, ['cash', 'upi', 'card', 'bank', 'cheque'], true)) {
            $method = 'cash';
        }
        $date = trim((string)($in['collection_date'] ?? ''));
        if ($date === '' || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $date)) {
            $date = date('Y-m-d');
        }

        $note = 'Loan settled — closed early after '
              . self::describeInstalments((float)$q['instalments_paid'], (int)$q['instalments_total'])
              . '. Interest charged ' . number_format((float)$q['interest_earned'], 2)
              . ' of ' . number_format((float)$q['interest_total'], 2);
        if ((float)$q['interest_rebate'] > 0) {
            $note .= ' (rebate ' . number_format((float)$q['interest_rebate'], 2) . ')';
        }
        if ($overridden) {
            $note .= '. Calculated ' . number_format($calculated, 2)
                   . ', closed at ' . number_format($amount, 2);
            // Which of the two the admin actually set, because "interest fixed
            // at ₹3,000" and "closing figure fixed at ₹20,000" are the same
            // money and different decisions.
            if ($interestSet !== null) {
                $note .= ' (interest set to ' . number_format($interestSet, 2) . ')';
            }
            $note .= ' — ' . $reason;
        }
        $extra = trim((string)($in['notes'] ?? ''));
        if ($extra !== '') $note .= '. ' . $extra;

        $pdo = Database::pdo();
        $pdo->beginTransaction();
        try {
            // 1. The receipt.
            $receiptId = uuid4();
            $pdo->prepare(
                'INSERT INTO `collections`
                    (`id`, `receipt_number`, `loan_id`, `customer_id`, `customer_name`,
                     `loan_number`, `collection_amount`, `payment_method`, `collection_date`,
                     `agent_id`, `agent_name`, `notes`)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?)'
            )->execute([
                $receiptId, self::nextReceiptNumber($pdo), $loanId, $q['customer_id'],
                $q['customer_name'], $q['loan_number'], $amount, $method, $date,
                $actor['sub'] ?? null, $actor['full_name'] ?? ($actor['email'] ?? null), $note,
            ]);

            // 2. The tail of the schedule she is no longer going to pay. Rows
            //    that took money stay — they are the history. One final row
            //    stands for the settlement itself, so the schedule screen reads
            //    as what happened rather than as a plan that was abandoned.
            $pdo->prepare(
                'UPDATE `repayment_schedule`
                    SET `delflag` = 1, `deleted_at` = NOW(), `deleted_by` = ?
                  WHERE `loan_id` = ? AND `delflag` = 0 AND COALESCE(`paid_amount`, 0) <= 0'
            )->execute([$actor['sub'] ?? null, $loanId]);

            // Over every row, including the ones just soft-deleted: there is a
            // unique index on (loan_id, installment_no), and a deleted row
            // still occupies its number. Counting only live rows produced a
            // settlement row numbered 6 colliding with the deleted 6.
            $stmt = $pdo->prepare(
                'SELECT COALESCE(MAX(`installment_no`), 0) FROM `repayment_schedule`
                  WHERE `loan_id` = ?'
            );
            $stmt->execute([$loanId]);
            $nextNo = (int)$stmt->fetchColumn() + 1;

            // What the kept rows still want, so the final row asks for exactly
            // the remainder and the cascade lands on zero.
            $stmt = $pdo->prepare(
                'SELECT COALESCE(SUM(`emi_amount`), 0) FROM `repayment_schedule`
                  WHERE `loan_id` = ? AND `delflag` = 0'
            );
            $stmt->execute([$loanId]);
            $kept = self::r2((float)$stmt->fetchColumn());

            $finalDue = self::r2(max(0.0, (float)$q['paid_so_far'] + $amount - $kept));
            if ($finalDue > 0) {
                $pdo->prepare(
                    'INSERT INTO `repayment_schedule`
                        (`id`, `loan_id`, `installment_no`, `due_date`, `emi_amount`,
                         `paid_amount`, `balance`, `status`)
                     VALUES (?,?,?,?,?,?,?,?)'
                )->execute([uuid4(), $loanId, $nextNo, $date, $finalDue, 0, $finalDue, 'pending']);
            }

            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            throw $e;
        }

        // 3. Outside the transaction, like every other write path here: the
        //    cascade re-reads the receipts and the schedule and finds nothing
        //    left owing, which is what closes the loan.
        LoanRecalc::sync($loanId);

        // 4. The loan's own totals, written after the cascade rather than
        //    before it. `disbursed` is fixed at origination, so interest is
        //    whatever she ends up paying above it — which is how an admin's
        //    waiver shows up as less interest rather than as a loan that
        //    mysteriously lent less.
        //
        //    The ordering matters: the sync backfills any total that reads as
        //    zero, and a loan settled at exactly what it lent has a genuinely
        //    zero interest. Writing first meant the backfill put the original
        //    interest straight back. Writing afterwards settles it, and the
        //    loan is closed by then, which is what keeps later syncs off it.
        $repayAfter    = self::r2((float)$q['paid_so_far'] + $amount);
        $interestAfter = self::r2(max(0.0, $repayAfter - (float)$q['disbursed']));
        $pdo->prepare(
            'UPDATE `loans` SET `total_repayment` = ?, `total_interest` = ? WHERE `id` = ?'
        )->execute([$repayAfter, $interestAfter, $loanId]);

        $after = Loan::select(' WHERE id = ?', [$loanId], '', ' LIMIT 1')[0] ?? [];

        return [
            'ok'                 => true,
            'loan_id'            => $loanId,
            'receipt_id'         => $receiptId,
            'calculated_amount'  => $calculated,
            'settled_amount'     => $amount,
            'overridden'         => $overridden,
            'reason'             => $overridden ? $reason : null,
            'interest_charged'   => $interestAfter,
            'interest_rebate'    => $q['interest_rebate'],
            'status'             => $after['status'] ?? null,
            'outstanding'        => isset($after['outstanding_balance']) ? (float)$after['outstanding_balance'] : null,
        ];
    }

    /** Weekly and the 100-day daily plan hold the interest back at disbursement. */
    private static function isUpfrontPlan(array $loan): bool
    {
        $type = strtolower(trim((string)($loan['loan_type'] ?? '')));
        if ($type === 'weekly') return true;
        $duration = (int)($loan['loan_duration'] ?? 0);
        return $type === 'daily' && ($duration > 0 ? $duration : 60) >= 100;
    }

    /** "5 of 10 instalments", or "4½ of 10" when a part-payment is involved. */
    private static function describeInstalments(float $paid, int $total): string
    {
        $shown = abs($paid - round($paid)) < 0.01
            ? (string)(int)round($paid)
            : rtrim(rtrim(number_format($paid, 2), '0'), '.');
        return "$shown of $total instalments";
    }

    /**
     * The next receipt number, allocated by the server.
     *
     * The collections screen works this out in the browser from the rows it
     * happens to have, which is fine until two people are collecting at once.
     * A settlement is written here, so it is counted here.
     */
    private static function nextReceiptNumber(PDO $pdo): string
    {
        $max = (int)$pdo->query(
            "SELECT COALESCE(MAX(CAST(REGEXP_REPLACE(`receipt_number`, '[^0-9]', '') AS UNSIGNED)), 0)
               FROM `collections`"
        )->fetchColumn();
        return 'RCP-' . ($max + 1);
    }
}
