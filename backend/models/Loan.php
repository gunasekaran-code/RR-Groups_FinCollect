<?php
class Loan extends Model
{
    protected static string $table = 'loans';

    /**
     * Sequential HP Number starting at RR001, auto-incrementing sequentially
     * (RR002, RR003, etc.) based on existing database entries.
     */
    public static function nextLoanNumber(): string
    {
        $pdo = Database::pdo();
        $stmt = $pdo->query("SELECT loan_number FROM loans WHERE loan_number LIKE 'RR%'");
        $numbers = $stmt->fetchAll(PDO::FETCH_COLUMN);

        $max = 0;
        foreach ($numbers as $num) {
            if (preg_match('/^RR(\d+)$/i', trim($num), $m)) {
                $val = (int)$m[1];
                if ($val > $max) {
                    $max = $val;
                }
            }
        }

        $next = $max + 1;
        return 'RR' . str_pad((string)$next, 3, '0', STR_PAD_LEFT);
    }

    /**
     * Fill in a loan's derived money figures when they are missing.
     *
     * `emi`, `total_interest` and `total_repayment` were only ever computed in
     * the browser (frontend/src/calc.ts) and posted alongside the loan. Any
     * write that did not come from the Create Loan screen — an import, a
     * partial PATCH, an older build of the form — landed a loan with all three
     * at zero, and nothing downstream could tell that apart from a loan that
     * really repays nothing.
     *
     * A zero `total_repayment` is not a harmless blank. The Account Book works
     * out what a borrower was handed as `total_repayment - total_interest`, so
     * a zero sent it down the fallback path and booked the *full principal* as
     * cash out: ₹20,000 handed over on a loan where ₹18,000 changed hands and
     * ₹2,000 was kept as interest. The Repayment Schedule screen showed the
     * same zero as "Total Repayment ₹0".
     *
     * The figures are not guesses — every one of them is a pure function of
     * principal, rate, type and duration, which are all stored. This mirrors
     * calc.ts exactly; the two are kept in step by t59.
     *
     * Only absent or non-positive fields are filled. A loan carrying its own
     * figures keeps them, so rescheduling or a hand-adjusted total is never
     * overwritten.
     */
    public static function deriveTotals(array $row): array
    {
        $principal = (float)($row['loan_amount'] ?? 0);
        $rate      = (float)($row['interest_percentage'] ?? 0);
        $duration  = (int)($row['loan_duration'] ?? 0);
        $type      = strtolower(trim((string)($row['loan_type'] ?? 'monthly')));
        if ($principal <= 0) return [];

        $r2 = fn(float $n): float => round($n, 2);

        if ($type === 'weekly') {
            // Interest is deducted at disbursement; the borrower repays the
            // principal over the weeks. 10 weeks is the only weekly plan.
            $weeks    = $duration > 0 ? $duration : 10;
            $interest = $r2($principal * $rate / 100);
            $emi      = $r2($principal / $weeks);
            $repay    = $principal;
        } elseif ($type === 'daily') {
            // Two daily plans, told apart by their length — the same test the
            // Create Loan screen uses. 100 days deducts the interest upfront;
            // 60 days adds it on top.
            $days     = $duration > 0 ? $duration : 60;
            $interest = $r2($principal * $rate / 100);
            if ($days >= 100) {
                $repay = $principal;
                $emi   = $r2($principal / $days);
            } else {
                $repay = $r2($principal + $interest);
                $emi   = $r2($repay / $days);
            }
        } elseif ($type === 'monthly_interest') {
            $months   = $duration > 0 ? $duration : 12;
            $monthly  = $r2($principal * $rate / 100);
            $interest = $r2($monthly * $months);
            $repay    = $r2($principal + $interest);
            $emi      = $monthly;
        } else {
            $months = $duration;
            if ($months <= 0) return [];
            $emi      = $r2(($principal / $months) + $r2($principal * $rate / 100));
            $interest = $r2($emi * $months - $principal);
            $repay    = $r2($emi * $months);
        }

        // A stored total_repayment outranks the derived one, and the interest
        // must then be read OUT of it rather than recomputed. Several loans
        // here carry a repayment that already includes their interest while
        // total_interest itself sits at zero — deriving ₹5,000 of interest for
        // a loan whose own totals say ₹1,000 would have reported ₹6,000 handed
        // to a borrower who took ₹10,000. Never contradict a figure the loan
        // already carries.
        // Which side of the loan the interest sits on is a property of the
        // PLAN, not of the arithmetic. Weekly and the 100-day daily plan hold
        // it back at disbursement, so their repayment is the bare principal
        // and the interest is charged on top of nothing visible. Every other
        // plan adds it in, so the interest is whatever the repayment exceeds
        // the principal by — and a monthly loan repaying exactly its principal
        // charges no interest at all, rather than secretly deducting some.
        $upfrontPlan = $type === 'weekly' || ($type === 'daily' && ($duration > 0 ? $duration : 60) >= 100);
        $storedRepay = (float)($row['total_repayment'] ?? 0);
        if ($storedRepay > 0) {
            $interest = $upfrontPlan && $storedRepay <= $principal
                ? $r2($principal * $rate / 100)
                : $r2(max($storedRepay - $principal, 0.0));
        }

        $fill = [];
        if ((float)($row['emi'] ?? 0) <= 0             && $emi > 0)      $fill['emi'] = $emi;
        if ((float)($row['total_interest'] ?? 0) <= 0  && $interest > 0) $fill['total_interest'] = $interest;
        if ($storedRepay <= 0                          && $repay > 0)    $fill['total_repayment'] = $repay;
        return $fill;
    }

    /**
     * What the borrower actually walked away with.
     *
     * `total_repayment - total_interest` on every plan: the interest is either
     * already inside the repayment (monthly, 60-day daily) or was held back at
     * disbursement (weekly, 100-day daily). Capped at the principal, because
     * no borrower is handed more than the loan.
     */
    public static function disbursedAmount(array $row): float
    {
        $principal = (float)($row['loan_amount'] ?? 0);
        if ($principal <= 0) return 0.0;
        $filled  = self::deriveTotals($row) + $row;
        $repay   = (float)($filled['total_repayment'] ?? 0);
        $interest = (float)($filled['total_interest'] ?? 0);
        if ($repay <= 0) return $principal;
        return round(min(max($repay - $interest, 0.0), $principal), 2);
    }}
