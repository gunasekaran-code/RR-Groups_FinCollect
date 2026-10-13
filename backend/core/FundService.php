<?php
/**
 * A fund's life: deposits in, and the one payment that goes back out.
 *
 * Three things were decided in the browser and PATCHed onto the row, and all
 * three were wrong in ways that only showed up in the money:
 *
 *   The status. `matured` was written by whichever modal ran last. A settlement
 *   set it before a rupee had been deposited, and a collection recorded from
 *   anywhere else left it behind, so a fund could sit at `active` with nothing
 *   left to collect. It is derived here instead, from the deposits.
 *
 *   The running total. `collected_amount` was sent by the client alongside the
 *   passbook row, so the two could disagree — and did: a full settlement set
 *   collected to the target while writing a passbook row for the bonus alone,
 *   leaving ₹4,000 of "received" money that Cash In Hand (which sums
 *   `fund_payments`) had never seen.
 *
 *   The payout. Handing the customer their money back was written into
 *   `fund_payments`, the table of deposits coming IN. Paying out ₹6,000
 *   therefore *raised* Cash In Hand by ₹6,000 and put a deposit in the passbook
 *   on the day the fund was emptied. A payout is a cash_out, exactly as a chit
 *   prize is.
 *
 * What the customer is handed:
 *
 *     matured    deposits + maturity bonus     every week paid in
 *     settlement deposits                      closed early; the bonus is not earned
 *     partial    that share of deposits        some units closed, the rest running
 *
 * The amount is always computed here, never taken from the request. It is the
 * one number in the app a sender could otherwise choose for themselves.
 */
class FundService
{
    private const METHODS = ['cash', 'upi', 'card', 'bank', 'cheque'];

    /** A fund is fully deposited when it is within a paisa of its target. */
    private const EPSILON = 0.01;

    // ────────────────────────────── reads ──────────────────────────────

    /**
     * Everything a fund screen needs in one payload: the row as it now stands,
     * its payouts, and what a payout would hand over today.
     *
     * Returned from every write as well, so the UI never has to guess what the
     * server decided — the same shape a chit action returns.
     */
    public static function sheet(string $fundId): array
    {
        $fund = self::find($fundId);
        if (!$fund) return ['fund' => null, 'payouts' => [], 'payout' => null];

        return [
            'fund'    => self::shapeFund($fund),
            'payouts' => self::payoutsFor($fundId),
            'payout'  => self::preview($fund),
        ];
    }

    /**
     * What paying this fund out would hand over, and whether it can be.
     *
     * The bonus is the whole question. It is earned by depositing every week of
     * the scheme, so it belongs to a matured fund and to nothing else: a fund
     * closed early gets its deposits back and no more.
     */
    public static function preview(array $fund): array
    {
        $status    = (string)($fund['status'] ?? 'active');
        $collected = round((float)($fund['collected_amount'] ?? 0), 2);
        $target    = self::depositTarget($fund);
        $isMatured = $status === 'matured';

        // Deposits already handed back by a partial closure are gone from
        // `collected_amount` (recalc subtracts them), so what is left here is
        // what is still owed to the customer.
        $deposit = max(0.0, $collected);
        $bonus   = $isMatured ? round((float)($fund['bonus'] ?? 0), 2) : 0.0;

        $settled = self::finalPayout((string)$fund['id']);

        $reason = null;
        if ($settled)                    $reason = 'This fund has already been paid out.';
        elseif ($status === 'active')    $reason = 'The fund is still collecting. Close it or finish the deposits first.';
        elseif ($deposit + $bonus <= 0)  $reason = 'There is nothing to pay out — no deposits were received.';

        return [
            'kind'           => $isMatured ? 'maturity' : 'settlement',
            'deposit_amount' => $deposit,
            'bonus_amount'   => $bonus,
            'payout_amount'  => round($deposit + $bonus, 2),
            'deposit_target' => $target,
            'weeks_paid'     => self::weeksPaid($fund),
            'weeks'          => (int)($fund['weeks'] ?? 0),
            'bonus_earned'   => $isMatured,
            'can_pay'        => $reason === null,
            'blocked_reason' => $reason,
            'already_paid'   => $settled ? self::shapePayout($settled) : null,
        ];
    }

    /** Every payout recorded against a fund, newest first. */
    public static function payoutsFor(string $fundId): array
    {
        $stmt = Database::pdo()->prepare(
            'SELECT * FROM `fund_payouts` WHERE `fund_id` = ? AND `delflag` = 0
              ORDER BY `payout_date` DESC, `created_at` DESC'
        );
        $stmt->execute([$fundId]);
        return array_map([self::class, 'shapePayout'], $stmt->fetchAll());
    }

    // ───────────────────────────── writes ──────────────────────────────

    /**
     * Record a deposit.
     *
     * One request instead of the browser's two: the passbook row and the fund's
     * running total can no longer disagree, because only one of them is written
     * and the other is derived from it.
     */
    public static function collect(array $in, array $actor): array
    {
        $pdo  = Database::pdo();
        $fund = self::require_($in['fund_id'] ?? '');

        if ($fund['status'] !== 'active') {
            json_error('That fund is no longer collecting.', 409);
        }

        $target    = self::depositTarget($fund);
        $collected = round((float)$fund['collected_amount'], 2);
        $remaining = round(max(0.0, $target - $collected), 2);
        if ($remaining <= 0) json_error('This fund has already taken its full deposit.', 409);

        $amount = round((float)($in['amount'] ?? 0), 2);
        if ($amount <= 0) json_error('Enter an amount to collect.', 400);
        if ($amount > $remaining + self::EPSILON) {
            json_error('Only ' . self::money($remaining) . ' is left to deposit on this fund.', 400);
        }

        $method  = in_array($in['payment_method'] ?? '', self::METHODS, true) ? $in['payment_method'] : 'cash';
        $payDate = self::asDate($in['payment_date'] ?? null) ?: date('Y-m-d');
        $notes   = trim((string)($in['notes'] ?? '')) ?: null;

        // From the token, never the body: a receipt must name whoever actually
        // took the money, because the handover screen settles against it.
        $agentId   = $actor['sub'] ?? null;
        $agentName = $agentId ? (Profile::findPublic($agentId)['full_name'] ?? null) : null;
        if ($agentId === null) {
            $agentId   = $fund['assigned_agent'] ?? null;
            $agentName = $fund['agent_name'] ?? null;
        }

        // Which week this settles. Derived from the money rather than counted
        // in rows, so two weeks paid in one receipt advance the fund by two.
        //
        // `weekly_amount` is read through Fund::weeklyAmount, which works it
        // out from the deposit target and the term when the column was never
        // written. It used to be read straight off the row, and a zero there
        // sent every single receipt down the `: 1` branch — a fund could take
        // deposits for months and file all of them as week 1.
        $weekly = Fund::weeklyAmount($fund);
        $weeks  = (int)$fund['weeks'];
        if ($weekly > 0) {
            $weekNo = (int)floor($collected / $weekly) + 1;
        } else {
            // Nothing to divide by and nothing to derive one from. Counting
            // receipts is worse than the money — a half payment shows up as a
            // whole week — but it is the only thing left, and it at least
            // never files two deposits under the same week.
            $stmt = $pdo->prepare('SELECT COUNT(*) FROM `fund_payments` WHERE `fund_id` = ? AND `delflag` = 0');
            $stmt->execute([$fund['id']]);
            $weekNo = (int)$stmt->fetchColumn() + 1;
        }
        if ($weeks > 0) $weekNo = min($weekNo, $weeks);
        $weekNo = max(1, $weekNo);

        $pdo->beginTransaction();
        try {
            $pdo->prepare(
                'INSERT INTO `fund_payments`
                   (id, fund_id, fund_number, customer_id, customer_name, week_no, amount,
                    balance_after, payment_method, payment_date, agent_id, agent_name, notes)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)'
            )->execute([
                uuid4(), $fund['id'], $fund['fund_number'] ?? null,
                $fund['customer_id'] ?? null, $fund['customer_name'] ?? null,
                $weekNo, $amount, round($collected + $amount, 2),
                $method, $payDate, $agentId, $agentName, $notes,
            ]);
            self::recalc($pdo, (string)$fund['id']);
            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            json_error('Could not record that collection: ' . $e->getMessage(), 409);
        }

        return self::sheet((string)$fund['id']);
    }

    /**
     * End the scheme early.
     *
     * Closing does not move money — the payout is its own step, so the card can
     * show what is owed before anybody hands it over. The one exception is a
     * partial closure: it shrinks the fund and the rest carries on collecting,
     * so there is no finished fund left to hang a pending payout on and the
     * closed units are paid over in the same action.
     */
    public static function close(array $in, array $actor): array
    {
        $pdo  = Database::pdo();
        $fund = self::require_($in['fund_id'] ?? '');

        if ($fund['status'] === 'closed') json_error('That fund is already closed.', 409);
        if (self::finalPayout((string)$fund['id'])) {
            json_error('That fund has already been paid out.', 409);
        }

        $units      = round((float)($fund['units'] ?? 1), 2);
        $closeUnits = array_key_exists('units', $in) ? round((float)$in['units'], 2) : $units;
        if ($closeUnits <= 0)      json_error('How many units are being closed?', 400);
        if ($closeUnits > $units)  json_error("This fund only has $units units.", 400);

        $isFull = $closeUnits >= $units - 0.001;

        if ($isFull) {
            $pdo->prepare("UPDATE `funds` SET `status` = 'closed' WHERE `id` = ? AND `delflag` = 0")
                ->execute([$fund['id']]);
            return self::sheet((string)$fund['id']);
        }

        // Partial: everything about the fund scales down with the units, and
        // the closed share of the deposits is handed over now.
        $ratio     = $units > 0 ? $closeUnits / $units : 1.0;
        $collected = round((float)$fund['collected_amount'], 2);
        $share     = round($collected * $ratio, 2);
        $remUnits  = round($units - $closeUnits, 2);

        $method  = in_array($in['payment_method'] ?? '', self::METHODS, true) ? $in['payment_method'] : 'cash';
        $payDate = self::asDate($in['payout_date'] ?? $in['payment_date'] ?? null) ?: date('Y-m-d');
        $notes   = trim((string)($in['notes'] ?? ''));

        $pdo->beginTransaction();
        try {
            $pdo->prepare(
                'UPDATE `funds`
                    SET `units` = ?, `weekly_amount` = ?, `deposit_amount` = ?,
                        `bonus` = ?, `total_amount` = ?
                  WHERE `id` = ? AND `delflag` = 0'
            )->execute([
                $remUnits,
                round(Fund::weeklyAmount($fund) * ($remUnits / ($units ?: 1)), 2),
                round(self::depositTarget($fund) * ($remUnits / ($units ?: 1)), 2),
                round((float)$fund['bonus'] * ($remUnits / ($units ?: 1)), 2),
                round((self::depositTarget($fund) + (float)$fund['bonus']) * ($remUnits / ($units ?: 1)), 2),
                $fund['id'],
            ]);

            if ($share > 0) {
                self::writePayout($pdo, $fund, [
                    'kind'           => 'partial',
                    'units_closed'   => $closeUnits,
                    'deposit_amount' => $share,
                    'bonus_amount'   => 0.0,
                    'payment_method' => $method,
                    'payout_date'    => $payDate,
                    'notes'          => $notes,
                    'title'          => 'Fund Closure: ' . ($fund['customer_name'] ?? 'Customer')
                                        . ' (' . ($fund['fund_number'] ?? '') . ')',
                    'ledger_note'    => $notes !== '' ? $notes : sprintf(
                        '%s units of %s closed early — %s returned to %s (%s)',
                        $closeUnits, $units, self::money($share),
                        $fund['customer_name'] ?? 'the customer', strtoupper($method)
                    ),
                ], $actor);
            }

            self::recalc($pdo, (string)$fund['id']);
            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            json_error('Could not close that fund: ' . $e->getMessage(), 409);
        }

        return self::sheet((string)$fund['id']);
    }

    /**
     * Hand the money over. This is the step that takes cash out of the safe.
     *
     * The cash_out row and the payout record go in one transaction, so the
     * books can never show a paid-out fund with no money movement behind it.
     */
    public static function payout(array $in, array $actor): array
    {
        $pdo  = Database::pdo();
        $fund = self::require_($in['fund_id'] ?? '');

        $preview = self::preview($fund);
        if (!$preview['can_pay']) {
            json_error($preview['blocked_reason'] ?? 'This fund cannot be paid out.', 409);
        }

        $method  = in_array($in['payment_method'] ?? '', self::METHODS, true) ? $in['payment_method'] : 'cash';
        $payDate = self::asDate($in['payout_date'] ?? null) ?: date('Y-m-d');
        $notes   = trim((string)($in['notes'] ?? ''));

        $pdo->beginTransaction();
        try {
            // Guarded on the absence of a payout inside the transaction as well
            // as before it: two clicks racing each other would otherwise both
            // pass the preview and pay the customer twice.
            $stmt = $pdo->prepare(
                "SELECT COUNT(*) FROM `fund_payouts`
                  WHERE `fund_id` = ? AND `delflag` = 0 AND `kind` <> 'partial' FOR UPDATE"
            );
            $stmt->execute([$fund['id']]);
            if ((int)$stmt->fetchColumn() > 0) {
                throw new \RuntimeException('That fund was paid out by someone else a moment ago');
            }

            $payoutId = self::writePayout($pdo, $fund, [
                'kind'           => $preview['kind'],
                'units_closed'   => round((float)($fund['units'] ?? 1), 2),
                'deposit_amount' => $preview['deposit_amount'],
                'bonus_amount'   => $preview['bonus_amount'],
                'payment_method' => $method,
                'payout_date'    => $payDate,
                'notes'          => $notes,
                'title'          => 'Fund Payout: ' . ($fund['customer_name'] ?? 'Customer')
                                    . ' (' . ($fund['fund_number'] ?? '') . ')',
                'ledger_note'    => $notes !== '' ? $notes : sprintf(
                    '%s paid to %s — %s%s (%s)',
                    self::money($preview['payout_amount']),
                    $fund['customer_name'] ?? 'the customer',
                    self::money($preview['deposit_amount']) . ' deposits',
                    $preview['bonus_amount'] > 0
                        ? ' + ' . self::money($preview['bonus_amount']) . ' maturity bonus'
                        : ' (closed early — no bonus)',
                    strtoupper($method)
                ),
            ], $actor);

            // The scheme is over once the money is out. Left at `matured` the
            // fund would keep offering a Collect button against a customer who
            // no longer has an account.
            $pdo->prepare("UPDATE `funds` SET `status` = 'closed' WHERE `id` = ?")
                ->execute([$fund['id']]);

            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            json_error('Payout failed: ' . $e->getMessage(), 409);
            return [];
        }

        $out = self::sheet((string)$fund['id']);
        $out['payout_id'] = $payoutId;
        return $out;
    }

    /**
     * Undo a payout recorded in error.
     *
     * The ledger row is deleted rather than flagged: a soft-deleted cash_out
     * would keep the money off Cash In Hand for ever, which is the opposite of
     * what reversing it means.
     */
    public static function reverse(array $in, array $actor): array
    {
        $pdo = Database::pdo();

        $payoutId = trim((string)($in['payout_id'] ?? ''));
        if ($payoutId === '') json_error('Which payout is being reversed?', 400);

        $stmt = $pdo->prepare('SELECT * FROM `fund_payouts` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$payoutId]);
        $payout = $stmt->fetch();
        if (!$payout) json_error('That payout record no longer exists.', 404);

        $fundId = (string)$payout['fund_id'];

        $pdo->beginTransaction();
        try {
            if (!empty($payout['ledger_id'])) {
                $pdo->prepare('DELETE FROM `account_ledger` WHERE `id` = ?')->execute([$payout['ledger_id']]);
            }
            $pdo->prepare(
                'UPDATE `fund_payouts` SET `delflag` = 1, `deleted_at` = NOW(), `deleted_by` = ? WHERE `id` = ?'
            )->execute([$actor['sub'] ?? null, $payoutId]);

            // Back to whatever the deposits say it is. A reversed final payout
            // leaves the fund closed only if it was closed for its own reasons.
            if ($payout['kind'] !== 'partial') {
                $pdo->prepare("UPDATE `funds` SET `status` = 'active' WHERE `id` = ?")->execute([$fundId]);
            }
            self::recalc($pdo, $fundId);
            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            json_error('Could not reverse that payout: ' . $e->getMessage(), 409);
        }

        return self::sheet($fundId);
    }

    // ──────────────────────────── internals ────────────────────────────

    /**
     * Re-derive the fund's running total and status from what is recorded.
     *
     * Deposits in, less any deposits a partial closure has already handed back.
     * A final payout freezes the fund: recalculating a paid-out fund back to
     * `active` would put a Collect button on a closed account.
     */
    public static function recalc(PDO $pdo, string $fundId): void
    {
        $stmt = $pdo->prepare(
            'SELECT COALESCE(SUM(`amount`), 0) FROM `fund_payments` WHERE `fund_id` = ? AND `delflag` = 0'
        );
        $stmt->execute([$fundId]);
        $in = round((float)$stmt->fetchColumn(), 2);

        $stmt = $pdo->prepare(
            "SELECT COALESCE(SUM(`deposit_amount`), 0) FROM `fund_payouts`
              WHERE `fund_id` = ? AND `delflag` = 0 AND `kind` = 'partial'"
        );
        $stmt->execute([$fundId]);
        $returned = round((float)$stmt->fetchColumn(), 2);

        $collected = round(max(0.0, $in - $returned), 2);

        $stmt = $pdo->prepare('SELECT * FROM `funds` WHERE `id` = ? LIMIT 1');
        $stmt->execute([$fundId]);
        $fund = $stmt->fetch();
        if (!$fund) return;

        // Write back any derived figure the fund was stored without, so that
        // readers which go straight to the column — the agent portfolio, the
        // fund cards, reports — see the same number this service works with.
        // Reading through Fund::weeklyAmount everywhere would be enough for
        // correctness, but it would leave the database itself saying a fund
        // collects ₹0 a week, and that is what somebody exports.
        $fill = Fund::deriveFields($fund);
        if ($fill) {
            $set = [];
            $binds = [];
            foreach ($fill as $col => $val) { $set[] = "`$col` = ?"; $binds[] = $val; }
            $binds[] = $fundId;
            $pdo->prepare('UPDATE `funds` SET ' . implode(', ', $set) . ' WHERE `id` = ?')->execute($binds);
            $fund = array_merge($fund, $fill);
        }

        $target = self::depositTarget($fund);
        $status = (string)$fund['status'];

        // `closed` is a decision somebody made, and a paid-out fund is finished.
        // Neither is re-derived from the deposits.
        if ($status !== 'closed' && !self::finalPayout($fundId)) {
            $status = ($target > 0 && $collected >= $target - self::EPSILON) ? 'matured' : 'active';
        }

        $pdo->prepare('UPDATE `funds` SET `collected_amount` = ?, `status` = ? WHERE `id` = ?')
            ->execute([$collected, $status, $fundId]);
    }

    /** Write the cash_out and the payout row together. Caller owns the transaction. */
    private static function writePayout(PDO $pdo, array $fund, array $p, array $actor): string
    {
        $amount = round((float)$p['deposit_amount'] + (float)$p['bonus_amount'], 2);

        $agentId   = $actor['sub'] ?? null;
        $agentName = $agentId ? (Profile::findPublic($agentId)['full_name'] ?? null) : null;

        $ledgerId = uuid4();
        $pdo->prepare(
            'INSERT INTO `account_ledger`
               (id, entry_type, title, amount, category, entry_date, notes,
                agent_id, agent_name, payment_method)
             VALUES (?,?,?,?,?,?,?,?,?,?)'
        )->execute([
            $ledgerId, 'cash_out', $p['title'], $amount, 'Fund Payout',
            $p['payout_date'], $p['ledger_note'], $agentId, $agentName, $p['payment_method'],
        ]);

        $payoutId = uuid4();
        $pdo->prepare(
            'INSERT INTO `fund_payouts`
               (id, fund_id, fund_number, customer_id, customer_name, kind, units_closed,
                deposit_amount, bonus_amount, payout_amount, payout_date, payment_method,
                ledger_id, agent_id, agent_name, notes)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)'
        )->execute([
            $payoutId, $fund['id'], $fund['fund_number'] ?? null,
            $fund['customer_id'] ?? null, $fund['customer_name'] ?? null,
            $p['kind'], $p['units_closed'],
            round((float)$p['deposit_amount'], 2), round((float)$p['bonus_amount'], 2), $amount,
            $p['payout_date'], $p['payment_method'],
            $ledgerId, $agentId, $agentName,
            $p['notes'] !== '' ? $p['notes'] : null,
        ]);

        return $payoutId;
    }

    /** The maturity/settlement payout, if this fund has had one. */
    private static function finalPayout(string $fundId): ?array
    {
        try {
            $stmt = Database::pdo()->prepare(
                "SELECT * FROM `fund_payouts`
                  WHERE `fund_id` = ? AND `delflag` = 0 AND `kind` <> 'partial' LIMIT 1"
            );
            $stmt->execute([$fundId]);
            return $stmt->fetch() ?: null;
        } catch (\Throwable $e) {
            return null;
        }
    }

    private static function find(string $fundId): ?array
    {
        if ($fundId === '') return null;
        $stmt = Database::pdo()->prepare('SELECT * FROM `funds` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$fundId]);
        return $stmt->fetch() ?: null;
    }

    private static function require_($fundId): array
    {
        $fund = self::find(trim((string)$fundId));
        if (!$fund) json_error('That fund no longer exists.', 404);
        return $fund;
    }

    /**
     * What the customer signed up to deposit — weekly × weeks.
     *
     * Never `total_amount`: that includes the bonus, which the customer does
     * not pay in. Measuring progress against it left every fund permanently
     * short by the bonus.
     */
    private static function depositTarget(array $fund): float
    {
        $stored = round((float)($fund['deposit_amount'] ?? 0), 2);
        if ($stored > 0) return $stored;
        return round(Fund::weeklyAmount($fund) * (int)($fund['weeks'] ?? 0), 2);
    }

    /** Weeks covered by the money in, not rows in the passbook. */
    private static function weeksPaid(array $fund): int
    {
        $weekly = Fund::weeklyAmount($fund);
        if ($weekly <= 0) return 0;
        $done  = (int)floor(round((float)($fund['collected_amount'] ?? 0), 2) / $weekly);
        $weeks = (int)($fund['weeks'] ?? 0);
        return $weeks > 0 ? max(0, min($done, $weeks)) : max(0, $done);
    }

    private static function shapeFund(array $f): array
    {
        // Derived when the column is empty, so the passbook header stops
        // reading "Total deposit (₹0 × 50 weeks)" next to a total of ₹10,000,
        // and the next-due line stops offering to collect ₹0.
        $f['weekly_amount']    = Fund::weeklyAmount($f);
        $f['bonus']            = round((float)$f['bonus'], 2);
        $f['deposit_amount']   = round((float)$f['deposit_amount'], 2);
        $f['total_amount']     = round((float)$f['total_amount'], 2);
        $f['collected_amount'] = round((float)$f['collected_amount'], 2);
        $f['units']            = round((float)($f['units'] ?? 1), 2);
        $f['weeks']            = (int)$f['weeks'];
        return $f;
    }

    private static function shapePayout(array $p): array
    {
        return [
            'id'             => $p['id'],
            'fund_id'        => $p['fund_id'],
            'kind'           => (string)$p['kind'],
            'units_closed'   => round((float)$p['units_closed'], 2),
            'deposit_amount' => round((float)$p['deposit_amount'], 2),
            'bonus_amount'   => round((float)$p['bonus_amount'], 2),
            'payout_amount'  => round((float)$p['payout_amount'], 2),
            'payout_date'    => $p['payout_date'] ?? null,
            'payment_method' => (string)$p['payment_method'],
            'ledger_id'      => $p['ledger_id'] ?? null,
            'agent_name'     => $p['agent_name'] ?? null,
            'notes'          => $p['notes'] ?? null,
            'created_at'     => $p['created_at'] ?? null,
        ];
    }

    private static function asDate($v): ?string
    {
        $v = trim((string)$v);
        if ($v === '') return null;
        $ts = strtotime($v);
        return $ts ? date('Y-m-d', $ts) : null;
    }

    private static function money(float $n): string
    {
        return '₹' . number_format($n, 2);
    }
}
