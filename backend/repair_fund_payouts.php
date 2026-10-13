<?php
/**
 * Move old fund payouts out of the deposits table.
 *
 * Until this release, closing or settling a fund wrote the money handed to the
 * customer into `fund_payments` — the passbook of deposits coming IN, which is
 * what Cash In Hand sums as cash received. So paying somebody ₹1,000 back added
 * ₹1,000 to the safe instead of taking it out, and the passbook showed a
 * deposit on the day the account was emptied.
 *
 * Those rows are identifiable: the old code wrote its own note on every one of
 * them, and no collection has ever carried that text. This converts each into
 * what it always was — a `fund_payouts` record and an `account_ledger` cash_out
 * — so the money is counted once, in the right direction.
 *
 * Usage
 *   Browser (production):  https://rrgroupscbe.com/backend/repair_fund_payouts.php
 *   CLI (local):           php backend/repair_fund_payouts.php
 *
 * Both are a DRY RUN by default: they list every row that would move, the exact
 * effect on Cash In Hand, and change nothing. Add ?confirm=YES (or --confirm on
 * the CLI) to apply it. Take a backup first.
 *
 * WHAT THIS DOES NOT DECIDE. A full closure also set `collected_amount` to the
 * fund's whole target without writing a receipt for the difference, so a fund
 * that had taken ₹0 was left reading ₹5,000 deposited. Whether that ₹5,000 was
 * actually handed over is not recorded anywhere and cannot be worked out from
 * here, so nothing touches it. Those funds are listed under
 * `unreceipted_deposits` for a human to settle.
 *
 * DELETE THIS FILE once the repair is done.
 */
error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('max_execution_time', 300);

require_once __DIR__ . '/bootstrap.php';


// Not a public URL. See require_maintenance_admin() in bootstrap.php.
require_maintenance_admin();
$isCli = php_sapi_name() === 'cli';
if (!$isCli) {
    header('Content-Type: application/json; charset=utf-8');
    header('Access-Control-Allow-Origin: *');
}

$confirmed = $isCli
    ? in_array('--confirm', array_slice($argv, 1), true)
    : (($_GET['confirm'] ?? '') === 'YES');

// The two notes the old settlement modal wrote, and nothing else ever did.
$MARKERS = ['Full settlement closure (%', 'Partial closure of %'];

$report = [
    'timestamp' => date('c'),
    'mode'      => $confirmed ? 'EXECUTE' : 'DRY RUN - nothing was changed',
    'errors'    => [],
];

$finish = function (array $r) use ($isCli) {
    $flags = JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE;
    if ($isCli) $flags |= JSON_UNESCAPED_SLASHES;
    echo json_encode($r, $flags), "\n";
    exit(empty($r['errors']) ? 0 : 1);
};

try {
    $pdo = Database::pdo();

    $where = implode(' OR ', array_fill(0, count($MARKERS), 'fp.`notes` LIKE ?'));
    $stmt  = $pdo->prepare(
        "SELECT fp.*, f.`customer_name` AS fund_customer, f.`units` AS fund_units
           FROM `fund_payments` fp
           LEFT JOIN `funds` f ON f.`id` = fp.`fund_id`
          WHERE ($where) AND COALESCE(fp.`delflag`, 0) = 0
          ORDER BY fp.`created_at`"
    );
    $stmt->execute($MARKERS);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

    $before = AccountLedger::getRealtimeSummary();
    $report['cash_in_hand_before'] = round((float)$before['cashInHand'], 2);

    $total = 0.0;
    $report['would_move'] = array_map(function ($r) use (&$total) {
        $total += (float)$r['amount'];
        return [
            'fund_number' => $r['fund_number'] ?? null,
            'customer'    => $r['customer_name'] ?? $r['fund_customer'] ?? null,
            'amount'      => round((float)$r['amount'], 2),
            'date'        => $r['payment_date'] ?? substr((string)$r['created_at'], 0, 10),
            'note'        => $r['notes'] ?? null,
            'kind'        => str_starts_with((string)$r['notes'], 'Partial') ? 'partial' : 'settlement',
        ];
    }, $rows);
    $report['rows'] = count($rows);
    $report['total_amount'] = round($total, 2);

    // Removing a row from `fund_payments` takes it off the cash-in side; the new
    // cash_out then takes the same amount off again. So the safe falls by twice
    // the total, which is the whole size of the original error.
    $report['cash_in_hand_after'] = round((float)$before['cashInHand'] - 2 * $total, 2);
    $report['explanation'] = $total > 0
        ? 'Each row is counted as money in today and will be counted as money out instead, '
          . 'so Cash In Hand falls by twice ' . number_format($total, 2) . '.'
        : 'Nothing to move — no old settlement rows are sitting in the deposits table.';

    // Funds whose running total is larger than the deposits recorded for them.
    // A human has to say whether that money actually arrived.
    $orphans = $pdo->query(
        "SELECT f.`id`, f.`fund_number`, f.`customer_name`, f.`status`,
                ROUND(f.`collected_amount`, 2) AS collected_says,
                ROUND(COALESCE((SELECT SUM(p.`amount`) FROM `fund_payments` p
                                 WHERE p.`fund_id` = f.`id` AND COALESCE(p.`delflag`,0) = 0), 0), 2) AS receipts_say
           FROM `funds` f
          WHERE COALESCE(f.`delflag`, 0) = 0
         HAVING collected_says > receipts_say + 0.01
          ORDER BY collected_says - receipts_say DESC"
    )->fetchAll(PDO::FETCH_ASSOC);
    $report['unreceipted_deposits'] = $orphans;
    if ($orphans) {
        $report['unreceipted_note'] =
            'These funds say more was deposited than there are receipts for — the old '
          . '"Settle in full" button set the total without writing one. Nothing here changes '
          . 'them: whether that money was actually received is not recorded anywhere.';
    }

    if (!$confirmed) {
        $report['next_step'] = $isCli
            ? 'php backend/repair_fund_payouts.php --confirm'
            : 'Take a backup, then reload this URL with ?confirm=YES';
        $finish($report);
    }

    if (!$rows) {
        $report['done'] = 'Nothing to do.';
        $finish($report);
    }

    $pdo->beginTransaction();
    $moved = 0;
    foreach ($rows as $r) {
        $isPartial = str_starts_with((string)$r['notes'], 'Partial');
        $amount    = round((float)$r['amount'], 2);
        $date      = $r['payment_date'] ?: substr((string)$r['created_at'], 0, 10);

        $ledgerId = uuid4();
        $pdo->prepare(
            'INSERT INTO `account_ledger`
               (id, entry_type, title, amount, category, entry_date, notes,
                agent_id, agent_name, payment_method)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        )->execute([
            $ledgerId, 'cash_out',
            'Fund Payout: ' . ($r['customer_name'] ?? $r['fund_customer'] ?? 'Customer')
                . ' (' . ($r['fund_number'] ?? '') . ')',
            $amount, 'Fund Payout', $date,
            'Recovered from the fund passbook, where this payout had been recorded as a deposit. '
                . 'Original note: ' . $r['notes'],
            $r['agent_id'] ?? null, $r['agent_name'] ?? null,
            $r['payment_method'] ?? 'cash',
        ]);

        $pdo->prepare(
            'INSERT INTO `fund_payouts`
               (id, fund_id, fund_number, customer_id, customer_name, kind, units_closed,
                deposit_amount, bonus_amount, payout_amount, payout_date, payment_method,
                ledger_id, agent_id, agent_name, notes)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)'
        )->execute([
            uuid4(), $r['fund_id'], $r['fund_number'] ?? null,
            $r['customer_id'] ?? null, $r['customer_name'] ?? $r['fund_customer'] ?? null,
            $isPartial ? 'partial' : 'settlement',
            round((float)($r['fund_units'] ?? 0), 2),
            $amount, 0.0, $amount,
            $date, $r['payment_method'] ?? 'cash',
            $ledgerId, $r['agent_id'] ?? null, $r['agent_name'] ?? null,
            $r['notes'],
        ]);

        // Deleted, not flagged: a soft-deleted deposit is still a deposit as far
        // as anything reading the passbook by hand is concerned, and the row is
        // preserved verbatim in the payout's notes either way.
        $pdo->prepare('DELETE FROM `fund_payments` WHERE `id` = ?')->execute([$r['id']]);
        $moved++;
    }
    $pdo->commit();

    $after = AccountLedger::getRealtimeSummary();
    $report['moved'] = $moved;
    $report['cash_in_hand_now'] = round((float)$after['cashInHand'], 2);
    $report['fund_payouts_now'] = round((float)($after['fundPayouts'] ?? 0), 2);
    $report['done'] = 'Repaired. Delete backend/repair_fund_payouts.php now.';
} catch (Throwable $e) {
    if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack();
    $report['errors']['repair'] = $e->getMessage();
    $report['mode'] = 'FAILED - rolled back, nothing changed';
}

$finish($report);
