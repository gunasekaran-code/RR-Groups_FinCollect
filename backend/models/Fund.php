<?php
class Fund extends Model
{
    protected static string $table = 'funds';

    /**
     * What one week of this fund costs the customer.
     *
     * `weekly_amount` is the figure everything else hangs off — the passbook
     * header, the "next deposit due" line, how far along the fund is, and
     * which week a receipt settles. A fund written without it does not fail;
     * it goes quietly wrong:
     *
     *   - Every receipt is filed as week 1, because the week a deposit settles
     *     is worked out as `collected ÷ weekly`, and a zero divisor falls back
     *     to a constant 1. Two deposits then read "WK 1, WK 1" and the next
     *     one due is announced as week 2 — which is how this was noticed.
     *   - The passbook header reads "Total deposit (₹0 × 50 weeks) ₹10,000",
     *     because the total has a stored figure to fall back on and the
     *     per-week amount does not.
     *   - Progress never moves: weeks-paid is also `collected ÷ weekly`.
     *
     * Nothing is invented here. A fund that knows what it collects in total
     * and over how many weeks knows what a week costs, and both of those are
     * stored. `deposit_amount` is preferred over `total_amount` because the
     * latter includes the maturity bonus, which the customer never pays in.
     */
    public static function weeklyAmount(array $fund): float
    {
        $stored = round((float)($fund['weekly_amount'] ?? 0), 2);
        if ($stored > 0) return $stored;

        $weeks = (int)($fund['weeks'] ?? 0);
        if ($weeks <= 0) return 0.0;

        $target = round((float)($fund['deposit_amount'] ?? 0), 2);
        if ($target <= 0) {
            // total_amount carries the bonus; take it back out before dividing.
            $target = round((float)($fund['total_amount'] ?? 0) - (float)($fund['bonus'] ?? 0), 2);
        }
        if ($target <= 0) return 0.0;

        return round($target / $weeks, 2);
    }

    /**
     * The fields a fund is missing, ready to be written back.
     *
     * Only ever fills what is absent, so a fund carrying its own figures is
     * never overwritten — a hand-adjusted weekly amount stays as it is.
     */
    public static function deriveFields(array $fund): array
    {
        $fill = [];
        if (round((float)($fund['weekly_amount'] ?? 0), 2) <= 0) {
            $weekly = self::weeklyAmount($fund);
            if ($weekly > 0) $fill['weekly_amount'] = $weekly;
        }
        if (round((float)($fund['deposit_amount'] ?? 0), 2) <= 0) {
            $weekly = self::weeklyAmount($fund);
            $weeks  = (int)($fund['weeks'] ?? 0);
            if ($weekly > 0 && $weeks > 0) $fill['deposit_amount'] = round($weekly * $weeks, 2);
        }
        return $fill;
    }
}