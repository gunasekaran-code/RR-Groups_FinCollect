<?php
/**
 * Chit auctions and settlement — who won each draw, and whether the prize has
 * actually been handed over.
 *
 * The draw sheet has always carried a pool value per instalment: what the
 * winner of that draw receives. Nothing recorded who took it. That left the
 * largest movement in a chit group — the prize going out — off the books
 * entirely, so contributions raised Cash In Hand and the payout never lowered
 * it.
 *
 * Settling a draw writes an `account_ledger` cash_out row inside the same
 * transaction as the auction record, exactly as a contribution writes its
 * cash_in. The account book therefore needs no special case: the money is
 * counted once, by the same rule as every other rupee.
 *
 * The arithmetic of a draw:
 *
 *     payout   = pool − discount − commission     (handed to the winner)
 *     dividend = discount − commission            (shared among the members)
 *
 * A fixed-payout scheme simply leaves the discount at zero, and the winner is
 * handed the whole pool.
 */
class ChitAuctionService
{
    private const METHODS = ['cash', 'upi', 'card', 'bank', 'cheque'];

    // ────────────────────────────── reads ──────────────────────────────

    /**
     * Every draw in the group's schedule, each with its auction if one has
     * been recorded.
     *
     * Driven by the schedule rather than by the auctions table so a group that
     * has held no auction still shows its draws waiting, instead of an empty
     * screen that looks like a loading failure.
     */
    public static function forGroup(string $groupId): array
    {
        if ($groupId === '') return ['group' => null, 'draws' => [], 'summary' => self::emptySummary()];

        $pdo = Database::pdo();
        $stmt = $pdo->prepare('SELECT * FROM `chit_groups` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$groupId]);
        $group = $stmt->fetch();
        if (!$group) return ['group' => null, 'draws' => [], 'summary' => self::emptySummary()];

        // Generating is safe here: schedulesFor() only builds when the sheet is
        // genuinely absent, and an auctions screen with no draws is useless.
        $schedule = ChitPassbookService::schedulesFor($groupId, $group, true);

        $stmt = $pdo->prepare(
            'SELECT * FROM `chit_auctions` WHERE `group_id` = ? AND `delflag` = 0'
        );
        $stmt->execute([$groupId]);
        $byDraw = [];
        foreach ($stmt->fetchAll() as $a) {
            $byDraw[(int)$a['installment_no']] = $a;
        }

        // What each draw has actually been contributed towards, so the screen
        // can show whether the pool has been collected before it is paid out.
        $stmt = $pdo->prepare(
            'SELECT `installment_no`, COALESCE(SUM(`paid_amount`), 0) AS collected
               FROM `chit_passbook` WHERE `group_id` = ? AND `delflag` = 0
              GROUP BY `installment_no`'
        );
        $stmt->execute([$groupId]);
        $collected = [];
        foreach ($stmt->fetchAll() as $r) {
            $collected[(int)$r['installment_no']] = (float)$r['collected'];
        }

        $draws = [];
        foreach ($schedule as $s) {
            $no = (int)$s['installment_no'];
            $a  = $byDraw[$no] ?? null;
            $draws[] = [
                'installment_no' => $no,
                'due_date'       => $s['due_date'] ?? null,
                'pool_amount'    => round((float)($s['pool_amount'] ?? 0), 2),
                'payable_amount' => round((float)($s['payable_amount'] ?? 0), 2),
                'collected'      => round($collected[$no] ?? 0, 2),
                'auction'        => $a ? self::shape($a) : null,
                'status'         => $a ? (string)$a['status'] : 'open',
            ];
            unset($byDraw[$no]);
        }

        // An auction whose draw has since vanished from the schedule is still
        // money that moved — showing it is the only way it can be corrected.
        foreach ($byDraw as $no => $a) {
            $draws[] = [
                'installment_no' => (int)$no,
                'due_date'       => $a['auction_date'] ?? null,
                'pool_amount'    => round((float)$a['pool_amount'], 2),
                'payable_amount' => 0.0,
                'collected'      => round($collected[(int)$no] ?? 0, 2),
                'auction'        => self::shape($a),
                'status'         => (string)$a['status'],
                'orphaned'       => true,
            ];
        }
        usort($draws, fn($x, $y) => $x['installment_no'] <=> $y['installment_no']);

        return [
            'group'   => [
                'id'           => $group['id'],
                'group_name'   => $group['group_name'] ?? null,
                'group_number' => $group['group_number'] ?? null,
                'group_value'  => round((float)($group['group_value'] ?? 0), 2),
                'duration'     => (int)($group['duration'] ?? 0),
            ],
            'draws'   => $draws,
            'summary' => self::summarize($draws),
        ];
    }

    private static function emptySummary(): array
    {
        return [
            'total_draws' => 0, 'won' => 0, 'settled' => 0, 'open' => 0,
            'paid_out' => 0.0, 'pending_payout' => 0.0, 'dividend_total' => 0.0,
        ];
    }

    private static function summarize(array $draws): array
    {
        $s = self::emptySummary();
        $s['total_draws'] = count($draws);
        foreach ($draws as $d) {
            $a = $d['auction'];
            if (!$a) { $s['open']++; continue; }
            $s['dividend_total'] += $a['dividend_total'];
            if ($a['status'] === 'settled') {
                $s['settled']++;
                $s['paid_out'] += $a['payout_amount'];
            } else {
                $s['won']++;
                $s['pending_payout'] += $a['payout_amount'];
            }
        }
        foreach (['paid_out', 'pending_payout', 'dividend_total'] as $k) {
            $s[$k] = round($s[$k], 2);
        }
        return $s;
    }

    private static function shape(array $a): array
    {
        return [
            'id'             => $a['id'],
            'installment_no' => (int)$a['installment_no'],
            'auction_date'   => $a['auction_date'] ?? null,
            'member_id'      => $a['member_id'] ?? null,
            'customer_id'    => $a['customer_id'] ?? null,
            'member_name'    => $a['member_name'] ?? null,
            'pool_amount'    => round((float)$a['pool_amount'], 2),
            'bid_amount'     => round((float)$a['bid_amount'], 2),
            'commission'     => round((float)$a['commission'], 2),
            'payout_amount'  => round((float)$a['payout_amount'], 2),
            'dividend_total' => round((float)$a['dividend_total'], 2),
            'status'         => (string)$a['status'],
            'payout_date'    => $a['payout_date'] ?? null,
            'payment_method' => (string)$a['payment_method'],
            'ledger_id'      => $a['ledger_id'] ?? null,
            'agent_name'     => $a['agent_name'] ?? null,
            'notes'          => $a['notes'] ?? null,
        ];
    }

    // ───────────────────────────── writes ──────────────────────────────

    /**
     * Record (or correct) the winner of a draw.
     *
     * Recording a winner does not move money — settle() does that — so this is
     * safely repeatable while the details are being entered.
     */
    public static function record(array $in, array $actor): array
    {
        $pdo = Database::pdo();

        $groupId = trim((string)($in['group_id'] ?? ''));
        $drawNo  = (int)($in['installment_no'] ?? 0);
        if ($groupId === '') json_error('Which group?', 400);
        if ($drawNo < 1)     json_error('Which draw?', 400);

        $stmt = $pdo->prepare('SELECT * FROM `chit_groups` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$groupId]);
        $group = $stmt->fetch();
        if (!$group) json_error('That chit group no longer exists', 404);

        $memberId = trim((string)($in['member_id'] ?? ''));
        if ($memberId === '') json_error('Who won the draw?', 400);

        $stmt = $pdo->prepare(
            'SELECT * FROM `chit_members` WHERE `id` = ? AND `group_id` = ? AND `delflag` = 0 LIMIT 1'
        );
        $stmt->execute([$memberId, $groupId]);
        $member = $stmt->fetch();
        if (!$member) json_error('That member is not in this group', 404);

        $existing = self::find($pdo, $groupId, $drawNo);
        if ($existing && $existing['status'] === 'settled') {
            json_error('That draw has already been paid out. Reverse the settlement before changing it.', 409);
        }

        // The pool comes from the draw sheet, not from the browser: the prize
        // is a property of the scheme, and letting a form set it would make the
        // payout whatever the sender typed.
        $pool = self::poolFor($pdo, $groupId, $group, $drawNo);

        $bid        = max(0.0, round((float)($in['bid_amount'] ?? 0), 2));
        $commission = max(0.0, round((float)($in['commission'] ?? 0), 2));
        if ($bid > $pool) {
            json_error('The discount cannot be more than the pool of ' . self::money($pool), 400);
        }
        if ($commission > $bid && $bid > 0) {
            json_error('Commission cannot be more than the discount it comes out of', 400);
        }
        // With no discount there is nothing to take a commission from, so a
        // fixed-payout scheme charging one would pay the winner less than the
        // pool with no dividend to show for it.
        if ($bid <= 0 && $commission > 0) {
            json_error('Commission comes out of the discount — record the discount first', 400);
        }

        $payout   = round($pool - $bid, 2);
        $dividend = round($bid - $commission, 2);

        $agentId   = $actor['sub'] ?? null;
        $agentName = $agentId ? (Profile::findPublic($agentId)['full_name'] ?? null) : null;

        $row = [
            'group_id'       => $groupId,
            'installment_no' => $drawNo,
            'group_number'   => $group['group_number'] ?? null,
            'group_name'     => $group['group_name'] ?? null,
            'auction_date'   => self::asDate($in['auction_date'] ?? null) ?: date('Y-m-d'),
            'member_id'      => $memberId,
            'customer_id'    => $member['customer_id'] ?? null,
            'member_name'    => $member['member_name'] ?? null,
            'pool_amount'    => $pool,
            'bid_amount'     => $bid,
            'commission'     => $commission,
            'payout_amount'  => $payout,
            'dividend_total' => $dividend,
            'notes'          => trim((string)($in['notes'] ?? '')) ?: null,
            'agent_id'       => $agentId,
            'agent_name'     => $agentName,
        ];

        if ($existing) {
            $sets = implode(', ', array_map(fn($c) => "`$c` = ?", array_keys($row)));
            $stmt = $pdo->prepare("UPDATE `chit_auctions` SET $sets WHERE `id` = ?");
            $stmt->execute([...array_values($row), $existing['id']]);
            $id = $existing['id'];
        } else {
            $row = ['id' => uuid4(), 'status' => 'won'] + $row;
            $cols = implode(', ', array_map(fn($c) => "`$c`", array_keys($row)));
            $qs   = implode(',', array_fill(0, count($row), '?'));
            $pdo->prepare("INSERT INTO `chit_auctions` ($cols) VALUES ($qs)")
                ->execute(array_values($row));
            $id = $row['id'];
        }

        return self::forGroupWith($groupId, $id);
    }

    /**
     * Hand the prize over: the money leaves the safe here.
     *
     * The cash_out row and the status change go in one transaction, so the
     * books can never show a paid-out draw with no cash movement behind it, or
     * a payment with nothing explaining it.
     */
    public static function settle(array $in, array $actor): array
    {
        $pdo = Database::pdo();

        $auctionId = trim((string)($in['auction_id'] ?? ''));
        if ($auctionId === '') json_error('Which draw is being paid out?', 400);

        $stmt = $pdo->prepare('SELECT * FROM `chit_auctions` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$auctionId]);
        $auction = $stmt->fetch();
        if (!$auction) json_error('That auction record no longer exists', 404);
        if ($auction['status'] === 'settled') {
            json_error('That prize has already been paid out', 409);
        }
        if (empty($auction['member_id'])) {
            json_error('Record who won the draw before paying it out', 400);
        }

        $payout = round((float)$auction['payout_amount'], 2);
        if ($payout <= 0) json_error('There is nothing to pay out on that draw', 400);

        $method  = in_array($in['payment_method'] ?? '', self::METHODS, true)
            ? $in['payment_method'] : 'cash';
        $payDate = self::asDate($in['payout_date'] ?? null) ?: date('Y-m-d');
        $notes   = trim((string)($in['notes'] ?? ''));

        // Taken from the token, never the body: an agent must not be able to
        // file a payout under someone else's name.
        $agentId   = $actor['sub'] ?? null;
        $agentName = $agentId ? (Profile::findPublic($agentId)['full_name'] ?? null) : null;

        $pdo->beginTransaction();
        try {
            $ledgerId = uuid4();
            $pdo->prepare(
                'INSERT INTO `account_ledger`
                   (id, entry_type, title, amount, category, entry_date, notes,
                    agent_id, agent_name, payment_method)
                 VALUES (?,?,?,?,?,?,?,?,?,?)'
            )->execute([
                $ledgerId,
                'cash_out',
                'Chit Payout: ' . ($auction['group_name'] ?? '') . ' - ' . ($auction['member_name'] ?? 'Winner'),
                $payout,
                'Chit Payout',
                $payDate,
                $notes !== '' ? $notes : sprintf(
                    'Draw #%d prize %s paid to %s (%s)',
                    (int)$auction['installment_no'],
                    self::money($payout),
                    $auction['member_name'] ?? 'winner',
                    strtoupper($method)
                ),
                $agentId,
                $agentName,
                $method,
            ]);

            // Guarded on status as well as id: two clicks racing each other
            // would otherwise both pass the check above and pay twice.
            $stmt = $pdo->prepare(
                "UPDATE `chit_auctions`
                    SET `status` = 'settled', `payout_date` = ?, `payment_method` = ?,
                        `ledger_id` = ?, `agent_id` = ?, `agent_name` = ?,
                        `notes` = COALESCE(NULLIF(?, ''), `notes`)
                  WHERE `id` = ? AND `status` <> 'settled'"
            );
            $stmt->execute([$payDate, $method, $ledgerId, $agentId, $agentName, $notes, $auctionId]);
            if ($stmt->rowCount() === 0) {
                throw new \RuntimeException('That prize was paid out by someone else a moment ago');
            }

            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            json_error('Payout failed: ' . $e->getMessage(), 409);
        }

        return self::forGroupWith((string)$auction['group_id'], $auctionId);
    }

    /**
     * Undo a payout that was recorded in error.
     *
     * The ledger row is removed rather than flagged: leaving a soft-deleted
     * cash_out behind would keep the money off Cash In Hand for ever, which is
     * the opposite of what reversing it means.
     */
    public static function reverse(array $in, array $actor): array
    {
        $pdo = Database::pdo();

        $auctionId = trim((string)($in['auction_id'] ?? ''));
        if ($auctionId === '') json_error('Which payout is being reversed?', 400);

        $stmt = $pdo->prepare('SELECT * FROM `chit_auctions` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$auctionId]);
        $auction = $stmt->fetch();
        if (!$auction) json_error('That auction record no longer exists', 404);
        if ($auction['status'] !== 'settled') json_error('That draw has not been paid out', 409);

        $pdo->beginTransaction();
        try {
            if (!empty($auction['ledger_id'])) {
                $pdo->prepare('DELETE FROM `account_ledger` WHERE `id` = ?')
                    ->execute([$auction['ledger_id']]);
            }
            $pdo->prepare(
                "UPDATE `chit_auctions`
                    SET `status` = 'won', `payout_date` = NULL, `ledger_id` = NULL
                  WHERE `id` = ?"
            )->execute([$auctionId]);
            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            json_error('Could not reverse that payout: ' . $e->getMessage(), 409);
        }

        return self::forGroupWith((string)$auction['group_id'], $auctionId);
    }

    /** Remove an auction record entirely. Only while unsettled. */
    public static function remove(array $in, array $actor): array
    {
        $pdo = Database::pdo();

        $auctionId = trim((string)($in['auction_id'] ?? ''));
        if ($auctionId === '') json_error('Which auction?', 400);

        $stmt = $pdo->prepare('SELECT * FROM `chit_auctions` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$auctionId]);
        $auction = $stmt->fetch();
        if (!$auction) json_error('That auction record no longer exists', 404);
        if ($auction['status'] === 'settled') {
            json_error('Reverse the payout before removing the auction', 409);
        }

        $pdo->prepare(
            'UPDATE `chit_auctions` SET `delflag` = 1, `deleted_at` = NOW(), `deleted_by` = ? WHERE `id` = ?'
        )->execute([$actor['sub'] ?? null, $auctionId]);

        return self::forGroup((string)$auction['group_id']);
    }

    // ──────────────────────────── internals ────────────────────────────

    private static function forGroupWith(string $groupId, string $auctionId): array
    {
        $out = self::forGroup($groupId);
        $out['auction_id'] = $auctionId;
        return $out;
    }

    private static function find(PDO $pdo, string $groupId, int $drawNo): ?array
    {
        $stmt = $pdo->prepare(
            'SELECT * FROM `chit_auctions`
              WHERE `group_id` = ? AND `installment_no` = ? AND `delflag` = 0 LIMIT 1'
        );
        $stmt->execute([$groupId, $drawNo]);
        return $stmt->fetch() ?: null;
    }

    /** The pool for a draw, from the draw sheet. */
    private static function poolFor(PDO $pdo, string $groupId, array $group, int $drawNo): float
    {
        foreach (ChitPassbookService::schedulesFor($groupId, $group, true) as $s) {
            if ((int)$s['installment_no'] === $drawNo) {
                return round((float)($s['pool_amount'] ?? 0), 2);
            }
        }
        json_error("Draw #$drawNo is not in this group's schedule", 400);
        return 0.0; // unreachable; json_error exits
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
