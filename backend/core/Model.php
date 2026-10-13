<?php
// Base data model: schema introspection, type casting, and CRUD builders.
// Concrete models set $table (and optionally $hidden).

abstract class Model
{
    protected static string $table = '';
    /** Columns never returned to clients (e.g. password_hash). */
    protected static array $hidden = [];

    /** table name => model class, used by rest.php to resolve ?table=. */
    private const REGISTRY = [
        'profiles'           => Profile::class,
        'customers'          => Customer::class,
        'loans'              => Loan::class,
        'repayment_schedule' => RepaymentSchedule::class,
        'collections'        => Collection::class,
        'chit_groups'        => ChitGroup::class,
        'chit_members'       => ChitMember::class,
        'chit_schedules'     => ChitSchedule::class,
        'chit_payments'      => ChitPayment::class,
        'chit_passbook'      => ChitPassbook::class,
        'funds'              => Fund::class,
        'fund_payments'      => FundPayment::class,
        // Read-only through rest.php — FundPayoutController refuses anything
        // else. The Funds list needs every payout at once to know which cards
        // still owe money; writing one is a transaction and lives in funds.php.
        'fund_payouts'       => FundPayout::class,
        'handovers'          => Handover::class,
        'notifications'      => Notification::class,
        'settings'           => Setting::class,
        'push_subscriptions' => PushSubscription::class,
        'account_ledger'     => AccountLedger::class,
        'promo_popups'       => PromoPopup::class,
        'recycle_bin'        => RecycleBin::class,
    ];

    public static function forTable(string $table): ?string
    {
        return self::REGISTRY[$table] ?? null;
    }

    public static function table(): string
    {
        return static::$table;
    }

    /**
     * Columns a list read should not carry unless it asks for them by name.
     *
     * These are the base64 image columns — scanned Aadhaar cards, PAN cards,
     * signatures, payment proofs. One of them is a few hundred kilobytes and
     * that is fine; a hundred rows of them is fifty megabytes, and PHP needs
     * that much again to turn it into JSON. On a shared host it exhausts
     * memory_limit, and a memory exhaustion is a FATAL rather than an
     * exception — so it slips past `Model::select`'s try/catch and past
     * bootstrap's exception handler, and the browser gets a bare 500 with
     * nothing in it to explain itself.
     *
     * That is not hypothetical: it took the live site down on every screen
     * that loads customers, after months of documents being photographed at
     * the door. Declaring them here means a table cannot quietly become too
     * heavy to list.
     *
     * @return string[]
     */
    public static function heavyColumns(): array
    {
        return static::$heavy;
    }

    /** @var string[] */
    protected static array $heavy = [];

    /**
     * Heavy columns worth reporting the *existence* of, without the contents.
     *
     * A list read cannot afford to carry a customer's photograph, but it can
     * easily afford one byte saying whether there is one. Without that the
     * client cannot tell "no picture" from "picture not fetched yet", so it
     * asks for every avatar — and gets an error back for everyone whose photo
     * has not been taken yet. Thirty of thirty-two customers here, which is a
     * console full of red 404s describing something perfectly normal.
     *
     * Keyed by the heavy column, valued by the name the flag is returned
     * under. Declared only where something reads it, so tables do not pay for
     * flags nobody looks at.
     *
     * @return array<string,string>
     */
    public static function presenceFlags(): array
    {
        return static::$presence;
    }

    /** @var array<string,string> */
    protected static array $presence = [];

    /** column name => MySQL type string (cached per table). */
    public static function columns(): array
    {
        static $cache = [];
        $t = static::$table;
        if (!isset($cache[$t])) {
            try {
                $rows = Database::pdo()->query("SHOW COLUMNS FROM `$t`")->fetchAll();
                $cols = [];
                foreach ($rows as $r) {
                    $cols[$r['Field']] = strtolower($r['Type']);
                }
                $cache[$t] = $cols;
            } catch (\Throwable $e) {
                $cache[$t] = [];
            }
        }
        return $cache[$t];
    }

    /** Cast numeric columns to real numbers and drop hidden columns. */
    public static function castRows(array $rows): array
    {
        $types = static::columns();
        $hidden = static::$hidden;
        return array_map(function ($row) use ($types, $hidden) {
            foreach ($hidden as $h) {
                unset($row[$h]);
            }
            foreach ($row as $k => $v) {
                if ($v === null || !isset($types[$k])) continue;
                $t = $types[$k];
                if (str_starts_with($t, 'decimal') || str_starts_with($t, 'float') || str_starts_with($t, 'double')) {
                    $row[$k] = (float)$v;
                } elseif (str_starts_with($t, 'int') || str_starts_with($t, 'bigint')
                       || str_starts_with($t, 'smallint') || str_starts_with($t, 'mediumint')
                       || str_starts_with($t, 'tinyint')) {
                    $row[$k] = (int)$v;
                }
            }
            return $row;
        }, $rows);
    }

    private static function coerce($v)
    {
        if (is_bool($v)) return $v ? 1 : 0;
        if (is_array($v)) return json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        return $v;
    }

    /**
     * Coerce a value for a specific column type. Converts JavaScript ISO 8601
     * datetimes (e.g. "2026-07-16T10:20:30.123Z") into MySQL's expected
     * "Y-m-d H:i:s" / "Y-m-d" so strict mode accepts them.
     */
    private static function normalize($v, string $type)
    {
        $v = self::coerce($v);
        if (is_string($v) && $v !== '') {
            if (str_starts_with($type, 'datetime') || str_starts_with($type, 'timestamp')) {
                if (strpbrk($v, 'TZ') !== false) {
                    $ts = strtotime($v);
                    if ($ts !== false) return date('Y-m-d H:i:s', $ts);
                }
            } elseif (str_starts_with($type, 'date') && strpos($v, 'T') !== false) {
                return substr($v, 0, 10);
            }
        }
        return $v;
    }

    public static function normalizeWhere(string $where): string
    {
        $trimmed = trim($where);
        if ($trimmed === '') return '';
        if (stripos($trimmed, 'WHERE') === 0) {
            return ' ' . $trimmed;
        }
        return ' WHERE ' . $trimmed;
    }

    /**
     * SELECT with pre-built WHERE/ORDER/LIMIT fragments. Returns cast rows.
     *
     * `$columnList` comes from QueryParser::columnList, which only ever
     * returns `*` or a backtick-quoted list of this table's real columns —
     * nothing from the query string reaches here as SQL. It defaults to `*`
     * so every existing caller keeps the behaviour it had.
     */
    public static function select(string $where, array $binds, string $order = '', string $limit = '', string $columnList = '*'): array
    {
        try {
            $whereSql = self::normalizeWhere($where);
            $select = $columnList === '' ? '*' : $columnList;
            $stmt = Database::pdo()->prepare("SELECT $select FROM `" . static::$table . "`$whereSql$order$limit");
            $stmt->execute($binds);
            return static::castRows($stmt->fetchAll());
        } catch (\Throwable $e) {
            return [];
        }
    }

    /** Raw first row INCLUDING hidden columns (used for auth). */
    public static function firstRaw(string $where, array $binds): ?array
    {
        $whereSql = self::normalizeWhere($where);
        $stmt = Database::pdo()->prepare("SELECT * FROM `" . static::$table . "`$whereSql LIMIT 1");
        $stmt->execute($binds);
        return $stmt->fetch() ?: null;
    }

    /**
     * Insert one or many rows. Generates a UUID id when the table has an id
     * column and none is supplied. Returns the inserted rows (cast).
     */
    public static function insertRows(array $rows, bool $upsert = false): array
    {
        $columns = static::columns();
        $pdo = Database::pdo();
        $ids = [];
        foreach ($rows as $row) {
            if (!is_array($row)) continue;
            $data = [];
            foreach ($row as $k => $v) {
                if (isset($columns[$k])) $data[$k] = self::normalize($v, $columns[$k]);
            }
            if (isset($columns['id']) && empty($data['id'])) {
                $data['id'] = uuid4();
            }
            if (!$data) {
                json_error('No valid columns to insert', 400);
            }
            $cols = array_keys($data);
            $ph = implode(',', array_fill(0, count($cols), '?'));
            $colList = implode(',', array_map(fn($c) => "`$c`", $cols));
            $sql = "INSERT INTO `" . static::$table . "` ($colList) VALUES ($ph)";
            if ($upsert) {
                $updates = array_map(fn($c) => "`$c` = VALUES(`$c`)", $cols);
                // Re-registering a device (push endpoint, passkey) upserts onto
                // a UNIQUE key. If that row was soft-deleted the upsert would
                // revive it still flagged, leaving it invisible to every read.
                if (isset($columns['delflag']) && !isset($data['delflag'])) {
                    $updates[] = '`delflag` = 0';
                    if (isset($columns['deleted_at'])) $updates[] = '`deleted_at` = NULL';
                    if (isset($columns['deleted_by'])) $updates[] = '`deleted_by` = NULL';
                }
                $sql .= " ON DUPLICATE KEY UPDATE " . implode(',', $updates);
            }
            $pdo->prepare($sql)->execute(array_values($data));
            $ids[] = $data['id'] ?? $pdo->lastInsertId();
        }
        if (!$ids || !isset($columns['id'])) {
            return [];
        }
        $ph = implode(',', array_fill(0, count($ids), '?'));
        return static::select(" WHERE `id` IN ($ph)", $ids);
    }

    /** UPDATE rows matching $where with $data. Returns updated rows (cast). */
    public static function updateWhere(array $data, string $where, array $binds): array
    {
        $columns = static::columns();
        $set = [];
        $setBinds = [];
        foreach ($data as $k => $v) {
            if (isset($columns[$k])) {
                $set[] = "`$k` = ?";
                $setBinds[] = self::normalize($v, $columns[$k]);
            }
        }
        if (!$set) {
            json_error('No valid columns to update', 400);
        }
        $whereSql = self::normalizeWhere($where);
        $sql = "UPDATE `" . static::$table . "` SET " . implode(', ', $set) . $whereSql;
        Database::pdo()->prepare($sql)->execute([...$setBinds, ...$binds]);
        return static::select($whereSql, $binds);
    }

    public static function deleteWhere(string $where, array $binds): void
    {
        $whereSql = self::normalizeWhere($where);
        Database::pdo()->prepare("DELETE FROM `" . static::$table . "`" . $whereSql)->execute($binds);
    }
}
