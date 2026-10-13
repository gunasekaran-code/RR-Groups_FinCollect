<?php
/**
 * Give funds back their weekly amount, and their passbooks back their weeks.
 *
 * `funds.weekly_amount` is the figure everything else hangs off. A fund
 * written without it does not fail — it goes quietly wrong:
 *
 *   - Every deposit is filed as WEEK 1. Which week a receipt settles is
 *     worked out as `collected ÷ weekly`, and a zero divisor fell back to a
 *     constant 1, so a passbook with two deposits read "WK 1, WK 1" and
 *     announced the next one due as week 2. Compare a healthy fund, which
 *     reads 1, 2, 3 and calls the next one week 4.
 *   - The passbook header read "Total deposit (₹0 × 50 weeks)  ₹10,000" —
 *     the total has a stored figure to fall back on, the per-week amount did
 *     not.
 *   - "Next deposit due" offered to collect ₹0.
 *   - Progress never advanced, because weeks-paid is the same division.
 *
 * Nothing is invented. A fund that knows its deposit target and its term
 * knows what a week costs, and both are stored. `deposit_amount` is preferred
 * over `total_amount` because the latter includes the maturity bonus, which
 * the customer never pays in.
 *
 * Existing receipts are renumbered by the same rule the live code uses: the
 * money already in when the receipt was taken, divided by the weekly amount,
 * plus one. So a receipt covering two weeks still advances the book by two,
 * and a half payment does not advance it at all.
 *
 * Usage
 *   Browser (production):  https://rrgroupscbe.com/backend/repair_fund_weeks.php
 *   CLI (local):           php backend/repair_fund_weeks.php
 *
 * Both are a DRY RUN by default: they list every fund and every receipt that
 * would change and alter nothing. Add ?confirm=YES (or --confirm on the CLI)
 * to apply it. Take a backup first.
 *
 * No money moves. Only `weekly_amount`, `deposit_amount` and the week NUMBER
 * on a receipt are touched — never an amount, a date or a balance.
 *
 * Safe to delete once it has been run.
 */
require __DIR__ . '/bootstrap.php';


// Not a public URL. See require_maintenance_admin() in bootstrap.php.
require_maintenance_admin();
$cli     = PHP_SAPI === 'cli';
$confirm = $cli
    ? in_array('--confirm', $argv ?? [], true)
    : (($_GET['confirm'] ?? '') === 'YES');

if (!$cli) header('Content-Type: text/plain; charset=utf-8');

$pdo = Database::pdo();

$funds = $pdo->query('SELECT * FROM `funds` WHERE `delflag` = 0 ORDER BY `fund_number` ASC')
             ->fetchAll(PDO::FETCH_ASSOC);

$planned = [];
$skipped = [];
foreach ($funds as $fund) {
    $fill   = Fund::deriveFields($fund);
    $weekly = Fund::weeklyAmount(array_merge($fund, $fill));

    $stmt = $pdo->prepare(
        'SELECT `id`, `week_no`, `amount`, `payment_date`
           FROM `fund_payments`
          WHERE `fund_id` = ? AND `delflag` = 0
          ORDER BY `payment_date` ASC, `created_at` ASC'
    );
    $stmt->execute([$fund['id']]);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

    // Replay the passbook: each receipt settles the week the money standing
    // before it had reached. Identical to the rule in FundService::collect.
    $weeks   = (int)$fund['weeks'];
    $running = 0.0;
    $renum   = [];
    foreach ($rows as $i => $r) {
        if ($weekly > 0) {
            $wk = (int)floor(round($running, 2) / $weekly) + 1;
        } else {
            $wk = $i + 1;   // nothing to divide by; at least never two the same
        }
        if ($weeks > 0) $wk = min($wk, $weeks);
        $wk = max(1, $wk);
        if ($wk !== (int)$r['week_no']) {
            $renum[] = ['id' => $r['id'], 'from' => (int)$r['week_no'], 'to' => $wk,
                        'amount' => (float)$r['amount'], 'date' => $r['payment_date']];
        }
        $running = round($running + (float)$r['amount'], 2);
    }

    // Only renumber a passbook that is actually broken.
    //
    // The replay orders receipts by payment date; the live code numbered them
    // in the order they were ENTERED. For a fund whose receipts were typed in
    // one sitting with the dates out of order, those two disagree — and the
    // stored numbers are a perfectly good 1, 2, 3. Rewriting them would be
    // this script inventing a problem to fix, on the strength of an ordering
    // nobody has said is the right one.
    //
    // Broken means one of two things, both unambiguous:
    //   - the fund had no weekly amount, so every receipt went down the
    //     constant-1 branch and the passbook reads "WK 1, WK 1, WK 1";
    //   - the numbers contain a duplicate, whatever the cause.
    $nums      = array_map(fn($r) => (int)$r['week_no'], $rows);
    $duplicate = count($nums) !== count(array_unique($nums));
    $noWeekly  = array_key_exists('weekly_amount', $fill);
    $broken    = $duplicate || $noWeekly;

    if ($renum && !$broken) {
        $skipped[] = [
            'number' => $fund['fund_number'] ?? '(no number)',
            'name'   => $fund['customer_name'] ?? '',
            'nums'   => $nums,
        ];
        $renum = [];
    }

    if (!$fill && !$renum) continue;
    $planned[] = ['fund' => $fund, 'fill' => $fill, 'weekly' => $weekly, 'renum' => $renum, 'rows' => count($rows)];
}

echo ($confirm ? "APPLYING\n" : "DRY RUN — nothing has been changed\n");
echo str_repeat('=', 78), "\n";
echo count($funds), " live funds, ", count($planned), " needing repair\n\n";

$report = function () use (&$skipped) {
    if (!$skipped) return;
    echo "
Left alone — the numbering there is already a clean sequence and
";
    echo "only the date-order reading differs. Nothing a customer would call
";
    echo "wrong, so it is not rewritten:
";
    foreach ($skipped as $k) {
        printf("  %-22s %-22s weeks %s
", $k['number'], $k['name'], implode(', ', $k['nums']));
    }
};

if (!$planned) { echo "Nothing to repair.\n"; $report(); exit(0); }

$receiptTotal = 0;
foreach ($planned as $p) {
    $f = $p['fund'];
    printf(
        "%-22s  %s  weeks=%d  deposits=%d\n",
        $f['fund_number'] ?? '(no number)',
        $f['customer_name'] ?? '',
        (int)$f['weeks'],
        $p['rows']
    );
    foreach ($p['fill'] as $col => $val) {
        printf("    %-16s %12s  ->  %s\n", $col, number_format((float)$f[$col], 2), number_format((float)$val, 2));
    }
    foreach ($p['renum'] as $r) {
        printf("    receipt %s  %s  WK %d -> WK %d\n",
            substr($r['date'], 0, 10), str_pad('+' . number_format($r['amount'], 2), 12, ' ', STR_PAD_LEFT),
            $r['from'], $r['to']);
        $receiptTotal++;
    }
    echo "\n";
}
echo "$receiptTotal receipt(s) would be renumbered.\n";
$report();

if (!$confirm) {
    echo "\nRe-run with ", ($cli ? '--confirm' : '?confirm=YES'), " to apply.\n";
    exit(0);
}

$pdo->beginTransaction();
try {
    foreach ($planned as $p) {
        if ($p['fill']) {
            $set = [];
            $binds = [];
            foreach ($p['fill'] as $col => $val) { $set[] = "`$col` = ?"; $binds[] = $val; }
            $binds[] = $p['fund']['id'];
            $pdo->prepare('UPDATE `funds` SET ' . implode(', ', $set) . ' WHERE `id` = ?')->execute($binds);
        }
        $upd = $pdo->prepare('UPDATE `fund_payments` SET `week_no` = ? WHERE `id` = ?');
        foreach ($p['renum'] as $r) {
            $upd->execute([$r['to'], $r['id']]);
        }
    }
    $pdo->commit();
} catch (\Throwable $e) {
    $pdo->rollBack();
    echo "\nFAILED, nothing changed: ", $e->getMessage(), "\n";
    exit(1);
}

echo "\n", count($planned), " fund(s) repaired, $receiptTotal receipt(s) renumbered.\n";
echo "No amount, date or balance was touched — only the week a receipt is filed under.\n";
echo "\nDelete this file once you are satisfied.\n";
