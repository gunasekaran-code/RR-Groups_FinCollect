<?php
class Customer extends Model
{
    protected static string $table = 'customers';

    /**
     * Every picture a customer row carries, none of which belongs in a list.
     *
     * The scanned papers are the obvious ones — about half a megabyte a
     * customer between the two Aadhaar sides, the PAN card and the signature.
     * `photo_url` was left listable at first, on the reasoning that the table
     * draws it as an avatar on every row and it is the small one. Measured,
     * that reasoning was wrong: at 180 customers the avatars were 3.65 MB of
     * a 3.71 MB response. Ninety-nine per cent of the customers list was
     * photographs of faces, drawn at 36 pixels across.
     *
     * They are served by `photo.php` instead — one cacheable request per
     * picture, only for the rows actually on screen. Naming the column
     * explicitly still returns it, which is how the edit form and the loan
     * application form get it.
     */
    protected static array $heavy = ['photo_url', 'aadhaar_front_url', 'aadhaar_back_url', 'pan_url', 'signature_url'];

    /**
     * Whether there is a photograph, which is one byte rather than 25 KB.
     *
     * The avatar needs to know the difference between "no picture" and
     * "picture not fetched yet". Without it the table asks `photo.php` for
     * every customer, and most of them have never had their photo taken.
     */
    protected static array $presence = ['photo_url' => 'has_photo'];

    /**
     * PAN, normalised — or a refusal.
     *
     * Optional: the column is nullable and plenty of small borrowers do not
     * hold one. But a malformed PAN is worse than a blank one, because it
     * looks like KYC that has been done, and the format used to be checked
     * only by `validateCustomerForm` in the browser.
     *
     * It lives on the model rather than in a controller because there are two
     * write paths — `customers.php` (CustomerController, which also creates
     * the portal login) and `rest.php?table=customers`
     * (CustomerRestController) — and a rule written in one of them is not a
     * rule.
     *
     * Trimmed and upper-cased first, so a PAN typed in lower case is corrected
     * rather than rejected. Call only for a value the request actually
     * carried: a PATCH that does not mention `pan` must be left alone, or
     * editing an address would trip over a legacy row.
     */
    public static function normalisePan($value): ?string
    {
        $pan = strtoupper(trim((string)($value ?? '')));
        if ($pan === '') return null;
        if (!preg_match('/^[A-Z]{5}[0-9]{4}[A-Z]$/', $pan)) {
            json_error('PAN looks like ABCDE1234F, or leave it blank', 400);
        }
        return $pan;
    }

    /**
     * Recompute `customers.loan_status` from the loans that actually exist.
     *
     * The column is denormalised and was only ever written by seed.php, so it
     * never moved off 'none' — a customer with a live loan still showed
     * "No Loan" in the directory. It is kept up to date here instead of being
     * derived at read time because the Customers screen filters and counts on
     * it, and a subquery on every list would not survive the generic model.
     *
     * Precedence: any overdue loan wins, then active, then closed, else none.
     * Soft-deleted loans are ignored — a deleted loan is not a live one.
     *
     * @param string[]|null $customerIds  null recomputes every customer.
     */
    public static function recalcLoanStatus(?array $customerIds = null): void
    {
        $ids = null;
        if ($customerIds !== null) {
            $ids = array_values(array_unique(array_filter($customerIds)));
            if (!$ids) return;
        }

        $scope = '';
        $binds = [];
        if ($ids !== null) {
            $scope = ' WHERE c.id IN (' . implode(',', array_fill(0, count($ids), '?')) . ')';
            $binds = $ids;
        }

        // One statement so a customer with many loans cannot be half-updated.
        $sql = "
            UPDATE customers c
            SET c.loan_status = (
                SELECT CASE
                    WHEN SUM(l.status = 'overdue') > 0 THEN 'overdue'
                    WHEN SUM(l.status = 'active')  > 0 THEN 'active'
                    WHEN COUNT(*) > 0              THEN 'closed'
                    ELSE 'none'
                END
                FROM loans l
                WHERE l.customer_id = c.id AND l.delflag = 0
            )
            $scope
        ";

        try {
            Database::pdo()->prepare($sql)->execute($binds);
        } catch (\Throwable $e) {
            // Never let a status refresh break the write that triggered it.
            error_log('Customer::recalcLoanStatus failed: ' . $e->getMessage());
        }
    }

    /** Customer ids referenced by the given loan ids (for a targeted recalc). */
    public static function idsForLoans(array $loanIds): array
    {
        $loanIds = array_values(array_unique(array_filter($loanIds)));
        if (!$loanIds) return [];

        $ph = implode(',', array_fill(0, count($loanIds), '?'));
        try {
            $stmt = Database::pdo()->prepare(
                "SELECT DISTINCT customer_id FROM loans WHERE id IN ($ph) AND customer_id IS NOT NULL"
            );
            $stmt->execute($loanIds);
            return $stmt->fetchAll(PDO::FETCH_COLUMN, 0) ?: [];
        } catch (\Throwable $e) {
            return [];
        }
    }

    /**
     * Carry a customer's photo through to their login.
     *
     * The photo lives on `customers.photo_url` — what the admin uploads, and
     * what the customer directory, the profile modal and the loan application
     * form all draw. The customer's OWN panel draws `profiles.avatar_url`,
     * and the two were joined exactly once: at the moment the login was
     * created (CustomerController::createLogin copies it across). A photo
     * added or replaced afterwards went nowhere. The admin saw the customer's
     * face on every screen they opened; the customer signed in to their
     * initials.
     *
     * What this will not do is overwrite a picture the customer chose. The
     * Profile screen lets them set their own, and an admin correcting an
     * address should not silently replace it with a KYC mugshot. So the copy
     * happens in exactly two cases:
     *
     *   - the login has no avatar at all, or
     *   - its avatar is the photo being replaced, which means it was
     *     mirroring this field rather than holding a choice.
     *
     * `$previousPhoto` is what the customer row held BEFORE the write, which
     * is the only way to tell those apart; callers read it while they still
     * can. Without it, only the first case applies — the cautious way round,
     * because replacing somebody's own picture cannot be undone from the UI.
     */
    public static function syncLoginAvatar(string $customerId, ?string $previousPhoto = null): void
    {
        if ($customerId === '') return;
        $pdo = Database::pdo();

        $stmt = $pdo->prepare('SELECT `photo_url` FROM `customers` WHERE `id` = ? LIMIT 1');
        $stmt->execute([$customerId]);
        $photo = $stmt->fetchColumn();
        $photo = (is_string($photo) && $photo !== '') ? $photo : null;

        $stmt = $pdo->prepare(
            "SELECT `id`, `avatar_url` FROM `profiles`
              WHERE `customer_id` = ? AND `role` = 'customer' AND `delflag` = 0"
        );
        $stmt->execute([$customerId]);
        $logins = $stmt->fetchAll(PDO::FETCH_ASSOC);
        if (!$logins) return;

        $prev = ($previousPhoto !== null && $previousPhoto !== '') ? $previousPhoto : null;
        $update = $pdo->prepare('UPDATE `profiles` SET `avatar_url` = ? WHERE `id` = ?');

        foreach ($logins as $login) {
            $current = $login['avatar_url'] ?? null;
            if ($current === '') $current = null;
            if ($current === $photo) continue;                       // already in step
            if ($current !== null && $current !== $prev) continue;    // theirs — leave it
            $update->execute([$photo, $login['id']]);
        }
    }}
