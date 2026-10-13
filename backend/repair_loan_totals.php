<?php
/**
 * Fill in the derived money figures on loans that were stored without them.
 *
 * `emi`, `total_interest` and `total_repayment` were only ever computed in the
 * browser and posted alongside the loan. Any write that did not come from the
 * Create Loan screen left all three at zero — and a zero `total_repayment` is
 * not a harmless blank:
 *
 *   - The Account Book works out what a borrower was handed as
 *     `total_repayment − total_interest`. A zero sent it down the fallback
 *     path and booked the FULL PRINCIPAL as cash out. On a ₹20,000 weekly
 *     loan the borrower took ₹18,000 and ₹2,000 stayed in the safe as
 *     upfront interest, but the book showed ₹20,000 leaving — so Cash In Hand
 *     read ₹2,000 lower than the cash actually in the box.
 *   - The Repayment Schedule screen showed the same zero, as
 *     "Total Repayment ₹0" above a loan that plainly repays ₹20,000.
 *
 * The figures are not invented. Every one is a pure function of principal,
 * rate, type and duration, all of which are stored — the same function the
 * Create Loan screen uses to quote them to the borrower before approval
 * (Loan::deriveTotals, mirroring frontend/src/calc.ts).
 *
 * Only non-positive fields are filled. A loan carrying its own figures is left
 * exactly as it is, so a rescheduled or hand-adjusted total is never touched.
 *
 * Usage
 *   Browser (production):  https://rrgroupscbe.com/backend/repair_loan_totals.php
 *   CLI (local):           php backend/repair_loan_totals.php
 *
 * Both are a DRY RUN by default: they list every loan that would change, the
 * exact effect on Cash In Hand, and change nothing. Add ?confirm=YES (or
 * --confirm on the CLI) to apply it. Take a backup first.
 *
 * This is safe to delete once it has been run.
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

$before = (float)AccountLedger::getRealtimeSummary()['cashInHand'];

$loans = $pdo->query(
    'SELECT * FROM `loans` WHERE `delflag` = 0 ORDER BY `loan_number` ASC'
)->fetchAll(PDO::FETCH_ASSOC);

$planned = [];
foreach ($loans as $loan) {
    $fill = Loan::deriveTotals($loan);
    if (!$fill) continue;
    $planned[] = [
        'id'     => $loan['id'],
        'number' => $loan['loan_number'],
        'type'   => $loan['loan_type'],
        'amount' => (float)$loan['loan_amount'],
        'was'    => [
            'emi'             => (float)$loan['emi'],
            'total_interest'  => (float)$loan['total_interest'],
            'total_repayment' => (float)$loan['total_repayment'],
        ],
        'fill'      => $fill,
        'disbursed' => Loan::disbursedAmount($loan),
    ];
}

echo ($confirm ? "APPLYING\n" : "DRY RUN — nothing has been changed\n");
echo str_repeat('=', 78), "\n";
echo count($loans), " live loans, ", count($planned), " missing at least one figure\n\n";

if (!$planned) {
    echo "Nothing to repair.\n";
    exit(0);
}

printf("%-10s %-17s %10s %10s %12s %12s\n", 'LOAN', 'TYPE', 'PRINCIPAL', 'DISBURSED', 'FILLING', 'WAS');
foreach ($planned as $p) {
    $cols = implode(',', array_keys($p['fill']));
    printf(
        "%-10s %-17s %10s %10s %12s %12s\n",
        $p['number'], $p['type'],
        number_format($p['amount'], 2), number_format($p['disbursed'], 2),
        $cols, number_format($p['was']['total_repayment'], 2)
    );
    foreach ($p['fill'] as $col => $val) {
        printf("             %-18s %s -> %s\n", $col, number_format($p['was'][$col], 2), number_format((float)$val, 2));
    }
}

if (!$confirm) {
    echo "\nRe-run with ", ($cli ? '--confirm' : '?confirm=YES'), " to apply.\n";
    exit(0);
}

$pdo->beginTransaction();
try {
    foreach ($planned as $p) {
        $set = [];
        $binds = [];
        foreach ($p['fill'] as $col => $val) {
            $set[] = "`$col` = ?";
            $binds[] = $val;
        }
        $binds[] = $p['id'];
        $pdo->prepare('UPDATE `loans` SET ' . implode(', ', $set) . ' WHERE `id` = ?')->execute($binds);
    }
    $pdo->commit();
} catch (\Throwable $e) {
    $pdo->rollBack();
    echo "\nFAILED, nothing changed: ", $e->getMessage(), "\n";
    exit(1);
}

$after = (float)AccountLedger::getRealtimeSummary()['cashInHand'];
echo "\n", count($planned), " loans repaired.\n";
printf("Cash In Hand: %s -> %s  (%s%s)\n",
    number_format($before, 2), number_format($after, 2),
    $after >= $before ? '+' : '', number_format($after - $before, 2));
if (abs($after - $before) >= 0.01) {
    echo "\nThe difference is upfront interest that never left the safe but was\n";
    echo "being booked as cash out.\n";
} else {
    // Expected, and not a sign the repair did nothing. The Account Book
    // reconstructs a missing total_repayment rather than falling back to the
    // principal, so the figure it showed was already right. What this changed
    // is the stored columns — which is what the Repayment Schedule screen and
    // the loan card read, and where "Total Repayment ₹0" came from.
    echo "\nCash In Hand did not move, which is expected: the Account Book already\n";
    echo "reconstructs a missing repayment, so the book was right before this ran.\n";
    echo "What this fixed is the stored figures the other screens read.\n";
}
echo "\nDelete this file once you are satisfied.\n";
