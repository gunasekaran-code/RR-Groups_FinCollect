<?php
class Profile extends Model
{
    protected static string $table = 'profiles';
    protected static array $hidden = ['password_hash', 'reset_otp_hash', 'reset_otp_expires'];

    /**
     * The avatar is a base64 data URL, and it does not belong in a list.
     *
     * Agent Management asks for every profile and draws a 36px face next to
     * each name. With eight agents and sixty customer logins on file that one
     * request answered with 1.88 MB, of which 1.85 MB was photographs — and
     * the table could not paint a single name until the last one had landed.
     * The screen needs four columns out of that to decide anything.
     *
     * Hidden from the default list, `has_photo` reports whether there is one,
     * and `photo.php` serves it per row: lazily, cached, and 304 thereafter.
     * Naming the column explicitly still works, which is how sign-in and
     * `me` get the signed-in user's own picture in a single row.
     */
    protected static array $heavy = ['avatar_url'];

    /** @var array<string,string> */
    protected static array $presence = ['avatar_url' => 'has_photo'];

    public static function findByEmail(string $email): ?array
    {
        return static::firstRaw(' WHERE email = ?', [$email]);
    }

    public static function findByIdentifier(string $input): ?array
    {
        $input = trim($input);
        if ($input === '') return null;
        if (str_contains($input, '@')) {
            return static::firstRaw(' WHERE LOWER(email) = LOWER(?)', [$input]);
        }
        $digits = preg_replace('/\D+/', '', $input);
        if ($digits !== '') {
            return static::firstRaw(
                ' WHERE LOWER(email) = LOWER(?) OR mobile = ? OR REPLACE(REPLACE(REPLACE(mobile, " ", ""), "-", ""), "+", "") LIKE ?',
                [strtolower($input), $input, '%' . $digits]
            );
        }
        return static::firstRaw(' WHERE LOWER(email) = LOWER(?) OR mobile = ?', [strtolower($input), $input]);
    }

    public static function emailTaken(string $email, ?string $exceptId = null): bool
    {
        if ($exceptId) {
            $stmt = Database::pdo()->prepare('SELECT COUNT(*) FROM profiles WHERE email = ? AND id <> ? AND delflag = 0');
            $stmt->execute([$email, $exceptId]);
        } else {
            $stmt = Database::pdo()->prepare('SELECT COUNT(*) FROM profiles WHERE email = ? AND delflag = 0');
            $stmt->execute([$email]);
        }
        return (int)$stmt->fetchColumn() > 0;
    }

    /**
     * Is this mobile number already used by another login?
     *
     * Matters because sign-in accepts a mobile number as the identifier: two
     * active profiles sharing one number would make login pick one at random.
     * Digits are compared so "+91 98765 43210" and "9876543210" collide.
     * Soft-deleted profiles are ignored — a deleted login holds nothing.
     */
    public static function mobileTaken(string $mobile, ?string $exceptId = null): bool
    {
        $digits = preg_replace('/\D+/', '', $mobile);
        if ($digits === '') return false;

        $sql = "SELECT COUNT(*) FROM profiles
                WHERE delflag = 0
                  AND REPLACE(REPLACE(REPLACE(IFNULL(mobile, ''), ' ', ''), '-', ''), '+', '') LIKE ?";
        $binds = ['%' . $digits];
        if ($exceptId) {
            $sql .= ' AND id <> ?';
            $binds[] = $exceptId;
        }
        $stmt = Database::pdo()->prepare($sql);
        $stmt->execute($binds);
        return (int)$stmt->fetchColumn() > 0;
    }

    public static function findPublic(string $id): ?array
    {
        $rows = static::select(' WHERE id = ?', [$id], '', ' LIMIT 1');
        return $rows[0] ?? null;
    }

    /** The login profile linked to a customers row, if any. */
    public static function findByCustomerId(string $customerId): ?array
    {
        return static::firstRaw(' WHERE customer_id = ? AND role = ?', [$customerId, 'customer']);
    }
}
