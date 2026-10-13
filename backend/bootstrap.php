<?php
// ============================================================
//  Bootstrap: config, PSR-style autoloader, and HTTP helpers.
//  Every entry point (auth.php, rest.php, users.php) requires this.
// ============================================================

$GLOBALS['app_config'] = require __DIR__ . '/config.php';

// Normalize & support method override for servers (e.g. LiteSpeed) that block PATCH / PUT / DELETE:
$methodOverride = $_SERVER['HTTP_X_HTTP_METHOD_OVERRIDE']
    ?? $_SERVER['REDIRECT_HTTP_X_HTTP_METHOD_OVERRIDE']
    ?? $_GET['_method']
    ?? $_POST['_method']
    ?? null;
if ($methodOverride && in_array(strtoupper($methodOverride), ['GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'], true)) {
    $_SERVER['REQUEST_METHOD'] = strtoupper($methodOverride);
}

// Global uncaught exception handler returning JSON error
set_exception_handler(function (\Throwable $e) {
    if (!headers_sent()) {
        send_cors();
    }
    json_error($e->getMessage(), 500);
});

// Autoload classes from core/, models/, controllers/ by class name.
spl_autoload_register(function (string $class): void {
    foreach (['core', 'models', 'controllers'] as $dir) {
        $file = __DIR__ . "/$dir/$class.php";
        if (is_file($file)) {
            require_once $file;
            return;
        }
    }
});

function config(?string $key = null)
{
    $cfg = $GLOBALS['app_config'];
    return $key === null ? $cfg : ($cfg[$key] ?? null);
}

// ---------------- HTTP helpers ----------------
/** Allow localhost and private-LAN origins (any port) so phones on the same Wi-Fi work. */
function is_lan_origin(string $origin): bool
{
    $host = parse_url($origin, PHP_URL_HOST) ?: '';
    if ($host === 'localhost') return true;
    if (preg_match('/^127\./', $host)) return true;              // loopback
    if (preg_match('/^10\./', $host)) return true;               // 10.0.0.0/8
    if (preg_match('/^192\.168\./', $host)) return true;         // 192.168.0.0/16
    if (preg_match('/^172\.(1[6-9]|2\d|3[01])\./', $host)) return true; // 172.16.0.0/12
    return false;
}

function send_cors(): void
{
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    $allowed = config('cors_origins') ?? [];
    if (in_array('*', $allowed, true)) {
        header('Access-Control-Allow-Origin: *');
    } elseif ($origin && (in_array($origin, $allowed, true) || is_lan_origin($origin))) {
        header("Access-Control-Allow-Origin: $origin");
        header('Vary: Origin');
    }
    header('Access-Control-Allow-Methods: GET, POST, PATCH, PUT, DELETE, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Authorization, X-Api-Token');
    header('Access-Control-Max-Age: 86400');
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
        http_response_code(204);
        exit;
    }
}

// Set default character encoding to UTF-8
if (function_exists('mb_internal_encoding')) {
    mb_internal_encoding('UTF-8');
}
if (function_exists('mb_http_output')) {
    mb_http_output('UTF-8');
}

function json_out($data, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function json_error(string $message, int $status = 400): void
{
    json_out(['error' => $message], $status);
}

function read_json_body(): array
{
    if (isset($GLOBALS['__json_body_override'])) {
        return $GLOBALS['__json_body_override'];
    }
    $raw = file_get_contents('php://input');
    if ($raw === '' || $raw === false) {
        return [];
    }
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

/** Override the parsed request body for the rest of this request (per-process). */
function set_json_body(array $body): void
{
    $GLOBALS['__json_body_override'] = $body;
}

function bearer_token(): ?string
{
    $hdr = $_SERVER['HTTP_AUTHORIZATION']
        ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION']
        ?? $_SERVER['HTTP_X_AUTHORIZATION']
        ?? $_SERVER['HTTP_X_API_TOKEN']
        ?? $_SERVER['REDIRECT_HTTP_X_AUTHORIZATION']
        ?? $_SERVER['REDIRECT_REDIRECT_HTTP_AUTHORIZATION']
        ?? $_SERVER['AUTHORIZATION']
        ?? '';

    if (!$hdr && function_exists('apache_request_headers')) {
        $headers = apache_request_headers();
        $hdr = $headers['Authorization']
            ?? $headers['authorization']
            ?? $headers['X-Authorization']
            ?? $headers['x-authorization']
            ?? $headers['X-Api-Token']
            ?? $headers['x-api-token']
            ?? '';
    }

    if (!$hdr && function_exists('getallheaders')) {
        $headers = getallheaders();
        $hdr = $headers['Authorization']
            ?? $headers['authorization']
            ?? $headers['X-Authorization']
            ?? $headers['x-authorization']
            ?? $headers['X-Api-Token']
            ?? $headers['x-api-token']
            ?? '';
    }

    if (!$hdr && !empty($_GET['token'])) {
        $hdr = 'Bearer ' . $_GET['token'];
    }

    if (preg_match('/Bearer\s+(.+)/i', $hdr, $m)) {
        return trim($m[1]);
    }
    if ($hdr && !preg_match('/\s/', $hdr)) {
        return trim($hdr);
    }
    return null;
}

function uuid4(): string
{
    $data = random_bytes(16);
    $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
    $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($data), 4));
}

function ensure_sequential_codes(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();

        // Remove old 'owner' account so only Admin, Staff, and Customer logins exist.
        $pdo->exec("DELETE FROM profiles WHERE email = 'owner@fincollect.in' OR full_name = 'Owner Admin'");

        // 1. Ensure user_code column exists in profiles
        $hasUserCode = $pdo->query(
            "SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'profiles' AND COLUMN_NAME = 'user_code'"
        )->fetchColumn();
        if (!$hasUserCode) {
            $pdo->exec("ALTER TABLE profiles ADD COLUMN `user_code` VARCHAR(64) NULL AFTER `role`");
        }

        // 2. Check if any profiles or customers need code updates
        $unfixedCust = (int)$pdo->query("SELECT COUNT(*) FROM customers WHERE customer_id NOT LIKE 'RRG-CUS-%'")->fetchColumn();
        $unfixedProf = (int)$pdo->query("SELECT COUNT(*) FROM profiles WHERE user_code IS NULL OR user_code NOT LIKE 'RRG-%'")->fetchColumn();

        if ($unfixedCust > 0 || $unfixedProf > 0) {
            // Fix profiles
            foreach (['admin' => 'RRG-ADM-', 'agent' => 'RRG-STF-', 'customer' => 'RRG-CUS-'] as $r => $prefix) {
                $rows = $pdo->query("SELECT id, user_code FROM profiles WHERE role = '$r' ORDER BY created_at ASC, id ASC")->fetchAll(PDO::FETCH_ASSOC);
                $idx = 1;
                foreach ($rows as $row) {
                    $code = sprintf('%s%04d', $prefix, $idx);
                    $stmt = $pdo->prepare("UPDATE profiles SET user_code = ? WHERE id = ?");
                    $stmt->execute([$code, $row['id']]);
                    $idx++;
                }
            }

            // Fix customers
            $custRows = $pdo->query("SELECT id, customer_id FROM customers ORDER BY created_at ASC, id ASC")->fetchAll(PDO::FETCH_ASSOC);
            $cIdx = 1;
            foreach ($custRows as $cRow) {
                $code = sprintf('RRG-CUS-%04d', $cIdx);
                $stmt = $pdo->prepare("UPDATE customers SET customer_id = ? WHERE id = ?");
                $stmt->execute([$code, $cRow['id']]);
                $cIdx++;
            }
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}

function ensure_chit_schedules_table(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $hasTable = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chit_schedules'"
        )->fetchColumn();
        if (!$hasTable) {
            $pdo->exec("
                CREATE TABLE chit_schedules (
                  id             CHAR(36)     NOT NULL PRIMARY KEY,
                  group_id       CHAR(36)     NOT NULL,
                  installment_no INT          NOT NULL,
                  due_date       DATE         NOT NULL,
                  payable_amount DECIMAL(14,2) NOT NULL DEFAULT 0,
                  pool_amount    DECIMAL(14,2) NOT NULL DEFAULT 0,
                  is_overridden  TINYINT(1)   NOT NULL DEFAULT 0,
                  notes          VARCHAR(255) NULL,
                  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  INDEX idx_chit_sched_group (group_id),
                  CONSTRAINT fk_chit_sched_group FOREIGN KEY (group_id)
                    REFERENCES chit_groups(id) ON DELETE CASCADE
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ");
        }
        // Ensure every_10_days is supported in draw_frequency enum
        $pdo->exec("ALTER TABLE chit_groups MODIFY draw_frequency ENUM('monthly_1', 'monthly_2', 'monthly_3', 'custom', 'every_5_days', 'every_10_days', 'interval_days') NOT NULL DEFAULT 'monthly_1'");
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}

function ensure_funds_units_column() {
    try {
        $pdo = Database::pdo();
        $stmt = $pdo->query("SHOW COLUMNS FROM funds LIKE 'units'");
        if ($stmt && $stmt->rowCount() === 0) {
            $pdo->exec("ALTER TABLE funds ADD COLUMN units DECIMAL(10,2) NOT NULL DEFAULT 1.00");
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}

function ensure_popup_settings_columns() {
    try {
        $pdo = Database::pdo();
        $stmt = $pdo->query("SHOW COLUMNS FROM settings LIKE 'popup_enabled'");
        if ($stmt && $stmt->rowCount() === 0) {
            $pdo->exec("ALTER TABLE settings ADD COLUMN popup_enabled TINYINT(1) NOT NULL DEFAULT 0, ADD COLUMN popup_image_url LONGTEXT NULL, ADD COLUMN popup_target_url TEXT NULL");
        }
        $countStmt = $pdo->query("SELECT COUNT(*) FROM settings");
        if ($countStmt && (int)$countStmt->fetchColumn() === 0) {
            $pdo->exec("INSERT INTO settings (id, company_name, popup_enabled, updated_at) VALUES (UUID(), 'RR Groups', 1, NOW())");
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}

/**
 * Penalty columns on `loans`.
 *
 * `penalty_per_week` lets an operator type the weekly-loan penalty by hand.
 * Left at 0 the recalculator falls back to the original automatic rate
 * (1% of principal per missed week, minimum ₹100), so loans created before
 * this column existed keep behaving exactly as they did.
 */
function ensure_loan_penalty_columns(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $add = [];
        foreach ([
            'penalty_amount'       => "DECIMAL(14,2) NOT NULL DEFAULT 0.00",
            'penalty_enabled'      => "TINYINT(1) NOT NULL DEFAULT 0",
            'penalty_rate_per_day' => "DECIMAL(10,2) NOT NULL DEFAULT 0.00",
            'penalty_per_week'     => "DECIMAL(10,2) NOT NULL DEFAULT 0.00",
        ] as $col => $def) {
            $stmt = $pdo->query("SHOW COLUMNS FROM loans LIKE '$col'");
            if ($stmt && $stmt->rowCount() === 0) {
                $add[] = "ADD COLUMN `$col` $def";
            }
        }
        if ($add) {
            $pdo->exec("ALTER TABLE loans " . implode(', ', $add));
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}

/**
 * How much of a receipt was a late fee rather than a repayment.
 *
 * Without this the two are indistinguishable, and the cascade treats the whole
 * receipt as money off the loan. A ₹1,300 instalment collected with its ₹100
 * penalty took ₹1,400 off a ₹13,000 loan — so the customer paid the fee and
 * got it credited against her own debt, and the business recorded no penalty
 * income at all. The fee was a number on a screen and nothing else.
 */
/**
 * Extra contact numbers, beside the primary one.
 *
 * A borrower often leaves two or three numbers — their own, a son's, the shop
 * line — and only one of them answers. They used to be crammed into `mobile`
 * or into the address, where nothing could dial them and search could not
 * match them.
 *
 * `mobile` is deliberately untouched. It is the number sign-in resolves
 * (Profile::findByIdentifier) and the one uniqueness is checked against, so
 * keeping the extras in their own column means adding a contact number can
 * never change who can log in or collide with somebody else's login.
 *
 * Stored as digits separated by commas. A small, fixed list that is only ever
 * read whole belongs with its row; a side table would buy nothing here and
 * cost a join on every customer read.
 */
function ensure_alt_mobiles_columns(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        foreach (['customers', 'profiles'] as $table) {
            $stmt = $pdo->query("SHOW COLUMNS FROM `$table` LIKE 'alt_mobiles'");
            if ($stmt && $stmt->rowCount() === 0) {
                $pdo->exec(
                    "ALTER TABLE `$table`
                        ADD COLUMN `alt_mobiles` VARCHAR(191) NULL DEFAULT NULL
                        AFTER `mobile`"
                );
            }
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}
function ensure_collection_penalty_column(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $stmt = $pdo->query("SHOW COLUMNS FROM collections LIKE 'penalty_amount'");
        if ($stmt && $stmt->rowCount() === 0) {
            $pdo->exec(
                "ALTER TABLE collections
                    ADD COLUMN `penalty_amount` DECIMAL(14,2) NOT NULL DEFAULT 0.00
                    AFTER `collection_amount`"
            );
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}
ensure_chit_schedules_table();
ensure_funds_units_column();
ensure_alt_mobiles_columns();
ensure_collection_penalty_column();
ensure_popup_settings_columns();
/**
 * Attribution columns on `account_ledger`.
 *
 * A chit contribution is recorded only as a ledger receipt, so without an
 * agent_id there is no way to tell who took the money — which kept agent chit
 * collections out of the Cash Handover tally. payment_method lets the same
 * screen split cash from UPI instead of parsing it out of the notes text.
 */
function ensure_ledger_agent_columns(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $add = [];
        foreach ([
            'agent_id'       => "CHAR(36) NULL",
            'agent_name'     => "VARCHAR(191) NULL",
            'payment_method' => "VARCHAR(32) NULL",
        ] as $col => $def) {
            $stmt = $pdo->query("SHOW COLUMNS FROM account_ledger LIKE '$col'");
            if ($stmt && $stmt->rowCount() === 0) {
                $add[] = "ADD COLUMN `$col` $def";
            }
        }
        if ($add) {
            $pdo->exec("ALTER TABLE account_ledger " . implode(', ', $add));
        }
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}

ensure_loan_penalty_columns();
ensure_ledger_agent_columns();

function ensure_promo_popups_table() {
    try {
        $pdo = Database::pdo();
        $pdo->exec("CREATE TABLE IF NOT EXISTS promo_popups (
          id           CHAR(36)     NOT NULL PRIMARY KEY,
          title        VARCHAR(191) NOT NULL DEFAULT 'Promotional Banner',
          image_url    LONGTEXT     NOT NULL,
          target_url   TEXT         NULL,
          is_active    TINYINT(1)   NOT NULL DEFAULT 1,
          created_by   VARCHAR(191) NULL,
          created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci");
    } catch (\Throwable $e) {
        // Silently ignore schema check errors
    }
}
ensure_promo_popups_table();

/**
 * Per-contribution chit passbook ledger.
 *
 * Before this table existed the only record of a chit contribution was the
 * free-text account_ledger receipt, and the customer passbook had to find its
 * own payments by substring-matching the member and group name inside that
 * text. That silently cross-matched similar names and broke whenever a group
 * or member was renamed. chit_payments stores the link as real foreign keys.
 */
function ensure_chit_payments_table(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $hasTable = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chit_payments'"
        )->fetchColumn();

        if (!$hasTable) {
            $pdo->exec("
                CREATE TABLE chit_payments (
                  id             CHAR(36)     NOT NULL PRIMARY KEY,
                  group_id       CHAR(36)     NOT NULL,
                  member_id      CHAR(36)     NULL,
                  group_number   VARCHAR(64)  NULL,
                  group_name     VARCHAR(191) NULL,
                  customer_id    CHAR(36)     NULL,
                  customer_name  VARCHAR(191) NULL,
                  installment_no INT          NOT NULL DEFAULT 0,
                  amount         DECIMAL(14,2) NOT NULL DEFAULT 0,
                  balance_after  DECIMAL(14,2) NOT NULL DEFAULT 0,
                  payment_method ENUM('cash','upi','card','bank','cheque') NOT NULL DEFAULT 'cash',
                  payment_date   DATE         NULL,
                  agent_id       CHAR(36)     NULL,
                  agent_name     VARCHAR(191) NULL,
                  ledger_id      CHAR(36)     NULL,
                  notes          TEXT         NULL,
                  created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  INDEX idx_chit_payments_group (group_id),
                  INDEX idx_chit_payments_member (member_id),
                  INDEX idx_chit_payments_customer (customer_id),
                  INDEX idx_chit_payments_ledger (ledger_id),
                  CONSTRAINT fk_chit_payments_group FOREIGN KEY (group_id)
                    REFERENCES chit_groups(id) ON DELETE CASCADE,
                  CONSTRAINT fk_chit_payments_member FOREIGN KEY (member_id)
                    REFERENCES chit_members(id) ON DELETE SET NULL
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ");
        }

        backfill_chit_payments_from_ledger();
    } catch (\Throwable $e) {
        // Schema check failures must never take the API down.
    }
}

/**
 * Recover historic contributions that only exist as account_ledger receipts.
 *
 * Idempotent: a receipt is skipped once a chit_payments row references it, so
 * this can run on every deployment without duplicating money. Receipts whose
 * group or member cannot be resolved are left behind rather than guessed at —
 * they stay visible in the Account Book either way.
 *
 * Only money *coming in* is a contribution. The category alone does not say
 * that: a chit prize payout is filed under "Chit Payout", names the same group
 * and the same member, and matches "%chit%" just as well — so this used to
 * recover a ₹39,600 prize as a ₹39,600 contribution and settle twenty-five
 * draws the member had never paid. Three conditions keep that out:
 *
 *   - the entry must be `cash_in`; a payout is `cash_out`,
 *   - it must not be the ledger row an auction wrote for its payout,
 *   - it must not be in the recycle bin, or a deleted receipt would come back
 *     as a live contribution.
 */
function backfill_chit_payments_from_ledger(): void
{
    $pdo = Database::pdo();

    // chit_auctions is created later in this file, so on a database that has
    // never seen it the clause is simply left out — cash_in already excludes
    // every payout on its own.
    $hasAuctions = (int)$pdo->query(
        "SELECT COUNT(*) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chit_auctions'"
    )->fetchColumn();
    $notAPayout = $hasAuctions
        ? "AND NOT EXISTS (SELECT 1 FROM chit_auctions a WHERE a.ledger_id = l.id)"
        : '';

    $rows = $pdo->query(
        "SELECT l.id, l.title, l.notes, l.amount, l.entry_date, l.agent_id, l.agent_name, l.payment_method
         FROM account_ledger l
         LEFT JOIN chit_payments p ON p.ledger_id = l.id
         WHERE LOWER(l.category) LIKE '%chit%'
           AND l.entry_type = 'cash_in'
           AND COALESCE(l.delflag, 0) = 0
           AND p.id IS NULL
           $notAPayout"
    )->fetchAll(PDO::FETCH_ASSOC);

    if (!$rows) return;

    $groups  = $pdo->query("SELECT id, group_name, group_number FROM chit_groups")->fetchAll(PDO::FETCH_ASSOC);
    $members = $pdo->query("SELECT id, group_id, customer_id, member_name FROM chit_members")->fetchAll(PDO::FETCH_ASSOC);

    $ins = $pdo->prepare(
        "INSERT INTO chit_payments
           (id, group_id, member_id, group_number, group_name, customer_id, customer_name,
            installment_no, amount, balance_after, payment_method, payment_date,
            agent_id, agent_name, ledger_id, notes)
         VALUES (?,?,?,?,?,?,?,0,?,0,?,?,?,?,?,?)"
    );

    $touched = [];
    foreach ($rows as $r) {
        $haystack = strtolower(trim(($r['title'] ?? '') . ' ' . ($r['notes'] ?? '')));
        if ($haystack === '') continue;

        // Resolve the group first — prefer the group number, which is unique.
        $group = null;
        foreach ($groups as $g) {
            $num = strtolower(trim((string)($g['group_number'] ?? '')));
            if ($num !== '' && strpos($haystack, $num) !== false) { $group = $g; break; }
        }
        if (!$group) {
            $best = 0;
            foreach ($groups as $g) {
                $name = strtolower(trim((string)($g['group_name'] ?? '')));
                if ($name !== '' && strpos($haystack, $name) !== false && strlen($name) > $best) {
                    $group = $g; $best = strlen($name);
                }
            }
        }
        if (!$group) continue;

        // Then the member, scoped to that group. Longest name wins so that
        // "Ramesh" cannot claim a receipt belonging to "Ramesh Kumar".
        $member = null; $best = 0;
        foreach ($members as $m) {
            if ($m['group_id'] !== $group['id']) continue;
            $name = strtolower(trim((string)($m['member_name'] ?? '')));
            if ($name !== '' && strpos($haystack, $name) !== false && strlen($name) > $best) {
                $member = $m; $best = strlen($name);
            }
        }
        if (!$member) continue;

        $method = strtolower(trim((string)($r['payment_method'] ?? 'cash')));
        if (!in_array($method, ['cash', 'upi', 'card', 'bank', 'cheque'], true)) $method = 'cash';

        $ins->execute([
            uuid4(),
            $group['id'],
            $member['id'],
            $group['group_number'] ?? null,
            $group['group_name'] ?? null,
            $member['customer_id'] ?? null,
            $member['member_name'] ?? null,
            (float)($r['amount'] ?? 0),
            $method,
            $r['entry_date'] ?: null,
            $r['agent_id'] ?? null,
            $r['agent_name'] ?? null,
            $r['id'],
            'Recovered from account book receipt during chit_payments migration.',
        ]);
        $touched[$member['id']] = true;
    }

    // Whoever gained a row needs their passbook and their group total
    // rebuilt. That cannot happen here — chit_passbook is created further down
    // this file — so the ids are handed to repair_and_resync_chit_payments(),
    // which runs once the table is guaranteed to exist. Without it the
    // recovered money sat in chit_payments while every derived figure still
    // showed the old total.
    foreach (array_keys($touched) as $mid) {
        $GLOBALS['rrg_chit_resync_members'][$mid] = true;
    }

    // Rebuild the running balance for every member the backfill touched.
    $sel = $pdo->prepare(
        "SELECT id, amount FROM chit_payments
         WHERE member_id = ? ORDER BY payment_date IS NULL, payment_date ASC, created_at ASC, id ASC"
    );
    $upd = $pdo->prepare("UPDATE chit_payments SET balance_after = ? WHERE id = ?");
    foreach (array_keys($touched) as $memberId) {
        $sel->execute([$memberId]);
        $running = 0.0;
        foreach ($sel->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $running = round($running + (float)$row['amount'], 2);
            $upd->execute([$running, $row['id']]);
        }
    }
}

ensure_chit_payments_table();

/**
 * Per-member chit passbook statement.
 *
 * The draw sheet lives in chit_schedules, one set per group. What a *member*
 * owes and has settled against each draw existed nowhere: the customer's
 * passbook worked it out in the browser every time the modal opened, so the
 * Paid / Pending / Overdue badge was never stored, never reportable, and never
 * the same fact the rest of the app was looking at.
 *
 * chit_passbook holds one row per (group, member, draw) — the draw number, its
 * scheduled date, the payable contribution, the dividend pool value and the
 * settled status — linked to chit_groups and chit_members by real foreign keys.
 *
 * The soft-delete columns are declared here rather than left to
 * ensure_soft_delete_columns(), because a member's passbook has to disappear
 * with the member on the very first request after the table is created.
 */
function ensure_chit_passbook_table(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $hasTable = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chit_passbook'"
        )->fetchColumn();

        if (!$hasTable) {
            $pdo->exec("
                CREATE TABLE chit_passbook (
                  id             CHAR(36)      NOT NULL PRIMARY KEY,
                  group_id       CHAR(36)      NOT NULL,
                  member_id      CHAR(36)      NOT NULL,
                  customer_id    CHAR(36)      NULL,
                  schedule_id    CHAR(36)      NULL,   -- the chit_schedules draw it mirrors
                  group_number   VARCHAR(64)   NULL,
                  group_name     VARCHAR(191)  NULL,
                  member_name    VARCHAR(191)  NULL,
                  installment_no INT           NOT NULL,
                  due_date       DATE          NULL,
                  payable_amount DECIMAL(14,2) NOT NULL DEFAULT 0,
                  pool_amount    DECIMAL(14,2) NOT NULL DEFAULT 0,
                  paid_amount    DECIMAL(14,2) NOT NULL DEFAULT 0,
                  balance        DECIMAL(14,2) NOT NULL DEFAULT 0,
                  payment_status ENUM('paid','partial','overdue','pending') NOT NULL DEFAULT 'pending',
                  is_overdue     TINYINT(1)    NOT NULL DEFAULT 0,
                  paid_date      DATE          NULL,
                  is_overridden  TINYINT(1)    NOT NULL DEFAULT 0,
                  notes          VARCHAR(255)  NULL,
                  synced_at      DATETIME      NULL,
                  delflag        TINYINT(1)    NOT NULL DEFAULT 0,
                  deleted_at     DATETIME      NULL,
                  deleted_by     CHAR(36)      NULL,
                  created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  -- One row per member per draw. Without this a repeated sync
                  -- would stack copies of the same instalment, which is how the
                  -- loan side ended up reporting a balance it never owed.
                  UNIQUE KEY uniq_passbook_member_draw (member_id, installment_no),
                  INDEX idx_passbook_group (group_id),
                  INDEX idx_passbook_customer (customer_id),
                  INDEX idx_passbook_status (payment_status),
                  INDEX idx_passbook_delflag (delflag),
                  CONSTRAINT fk_passbook_group FOREIGN KEY (group_id)
                    REFERENCES chit_groups(id) ON DELETE CASCADE,
                  CONSTRAINT fk_passbook_member FOREIGN KEY (member_id)
                    REFERENCES chit_members(id) ON DELETE CASCADE
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            ");
        }

        backfill_chit_passbook();
    } catch (\Throwable $e) {
        // Schema check failures must never take the API down.
    }
}

/**
 * Who won each draw, and whether the prize has actually been handed over.
 *
 * The draw sheet already carries a pool value per instalment — what the winner
 * of that draw receives — but nothing recorded *who* took it or whether the
 * money left the safe. Chit payouts were therefore invisible to the account
 * book: contributions came in and raised Cash In Hand, and the far larger sum
 * going back out to the winner never came off it.
 *
 * One row per (group, draw). The unique key is what stops a group paying the
 * same draw twice.
 */
function ensure_chit_auctions_table(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $hasTable = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chit_auctions'"
        )->fetchColumn();

        if ($hasTable) return;

        $pdo->exec("
            CREATE TABLE chit_auctions (
              id             CHAR(36)      NOT NULL PRIMARY KEY,
              group_id       CHAR(36)      NOT NULL,
              installment_no INT           NOT NULL,   -- the draw it settles
              schedule_id    CHAR(36)      NULL,
              group_number   VARCHAR(64)   NULL,
              group_name     VARCHAR(191)  NULL,
              auction_date   DATE          NULL,
              -- The winner. NULL until the draw is held.
              member_id      CHAR(36)      NULL,
              customer_id    CHAR(36)      NULL,
              member_name    VARCHAR(191)  NULL,
              -- pool - discount - commission = what the winner is handed.
              pool_amount    DECIMAL(14,2) NOT NULL DEFAULT 0,
              bid_amount     DECIMAL(14,2) NOT NULL DEFAULT 0,
              commission     DECIMAL(14,2) NOT NULL DEFAULT 0,
              payout_amount  DECIMAL(14,2) NOT NULL DEFAULT 0,
              -- The discount less commission, shared among the members.
              dividend_total DECIMAL(14,2) NOT NULL DEFAULT 0,
              status         ENUM('won','settled') NOT NULL DEFAULT 'won',
              payout_date    DATE          NULL,
              payment_method ENUM('cash','upi','card','bank','cheque') NOT NULL DEFAULT 'cash',
              -- The account_ledger cash_out row this payout wrote, so the
              -- money can be traced both ways and counted exactly once.
              ledger_id      CHAR(36)      NULL,
              agent_id       CHAR(36)      NULL,
              agent_name     VARCHAR(191)  NULL,
              notes          TEXT          NULL,
              created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
              delflag        TINYINT(1)    NOT NULL DEFAULT 0,
              deleted_at     DATETIME      NULL,
              deleted_by     CHAR(36)      NULL,
              -- A draw has one winner. Without this, a double submit pays the
              -- prize twice and the cash book never balances again.
              UNIQUE KEY uniq_auction_draw (group_id, installment_no),
              INDEX idx_auction_member (member_id),
              INDEX idx_auction_status (status),
              INDEX idx_auction_delflag (delflag),
              CONSTRAINT fk_auction_group FOREIGN KEY (group_id)
                REFERENCES chit_groups(id) ON DELETE CASCADE,
              -- SET NULL, not CASCADE: removing a member must not erase the
              -- record that a prize was paid out of the group's money.
              CONSTRAINT fk_auction_member FOREIGN KEY (member_id)
                REFERENCES chit_members(id) ON DELETE SET NULL
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ");
    } catch (\Throwable $e) {
        // Schema check failures must never take the API down.
    }
}

ensure_chit_auctions_table();

/**
 * Fund payouts — the money going back OUT to the customer.
 *
 * `fund_payments` is the passbook of deposits coming IN, and Cash In Hand sums
 * it as cash received. A maturity or closure payout was being written into that
 * same table, so handing a customer their money back *raised* Cash In Hand by
 * the amount paid out, and the passbook showed a ₹6,000 "deposit" on the day
 * the fund was emptied. Money leaving needs its own record, exactly as a chit
 * prize does.
 *
 * One row per payout rather than a set of columns on `funds`, because a fund
 * can be closed a few units at a time: each closure hands over its own share
 * and the fund carries on. `ledger_id` links to the account_ledger cash_out
 * that actually moved the cash, so the money is counted once and can be traced
 * from either end.
 *
 * The CASCADE key is not decoration: the recycle bin, soft_delete_cascade() and
 * restore all derive what a delete carries with it from the cascading keys, so
 * without it deleting a fund would leave its payouts behind.
 */
function ensure_fund_payouts_table(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $hasTable = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'fund_payouts'"
        )->fetchColumn();

        if ($hasTable) return;

        $pdo->exec("
            CREATE TABLE fund_payouts (
              id             CHAR(36)      NOT NULL PRIMARY KEY,
              fund_id        CHAR(36)      NOT NULL,
              fund_number    VARCHAR(64)   NULL,
              customer_id    CHAR(36)      NULL,
              customer_name  VARCHAR(191)  NULL,
              -- Why the money went out, which is also what decides the amount:
              --   maturity   — every week deposited, so the bonus is earned
              --   settlement — the scheme ended early, deposits back only
              --   partial    — some units closed, the rest still running
              kind           ENUM('maturity','settlement','partial') NOT NULL DEFAULT 'settlement',
              units_closed   DECIMAL(10,2) NOT NULL DEFAULT 0,
              -- The customer's own deposits being returned.
              deposit_amount DECIMAL(14,2) NOT NULL DEFAULT 0,
              -- The maturity bonus. Zero on anything but a matured fund: a
              -- scheme closed early has not earned it.
              bonus_amount   DECIMAL(14,2) NOT NULL DEFAULT 0,
              payout_amount  DECIMAL(14,2) NOT NULL DEFAULT 0,
              payout_date    DATE          NULL,
              payment_method ENUM('cash','upi','card','bank','cheque') NOT NULL DEFAULT 'cash',
              -- The account_ledger cash_out row this payout wrote.
              ledger_id      CHAR(36)      NULL,
              agent_id       CHAR(36)      NULL,
              agent_name     VARCHAR(191)  NULL,
              notes          TEXT          NULL,
              created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
              delflag        TINYINT(1)    NOT NULL DEFAULT 0,
              deleted_at     DATETIME      NULL,
              deleted_by     CHAR(36)      NULL,
              INDEX idx_fund_payouts_fund (fund_id),
              INDEX idx_fund_payouts_customer (customer_id),
              INDEX idx_fund_payouts_ledger (ledger_id),
              INDEX idx_fund_payouts_delflag (delflag),
              CONSTRAINT fk_fund_payouts_fund FOREIGN KEY (fund_id)
                REFERENCES funds(id) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ");
    } catch (\Throwable $e) {
        // Schema check failures must never take the API down.
    }
}

ensure_fund_payouts_table();

/**
 * A fund's status has to follow its deposits, not whoever wrote to it last.
 *
 * `matured` means the whole deposit target has been paid in — every week of a
 * 50-week scheme. It was being decided in the browser and PATCHed alongside the
 * running total, so a collection recorded anywhere else left the status behind,
 * and a fund could sit at `active` with nothing left to collect.
 *
 * This repairs the funds already in that state. From here on FundService::recalc()
 * derives it on the server after every collection, which is the only place it
 * can be derived correctly.
 */
function repair_fund_status_from_deposits(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_fund_status_' . md5(__DIR__) . '.done';
    if (file_exists($marker)) return;

    try {
        $pdo = Database::pdo();

        // A fund that has taken its full deposit is matured, unless it was
        // closed early — closing is a decision, and re-opening it here would
        // undo somebody's settlement.
        $pdo->exec(
            "UPDATE `funds`
                SET `status` = 'matured'
              WHERE `delflag` = 0
                AND `status` = 'active'
                AND COALESCE(`deposit_amount`, 0) > 0
                AND COALESCE(`collected_amount`, 0) >= COALESCE(`deposit_amount`, 0) - 0.01"
        );

        // And one that has not is active again: `matured` used to be written
        // the moment a settlement modal ran, before the deposits were in.
        $pdo->exec(
            "UPDATE `funds`
                SET `status` = 'active'
              WHERE `delflag` = 0
                AND `status` = 'matured'
                AND COALESCE(`deposit_amount`, 0) > 0
                AND COALESCE(`collected_amount`, 0) < COALESCE(`deposit_amount`, 0) - 0.01"
        );

        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Never take the API down over a repair pass.
    }
}

repair_fund_status_from_deposits();

/**
 * Which agent a chit group belongs to.
 *
 * Loans, funds and customers all carry an `assigned_agent`; chit groups were
 * the one module that did not, so the Chit Groups screen showed every group in
 * the business to every agent. There was nothing to filter on.
 */
function ensure_chit_group_agent_columns(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $stmt = $pdo->query("SHOW COLUMNS FROM chit_groups LIKE 'assigned_agent'");
        if ($stmt && $stmt->rowCount() > 0) return;

        $pdo->exec(
            "ALTER TABLE chit_groups
               ADD COLUMN assigned_agent CHAR(36)     NULL AFTER status,
               ADD COLUMN agent_name     VARCHAR(191) NULL AFTER assigned_agent,
               ADD INDEX idx_chit_groups_agent (assigned_agent)"
        );

        // SET NULL, like every other agent link: removing a member of staff
        // must not delete the groups they were looking after.
        try {
            $pdo->exec(
                "ALTER TABLE chit_groups
                 ADD CONSTRAINT fk_chit_groups_agent FOREIGN KEY (assigned_agent)
                   REFERENCES profiles(id) ON DELETE SET NULL"
            );
        } catch (\Throwable $e) {
            // A pre-existing row pointing at a missing profile, or the key is
            // already there. The column and index are what the scoping needs.
        }
    } catch (\Throwable $e) {
        // Schema check failures must never take the API down.
    }
}

ensure_chit_group_agent_columns();

/**
 * Build the passbook for every existing member once.
 *
 * After this the rows are maintained by ChitPassbookService on every write
 * that can change them, so this only has to run on the deployment that
 * introduces the table.
 */
function backfill_chit_passbook(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_passbook_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $built = ChitPassbookService::syncAll();
        error_log("backfill_chit_passbook: built passbooks for $built chit members");
        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
    }
}

/**
 * One draw sheet row per (group, draw) — the same guard the loan schedule got.
 *
 * Regenerating a group's schedule deletes and reinserts it, and a rebuild that
 * half-failed used to leave the old rows behind. Two copies of a draw means the
 * passbook asks a member to pay it twice, so duplicates are cleaned once and
 * then made impossible.
 */
function dedupe_chit_schedules(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_chitsched_dedupe_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $pdo = Database::pdo();

        $dupes = $pdo->query(
            "SELECT group_id, installment_no, COUNT(*) AS c
             FROM chit_schedules
             GROUP BY group_id, installment_no
             HAVING c > 1"
        )->fetchAll(PDO::FETCH_ASSOC);

        $removed = 0;
        if ($dupes) {
            // Keep the row an admin edited by hand, then the oldest.
            $pick = $pdo->prepare(
                "SELECT id FROM chit_schedules
                 WHERE group_id = ? AND installment_no = ?
                 ORDER BY is_overridden DESC, delflag ASC, created_at ASC, id ASC"
            );
            $drop = $pdo->prepare("DELETE FROM chit_schedules WHERE id = ?");

            foreach ($dupes as $d) {
                $pick->execute([$d['group_id'], $d['installment_no']]);
                $ids = $pick->fetchAll(PDO::FETCH_COLUMN, 0);
                array_shift($ids);
                foreach ($ids as $id) {
                    $drop->execute([$id]);
                    $removed++;
                }
            }
            error_log("dedupe_chit_schedules: removed $removed duplicate draw rows");
        }

        // A draw is never deleted on its own from the UI, so anything flagged
        // here is rebuild debris rather than a deliberate removal.
        $pdo->exec("DELETE FROM chit_schedules WHERE delflag = 1");

        try {
            $pdo->exec(
                "ALTER TABLE chit_schedules
                 ADD UNIQUE INDEX uniq_chit_schedule_draw (group_id, installment_no)"
            );
        } catch (\Throwable $e) {
            // Already present, or duplicates the pass above could not resolve.
        }

        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
    }
}

dedupe_chit_schedules();

ensure_chit_passbook_table();

/**
 * Undo contributions the ledger backfill should never have recovered, and
 * rebuild whatever it did legitimately recover.
 *
 * The backfill used to match any ledger row filed under a chit category,
 * whichever way the money was going. A prize payout is filed under
 * "Chit Payout", names the same group and the same winner, and reads as a
 * perfect match — so a ₹39,600 prize became a ₹39,600 contribution, and the
 * waterfall settled the member's next twenty-five draws with money they had
 * never paid. The query no longer matches those, but rows written before the
 * fix are still in the table, so they are taken back out here.
 *
 * Only rows the backfill itself created are touched — they carry its note, and
 * nothing else writes that string. A recovered row is removed when the receipt
 * behind it is not a live `cash_in`: the wrong direction, in the recycle bin,
 * an auction's own payout row, or gone from the ledger entirely (reversing a
 * settled auction deletes it, which is what left the orphan here). These are
 * deleted outright rather than soft-deleted: a fabricated row belongs in
 * nobody's recycle bin.
 *
 * Everything downstream — the member's passbook, the group's collected and
 * pending totals, the member's own status — is then rebuilt from what is
 * actually in chit_payments.
 */
function repair_and_resync_chit_payments(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $pdo = Database::pdo();
    $marker = 'Recovered from account book receipt during chit_payments migration.';

    try {
        $hasAuctions = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chit_auctions'"
        )->fetchColumn();
        $isAPayout = $hasAuctions
            ? "OR EXISTS (SELECT 1 FROM chit_auctions a WHERE a.ledger_id = p.ledger_id)"
            : '';

        $stmt = $pdo->prepare(
            "SELECT p.id, p.member_id, p.group_id
               FROM chit_payments p
               LEFT JOIN account_ledger l ON l.id = p.ledger_id
              WHERE p.notes = ?
                AND p.ledger_id IS NOT NULL
                AND (l.id IS NULL
                     OR l.entry_type <> 'cash_in'
                     OR COALESCE(l.delflag, 0) <> 0
                     $isAPayout)"
        );
        $stmt->execute([$marker]);
        $bogus = $stmt->fetchAll(PDO::FETCH_ASSOC);

        if ($bogus) {
            $del = $pdo->prepare('DELETE FROM chit_payments WHERE id = ?');
            foreach ($bogus as $row) {
                $del->execute([$row['id']]);
                if (!empty($row['member_id'])) {
                    $GLOBALS['rrg_chit_resync_members'][$row['member_id']] = true;
                }
                if (!empty($row['group_id'])) {
                    $GLOBALS['rrg_chit_resync_groups'][$row['group_id']] = true;
                }
            }
        }

        $memberIds = array_keys($GLOBALS['rrg_chit_resync_members'] ?? []);
        if (!$memberIds) return;

        // A member's running balance_after has to follow the deletion too, or
        // the receipt list keeps showing the total that included the prize.
        $sel = $pdo->prepare(
            "SELECT id, amount FROM chit_payments
              WHERE member_id = ? AND COALESCE(delflag, 0) = 0
              ORDER BY payment_date IS NULL, payment_date ASC, created_at ASC, id ASC"
        );
        $upd = $pdo->prepare('UPDATE chit_payments SET balance_after = ? WHERE id = ?');
        $grp = $pdo->prepare('SELECT group_id FROM chit_members WHERE id = ? LIMIT 1');

        foreach ($memberIds as $memberId) {
            $sel->execute([$memberId]);
            $running = 0.0;
            foreach ($sel->fetchAll(PDO::FETCH_ASSOC) as $row) {
                $running = round($running + (float)$row['amount'], 2);
                $upd->execute([$running, $row['id']]);
            }
            ChitPassbookService::syncMember((string)$memberId);
            $grp->execute([$memberId]);
            $gid = $grp->fetchColumn();
            if ($gid) $GLOBALS['rrg_chit_resync_groups'][$gid] = true;
        }

        foreach (array_keys($GLOBALS['rrg_chit_resync_groups'] ?? []) as $groupId) {
            ChitPassbookService::recalcGroupTotals((string)$groupId);
        }

        $GLOBALS['rrg_chit_resync_members'] = [];
        $GLOBALS['rrg_chit_resync_groups']  = [];
    } catch (\Throwable $e) {
        // A repair that cannot run must not take the API down; it retries on
        // the next request.
    }
}

repair_and_resync_chit_payments();

/**
 * Turn an `assigned_agent` holding an agent's *name* into their id.
 *
 * Early rows — and the fallback query the agent screens still carry — matched
 * an agent by name, so `assigned_agent` sometimes holds "Ravi" rather than a
 * uuid. That was survivable while the browser did the filtering and could try
 * both. AgentScope compares against the signed-in agent's id and nothing else,
 * which is the point of it, so a name left in that column would make the record
 * invisible to the very agent it belongs to.
 *
 * A row is only converted when exactly one live agent carries that name. Two
 * agents called "Kumar" are left for a human: handing someone else's loan to
 * the wrong Kumar is worse than leaving it for an admin to re-assign.
 */
function normalise_agent_assignments(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_agent_ids_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $pdo = Database::pdo();

        // Anything that is not shaped like a uuid is a candidate.
        $notUuid = "`assigned_agent` IS NOT NULL AND `assigned_agent` <> ''
                    AND `assigned_agent` NOT REGEXP '^[0-9a-f]{8}-[0-9a-f]{4}-'";

        $agents = $pdo->query(
            "SELECT `id`, `full_name` FROM `profiles`
              WHERE `role` = 'agent' AND `full_name` IS NOT NULL AND `full_name` <> ''"
        )->fetchAll(PDO::FETCH_ASSOC);

        // Names shared by two agents resolve to nobody.
        $byName = [];
        foreach ($agents as $a) {
            $key = strtolower(trim((string)$a['full_name']));
            $byName[$key] = array_key_exists($key, $byName) ? null : $a['id'];
        }

        $present = $pdo->query(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()"
        )->fetchAll(PDO::FETCH_COLUMN, 0);

        foreach (['loans', 'funds', 'chit_groups', 'customers'] as $table) {
            if (!in_array($table, $present, true)) continue;

            $rows = $pdo->query("SELECT `id`, `assigned_agent` FROM `$table` WHERE $notUuid")
                        ->fetchAll(PDO::FETCH_ASSOC);
            if (!$rows) continue;

            $upd = $pdo->prepare("UPDATE `$table` SET `assigned_agent` = ? WHERE `id` = ?");
            foreach ($rows as $r) {
                $key = strtolower(trim((string)$r['assigned_agent']));
                $id  = $byName[$key] ?? null;
                if ($id) $upd->execute([$id, $r['id']]);
            }
        }

        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
        error_log('normalise_agent_assignments: ' . $e->getMessage());
    }
}

normalise_agent_assignments();


/**
 * Reattach records whose customer went missing.
 *
 * `loans.customer_id`, `funds.customer_id` and the rest carry
 * `ON DELETE SET NULL`, so hard-deleting a customer — which the seed and reset
 * scripts still do, and which was the norm before soft delete arrived — silently
 * cut every loan, receipt, fund and chit membership loose from them. The rows
 * kept the customer's *name*, so nothing looked wrong on a screen that reads
 * loans (the agent's Collections list), while any screen that starts from
 * customers lost the money entirely: a ₹5,000 loan with ₹2,400 overdue on it
 * belonged to nobody.
 *
 * There are two shapes of breakage. Columns with a foreign key were set to
 * NULL; columns without one — collections, fund_payments, chit_payments — kept
 * the id of a customer who no longer exists, which is worse, because it looks
 * linked. Both are treated the same here: a customer id that matches no row at
 * all is a broken link. A *soft*-deleted customer is not — those rows point at
 * someone who is deliberately in the recycle bin, and moving them would undo a
 * decision somebody made.
 *
 * A row is only reattached when its stored customer_name matches exactly one
 * live customer. Two people called "Kumar" are left alone for a human to
 * resolve — a wrong guess here moves real money onto the wrong person's book.
 */
function relink_orphan_records(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_relink_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $pdo = Database::pdo();
        $fixed = [];

        // Parent records first, so the children below can follow their parent
        // rather than relying on a name of their own.
        foreach (['loans', 'funds', 'chit_members'] as $table) {
            $n = relink_by_name($pdo, $table, $table === 'chit_members' ? 'member_name' : 'customer_name');
            if ($n) $fixed[] = "$table: $n";
        }

        // A receipt belongs to whoever the loan belongs to. That is a fact, not
        // a guess, so it is tried before any name matching.
        $n = (int)$pdo->exec(
            "UPDATE collections c
               JOIN loans l ON l.id = c.loan_id AND l.customer_id IS NOT NULL
                SET c.customer_id = l.customer_id,
                    c.customer_name = COALESCE(c.customer_name, l.customer_name)
              WHERE " . orphan_condition('c')
        );
        if ($n) $fixed[] = "collections via loan: $n";

        $n = (int)$pdo->exec(
            "UPDATE fund_payments p
               JOIN funds f ON f.id = p.fund_id AND f.customer_id IS NOT NULL
                SET p.customer_id = f.customer_id
              WHERE " . orphan_condition('p')
        );
        if ($n) $fixed[] = "fund_payments via fund: $n";

        $n = (int)$pdo->exec(
            "UPDATE chit_payments p
               JOIN chit_members m ON m.id = p.member_id AND m.customer_id IS NOT NULL
                SET p.customer_id = m.customer_id
              WHERE " . orphan_condition('p')
        );
        if ($n) $fixed[] = "chit_payments via member: $n";

        // Anything still loose gets the name test as a last resort.
        $n = relink_by_name($pdo, 'collections', 'customer_name');
        if ($n) $fixed[] = "collections by name: $n";

        if ($fixed) {
            error_log('relink_orphan_records: ' . implode(', ', $fixed));
            // Balances and the customer directory are derived from these links.
            $loans = $pdo->query("SELECT id FROM loans WHERE delflag = 0")->fetchAll(PDO::FETCH_COLUMN, 0);
            LoanRecalc::syncMany($loans ?: []);
            ChitPassbookService::syncAll();
        }

        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
    }
}

/**
 * SQL for "this row's customer link is broken": either empty, or pointing at a
 * customer row that no longer physically exists.
 *
 * Deliberately not `delflag = 0`: a soft-deleted customer is still a customer,
 * sitting in the recycle bin, and their loans and receipts belong to them until
 * somebody restores or purges them.
 */
function orphan_condition(string $alias): string
{
    return "(`$alias`.customer_id IS NULL OR NOT EXISTS (
              SELECT 1 FROM customers oc WHERE oc.id = `$alias`.customer_id))";
}

/**
 * Point rows with a broken customer link back at the one live customer whose
 * name they carry. Returns how many were reattached.
 */
function relink_by_name(PDO $pdo, string $table, string $nameColumn): int
{
    $rows = $pdo->query(
        "SELECT id, `$nameColumn` AS nm FROM `$table` t
          WHERE " . orphan_condition('t') . "
            AND `$nameColumn` IS NOT NULL AND `$nameColumn` <> ''"
    )->fetchAll(PDO::FETCH_ASSOC);
    if (!$rows) return 0;

    $find = $pdo->prepare(
        "SELECT id FROM customers WHERE delflag = 0 AND full_name = ? LIMIT 2"
    );
    $set = $pdo->prepare("UPDATE `$table` SET customer_id = ? WHERE id = ?");

    $done = 0;
    foreach ($rows as $r) {
        $find->execute([$r['nm']]);
        $matches = $find->fetchAll(PDO::FETCH_COLUMN, 0);
        // Exactly one, or it stays loose: guessing between two people with the
        // same name would move real money onto the wrong book.
        if (count($matches) !== 1) continue;
        $set->execute([$matches[0], $r['id']]);
        $done++;
    }
    return $done;
}

relink_orphan_records();


/**
 * Soft-delete archive backing the admin Recycle Bin.
 *
 * Carries no foreign keys on purpose: it has to survive the deletion of the
 * very rows it describes, and the utf8mb4 migration drops and recreates every
 * FK in the schema — one fewer constraint to juggle there.
 */
function ensure_recycle_bin_table(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $hasTable = (int)$pdo->query(
            "SELECT COUNT(*) FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'recycle_bin'"
        )->fetchColumn();
        if ($hasTable) return;

        $pdo->exec("
            CREATE TABLE recycle_bin (
              id              CHAR(36)     NOT NULL PRIMARY KEY,
              table_name      VARCHAR(64)  NOT NULL,
              record_id       VARCHAR(64)  NULL,
              label           VARCHAR(255) NULL,
              payload         LONGTEXT     NOT NULL,
              child_count     INT          NOT NULL DEFAULT 0,
              deleted_by      CHAR(36)     NULL,
              deleted_by_name VARCHAR(191) NULL,
              deleted_by_role VARCHAR(32)  NULL,
              deleted_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
              restored_at     DATETIME     NULL,
              INDEX idx_recycle_table (table_name),
              INDEX idx_recycle_deleted_at (deleted_at),
              INDEX idx_recycle_actor (deleted_by)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ");
    } catch (\Throwable $e) {
        // Never take the API down over a schema check.
    }
}

ensure_recycle_bin_table();

/**
 * Soft-delete flag on customers.
 *
 * A customer cannot simply be removed: loans, collections, funds and chit
 * membership all point at them, and wiping the row would either orphan or
 * erase real financial history. delflag = 1 hides them everywhere instead.
 */
function ensure_customer_delflag(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();
        $cols = $pdo->query("SHOW COLUMNS FROM customers")->fetchAll(PDO::FETCH_COLUMN, 0);
        if (!in_array('delflag', $cols, true)) {
            $pdo->exec("ALTER TABLE customers ADD COLUMN delflag TINYINT(1) NOT NULL DEFAULT 0");
            $pdo->exec("ALTER TABLE customers ADD INDEX idx_customers_delflag (delflag)");
        }
        if (!in_array('deleted_at', $cols, true)) {
            $pdo->exec("ALTER TABLE customers ADD COLUMN deleted_at DATETIME NULL");
        }
        if (!in_array('deleted_by', $cols, true)) {
            $pdo->exec("ALTER TABLE customers ADD COLUMN deleted_by CHAR(36) NULL");
        }
    } catch (\Throwable $e) {
        // A schema check must never take the API down.
    }
}

ensure_customer_delflag();

/**
 * Tables carrying the soft-delete flag.
 *
 * recycle_bin is deliberately absent: it IS the archive, and "Empty Recycle
 * Bin" has to mean the records are gone. Flagging rows there would leave the
 * bin permanently full and give the admin no way to actually purge anything.
 */
const SOFT_DELETE_TABLES = [
    'account_ledger', 'biometric_credentials', 'chit_groups', 'chit_members',
    'chit_passbook', 'chit_payments', 'chit_schedules', 'collections', 'customers',
    'fund_payments', 'funds', 'handovers', 'loans', 'notifications',
    'profiles', 'promo_popups', 'push_subscriptions', 'repayment_schedule',
    'settings',
];

/**
 * Add delflag / deleted_at / deleted_by everywhere.
 *
 * 0 = active, 1 = deleted. Rows are flagged rather than removed so that the
 * financial trail — loans against a customer, collections against a loan,
 * contributions against a chit member — survives a deletion anywhere above it.
 */
function ensure_soft_delete_columns(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    try {
        $pdo = Database::pdo();

        $existing = $pdo->query(
            "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE()
               AND COLUMN_NAME IN ('delflag','deleted_at','deleted_by')"
        )->fetchAll(PDO::FETCH_ASSOC);

        $have = [];
        foreach ($existing as $r) {
            $have[$r['TABLE_NAME']][$r['COLUMN_NAME']] = true;
        }

        $tables = $pdo->query(
            "SELECT TABLE_NAME FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'"
        )->fetchAll(PDO::FETCH_COLUMN, 0);

        foreach (SOFT_DELETE_TABLES as $table) {
            if (!in_array($table, $tables, true)) continue;

            // Each ALTER is guarded on its own: a shared host that refuses one
            // must not stop the rest from being added.
            if (empty($have[$table]['delflag'])) {
                try {
                    $pdo->exec("ALTER TABLE `$table` ADD COLUMN delflag TINYINT(1) NOT NULL DEFAULT 0");
                    $pdo->exec("ALTER TABLE `$table` ADD INDEX idx_{$table}_delflag (delflag)");
                } catch (\Throwable $e) {}
            }
            if (empty($have[$table]['deleted_at'])) {
                try { $pdo->exec("ALTER TABLE `$table` ADD COLUMN deleted_at DATETIME NULL"); } catch (\Throwable $e) {}
            }
            if (empty($have[$table]['deleted_by'])) {
                try { $pdo->exec("ALTER TABLE `$table` ADD COLUMN deleted_by CHAR(36) NULL"); } catch (\Throwable $e) {}
            }
        }
    } catch (\Throwable $e) {
        // A schema check must never take the API down.
    }
}

ensure_soft_delete_columns();

/**
 * `customers.loan_status` was only ever written by seed.php, so every
 * customer created through the app has been stuck on 'none' — the directory
 * showed "No Loan" next to people holding live loans. It is maintained
 * going forward by Customer::recalcLoanStatus(); this corrects the rows
 * that are already wrong.
 */
function backfill_customer_loan_status(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_loanstatus_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        Customer::recalcLoanStatus(null);
        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
    }
}

backfill_customer_loan_status();

/**
 * Remove duplicated repayment instalments, then make them impossible.
 *
 * Editing a loan wipes and regenerates its schedule. While deletes were soft,
 * the old rows stayed behind flagged; before that, a failed regenerate could
 * leave a partial set. Either way the loan ended up with two or three copies of
 * every instalment, and since the outstanding balance is the sum of unpaid
 * instalment balances, it climbed far past the total repayment — a ₹1,30,000
 * loan reporting ₹2,32,860.
 *
 * The row with the most money against it is kept, so no payment is lost.
 */
function dedupe_repayment_schedule(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_sched_dedupe_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $pdo = Database::pdo();

        // Keep, per (loan_id, installment_no), the row with the highest
        // paid_amount — then the oldest — and drop the rest.
        $dupes = $pdo->query(
            "SELECT loan_id, installment_no, COUNT(*) AS c
             FROM repayment_schedule
             GROUP BY loan_id, installment_no
             HAVING c > 1"
        )->fetchAll(PDO::FETCH_ASSOC);

        $removed = 0;
        if ($dupes) {
            $pick = $pdo->prepare(
                "SELECT id FROM repayment_schedule
                 WHERE loan_id = ? AND installment_no = ?
                 ORDER BY paid_amount DESC, delflag ASC, created_at ASC, id ASC"
            );
            $drop = $pdo->prepare("DELETE FROM repayment_schedule WHERE id = ?");

            foreach ($dupes as $d) {
                $pick->execute([$d['loan_id'], $d['installment_no']]);
                $ids = $pick->fetchAll(PDO::FETCH_COLUMN, 0);
                array_shift($ids);           // keep the best one
                foreach ($ids as $id) {
                    $drop->execute([$id]);
                    $removed++;
                }
            }
            error_log("dedupe_repayment_schedule: removed $removed duplicate instalment rows");
        }

        // Any soft-deleted leftovers are rebuild debris, not user deletions —
        // a schedule row is never deleted on its own from the UI.
        $pdo->exec("DELETE FROM repayment_schedule WHERE delflag = 1");

        // Now that the table is clean, stop it ever happening again.
        try {
            $pdo->exec(
                "ALTER TABLE repayment_schedule
                 ADD UNIQUE INDEX uniq_schedule_installment (loan_id, installment_no)"
            );
        } catch (\Throwable $e) {
            // Already present, or duplicates the pass above could not resolve.
        }

        // Balances and statuses are derived from these rows, so refresh them.
        $loans = $pdo->query("SELECT id FROM loans WHERE delflag = 0")->fetchAll(PDO::FETCH_COLUMN, 0);
        LoanRecalc::syncMany($loans ?: []);

        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
    }
}

dedupe_repayment_schedule();

/**
 * Repair loans left stale by a restore from the recycle bin.
 *
 * Until RecycleBinService::restore() learned to resync, putting a collection
 * back returned the receipt without moving the loan's `outstanding_balance`.
 * The delete had correctly raised the balance; nothing lowered it again. The
 * money then showed in Cash In Hand and in Outstanding Money Lent at the same
 * time, and the loan card claimed a debt that had been paid.
 *
 * Only loans whose stored balance actually disagrees with their live
 * collections are touched, so this reports what it repaired instead of quietly
 * rewriting every loan in the database.
 */
function resync_restored_loans(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_restore_resync_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $pdo = Database::pdo();

        // total_repayment minus what has actually been received is what the
        // balance should be; anything more than a rupee out is stale.
        $stale = $pdo->query(
            "SELECT l.id
               FROM loans l
              WHERE l.delflag = 0
                AND ABS(
                      l.outstanding_balance
                      - GREATEST(l.total_repayment - COALESCE((
                          SELECT SUM(c.collection_amount) FROM collections c
                           WHERE c.loan_id = l.id AND c.delflag = 0
                        ), 0), 0)
                    ) > 1"
        )->fetchAll(PDO::FETCH_COLUMN, 0) ?: [];

        if ($stale) {
            LoanRecalc::syncMany($stale);
            error_log('resync_restored_loans: recalculated ' . count($stale) . ' loan(s) left stale by a restore');
        }

        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        // Retry on the next request rather than taking the API down.
    }
}

resync_restored_loans();

/** True when $table carries the soft-delete flag (cached per request). */
function table_has_delflag(string $table): bool
{
    static $cache = null;
    if ($cache === null) {
        $cache = [];
        try {
            $rows = Database::pdo()->query(
                "SELECT TABLE_NAME FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_NAME = 'delflag'"
            )->fetchAll(PDO::FETCH_COLUMN, 0);
            foreach ($rows as $t) $cache[$t] = true;
        } catch (\Throwable $e) {
            $cache = [];
        }
    }
    return !empty($cache[$table]);
}

/**
 * UNIQUE columns that must be released when a row is soft-deleted.
 *
 * This is the trap in every soft-delete design: the row stays, so its UNIQUE
 * value stays claimed. A deleted customer's login email could never be used
 * again, and re-registering the same phone for push or the same passkey would
 * collide with a hidden row. Each value is tombstoned with the row id, which
 * keeps it unique while freeing the original.
 *
 * The recycle bin snapshot still holds the real value, so a restore puts it
 * back — and if someone has claimed it meanwhile, the restore fails loudly
 * instead of silently producing two accounts with one email.
 */
const SOFT_DELETE_UNIQUE_COLUMNS = [
    'profiles'              => ['email'],
    'push_subscriptions'    => ['endpoint'],
    'biometric_credentials' => ['credential_id'],
];

/**
 * Tables that are money in the account book without holding it.
 *
 * Cash In Hand sums `collections` and `fund_payments` directly, so flagging
 * one of those rows is the whole of the job. These three are different: a chit
 * contribution, a chit prize and a fund payout each write an `account_ledger`
 * row and keep only its id. The cash-book row is where the money is counted,
 * and no foreign key points back to it.
 *
 * So deleting a chit group used to flag the group, its members, its draw
 * sheet, its contributions and its auctions — and leave every rupee of it in
 * the account book. The group vanished from the chit page and Cash In Hand did
 * not move.
 *
 * Maps table => the column holding the `account_ledger` id.
 */
const LEDGER_LINKED_TABLES = [
    'chit_payments' => 'ledger_id',
    'chit_auctions' => 'ledger_id',
    'fund_payouts'  => 'ledger_id',
];

/**
 * Flag the cash-book rows that $rows are the record of.
 *
 * Called with rows that have just been (or are about to be) soft-deleted. The
 * snapshot in the recycle bin holds these same rows, so a restore puts the
 * money back with the record — see RecycleBinService::attachLedgerRows().
 */
function soft_delete_linked_ledger(string $table, array $rows, ?string $actorId): void
{
    $col = LEDGER_LINKED_TABLES[$table] ?? null;
    if (!$col || !$rows) return;

    $ids = [];
    foreach ($rows as $row) {
        $v = is_array($row) ? ($row[$col] ?? null) : null;
        if (is_string($v) && $v !== '') $ids[$v] = $v;
    }
    if (!$ids) return;

    try {
        $pdo = Database::pdo();
        $ph  = implode(',', array_fill(0, count($ids), '?'));
        $pdo->prepare(
            "UPDATE `account_ledger` SET `delflag` = 1, `deleted_at` = ?, `deleted_by` = ?
              WHERE `id` IN ($ph) AND `delflag` = 0"
        )->execute(array_merge([date('Y-m-d H:i:s'), $actorId], array_values($ids)));
    } catch (\Throwable $e) {
        // Never let it block the delete the user asked for.
    }
}

/**
 * Flag the rows the database would have removed by ON DELETE CASCADE.
 *
 * A hard DELETE on a chit group took its members, draws and payments with
 * it. Now that the parent is only flagged the cascade never fires, so the
 * children would stay visible — a deleted group's contributions would keep
 * showing in a member's passbook. This walks the same foreign keys and
 * flags them, so soft delete matches what hard delete used to do.
 */
function soft_delete_cascade(string $table, array $rows, ?string $actorId, int $depth = 0): void
{
    if ($depth >= 3 || !$rows) return;

    // The money these rows stand for lives in `account_ledger`. Done here, at
    // the top, so it covers the rows handed in as well as every row the walk
    // below reaches on its way down.
    soft_delete_linked_ledger($table, $rows, $actorId);

    try {
        $pdo = Database::pdo();
        $links = $pdo->prepare(
            "SELECT k.TABLE_NAME, k.COLUMN_NAME
             FROM information_schema.REFERENTIAL_CONSTRAINTS rc
             JOIN information_schema.KEY_COLUMN_USAGE k
               ON k.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
              AND k.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
             WHERE rc.CONSTRAINT_SCHEMA = DATABASE()
               AND rc.REFERENCED_TABLE_NAME = ?
               AND rc.DELETE_RULE = 'CASCADE'"
        );
        $links->execute([$table]);
        $children = $links->fetchAll(PDO::FETCH_ASSOC);
        if (!$children) return;

        $now = date('Y-m-d H:i:s');
        foreach ($rows as $row) {
            $id = $row['id'] ?? null;
            if (!$id) continue;

            foreach ($children as $c) {
                $childTable = $c['TABLE_NAME'];
                $childCol   = $c['COLUMN_NAME'];
                if ($childTable === 'recycle_bin' || !table_has_delflag($childTable)) continue;

                // `id` alone was enough while the walk only had to flag rows.
                // The ledger link has to travel with them now, or the recursive
                // call cannot find the cash-book row a child was counted from.
                $ledgerCol = LEDGER_LINKED_TABLES[$childTable] ?? null;
                $select    = $ledgerCol ? "id, `$ledgerCol`" : 'id';
                $sel = $pdo->prepare("SELECT $select FROM `$childTable` WHERE `$childCol` = ? AND delflag = 0");
                $sel->execute([$id]);
                $kids = $sel->fetchAll(PDO::FETCH_ASSOC);
                if (!$kids) continue;

                $pdo->prepare(
                    "UPDATE `$childTable` SET delflag = 1, deleted_at = ?, deleted_by = ?
                     WHERE `$childCol` = ? AND delflag = 0"
                )->execute([$now, $actorId, $id]);

                soft_delete_cascade($childTable, $kids, $actorId, $depth + 1);
            }
        }
    } catch (\Throwable $e) {
        // Never let the cascade block the delete the user asked for.
    }
}

/**
 * Tombstone the UNIQUE columns of rows about to be soft-deleted.
 * Call BEFORE flagging them, with the rows as they still are.
 */
function release_unique_columns(string $table, array $rows): void
{
    $columns = SOFT_DELETE_UNIQUE_COLUMNS[$table] ?? null;
    if (!$columns || !$rows) return;

    try {
        $pdo = Database::pdo();
        foreach ($rows as $row) {
            $id = $row['id'] ?? null;
            if (!$id) continue;

            foreach ($columns as $col) {
                $current = $row[$col] ?? null;
                if ($current === null || $current === '') continue;
                // Already tombstoned by an earlier delete — leave it alone.
                if (strncmp((string)$current, 'deleted:', 8) === 0) continue;

                $tomb = $col === 'email'
                    ? 'deleted+' . $id . '@deleted.invalid'
                    : 'deleted:' . $id . ':' . $current;

                $pdo->prepare("UPDATE `$table` SET `$col` = ? WHERE `id` = ?")
                    ->execute([$tomb, $id]);
            }
        }
    } catch (\Throwable $e) {
        // Freeing the value is a convenience; never block the delete over it.
    }
}

/**
 * Self-healing UTF-8 migration.
 *
 * Tamil (and any non-Latin) text is stored as "?" whenever the database, table
 * or column charset is latin1 — MySQL replaces every character it cannot encode.
 * Shared hosts often default new schemas to latin1, so the tables created there
 * silently lose Tamil even though the PDO connection already speaks utf8mb4.
 *
 * This walks the current schema once and converts anything that is not utf8mb4.
 * A marker file keeps it from re-running information_schema on every request.
 */
function ensure_utf8mb4_charset(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $report = ['status' => 'skipped', 'converted' => [], 'fks_restored' => 0, 'errors' => []];

    // The suffix moved from _utf8mb4_ when the check grew to cover collations:
    // a server that recorded the narrower check as passing has to look again.
    $marker = sys_get_temp_dir() . '/rrgroups_utf8mb4_coll_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) {
        $report['status'] = 'already-done';
        $GLOBALS['utf8mb4_migration'] = $report;
        return;
    }

    try {
        $pdo = Database::pdo();
    } catch (\Throwable $e) {
        $report['status'] = 'no-db';
        $GLOBALS['utf8mb4_migration'] = $report;
        return;
    }

    // Any text column that is not utf8mb4 will mangle Tamil and the rupee sign.
    //
    // The collation matters as much as the charset, and used not to be checked.
    // A `utf8mb4_general_ci` column has the right charset, so it was skipped —
    // and the migration reported success over a database that was still mixed.
    // Mixed is not a cosmetic state: MariaDB refuses to compare two collations
    // outright, and a chit payout died on exactly that. Every text column is
    // brought to utf8mb4_unicode_ci, which is what the schema declares.
    try {
        $bad = $pdo->query(
            "SELECT DISTINCT TABLE_NAME FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE()
               AND CHARACTER_SET_NAME IS NOT NULL
               AND (CHARACTER_SET_NAME <> 'utf8mb4'
                    OR COLLATION_NAME <> 'utf8mb4_unicode_ci')"
        )->fetchAll(PDO::FETCH_COLUMN);
    } catch (\Throwable $e) {
        $report['status'] = 'inspect-failed';
        $report['errors']['inspect'] = $e->getMessage();
        $GLOBALS['utf8mb4_migration'] = $report;
        return;
    }

    if (!$bad) {
        $report['status'] = 'ok';
        $GLOBALS['utf8mb4_migration'] = $report;
        @file_put_contents($marker, date('c'));
        return;
    }

    // Shared hosts often withhold schema-level ALTER. That only changes the
    // default for FUTURE tables, so it must never block the conversion below.
    try {
        $dbDefault = $pdo->query(
            "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA
             WHERE SCHEMA_NAME = DATABASE()"
        )->fetchColumn();
        if ($dbDefault !== 'utf8mb4') {
            $pdo->exec('ALTER DATABASE `' . $pdo->query('SELECT DATABASE()')->fetchColumn()
                . '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
        }
    } catch (\Throwable $e) {
        $report['errors']['alter_database'] = $e->getMessage();
    }

    // MariaDB refuses to re-charset a column that sits in a foreign key
    // (errno 1832/1833) and SET FOREIGN_KEY_CHECKS=0 does NOT waive it — unlike
    // MySQL 8. So capture every constraint, drop them, convert, put them back.
    $fks = [];
    try {
        $rows = $pdo->query(
            "SELECT rc.CONSTRAINT_NAME, rc.TABLE_NAME, rc.REFERENCED_TABLE_NAME,
                    rc.UPDATE_RULE, rc.DELETE_RULE
             FROM information_schema.REFERENTIAL_CONSTRAINTS rc
             WHERE rc.CONSTRAINT_SCHEMA = DATABASE()"
        )->fetchAll(PDO::FETCH_ASSOC);
        foreach ($rows as $r) {
            $cols = $pdo->prepare(
                "SELECT COLUMN_NAME, REFERENCED_COLUMN_NAME
                 FROM information_schema.KEY_COLUMN_USAGE
                 WHERE CONSTRAINT_SCHEMA = DATABASE()
                   AND CONSTRAINT_NAME = ? AND TABLE_NAME = ?
                 ORDER BY ORDINAL_POSITION"
            );
            $cols->execute([$r['CONSTRAINT_NAME'], $r['TABLE_NAME']]);
            $pairs = $cols->fetchAll(PDO::FETCH_ASSOC);
            if (!$pairs) continue;
            $r['cols'] = array_column($pairs, 'COLUMN_NAME');
            $r['refs'] = array_column($pairs, 'REFERENCED_COLUMN_NAME');
            $fks[] = $r;
        }
    } catch (\Throwable $e) {
        $report['errors']['read_foreign_keys'] = $e->getMessage();
    }

    $quote = function (array $names): string {
        return '`' . implode('`, `', $names) . '`';
    };

    // Drop first so every table below is free to change charset.
    $dropped = [];
    foreach ($fks as $fk) {
        try {
            $pdo->exec("ALTER TABLE `{$fk['TABLE_NAME']}` DROP FOREIGN KEY `{$fk['CONSTRAINT_NAME']}`");
            $dropped[] = $fk;
        } catch (\Throwable $e) {
            $report['errors']['drop_fk_' . $fk['CONSTRAINT_NAME']] = $e->getMessage();
        }
    }

    $failed = false;
    try {
        foreach ($bad as $table) {
            try {
                // CONVERT TO rewrites every text column in the table in one pass.
                $pdo->exec("ALTER TABLE `$table` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
                $report['converted'][] = $table;
            } catch (\Throwable $e) {
                // One stubborn table must not strand the rest.
                $report['errors'][$table] = $e->getMessage();
                $failed = true;
            }
        }
    } finally {
        // Always put the constraints back, even if a conversion threw.
        foreach ($dropped as $fk) {
            try {
                $pdo->exec(
                    "ALTER TABLE `{$fk['TABLE_NAME']}` ADD CONSTRAINT `{$fk['CONSTRAINT_NAME']}`"
                    . " FOREIGN KEY (" . $quote($fk['cols']) . ")"
                    . " REFERENCES `{$fk['REFERENCED_TABLE_NAME']}` (" . $quote($fk['refs']) . ")"
                    . " ON DELETE {$fk['DELETE_RULE']} ON UPDATE {$fk['UPDATE_RULE']}"
                );
                $report['fks_restored']++;
            } catch (\Throwable $e) {
                $report['errors']['restore_fk_' . $fk['CONSTRAINT_NAME']] = $e->getMessage();
                $failed = true;
            }
        }
    }

    $report['status'] = $failed ? 'partial' : 'ok';
    $GLOBALS['utf8mb4_migration'] = $report;

    // Only stop re-checking once everything came out clean.
    if (!$failed) {
        @file_put_contents($marker, date('c'));
    }
}

/**
 * Give the money tables the cascading foreign keys everything else already has.
 *
 * Three separate mechanisms decide what a delete takes with it — the recycle
 * bin's archive, `soft_delete_cascade()`, and the restore that reads the
 * archived payload — and all three ask the database the same question: which
 * tables point here with ON DELETE CASCADE. That is one map, derived rather
 * than written down, which is why chit groups have always taken their members,
 * schedules and contributions with them.
 *
 * `fund_payments` and `collections` were never given the key. They are the two
 * tables that hold received money, so the consequences were the worst kind of
 * quiet:
 *
 *   - Deleting a fund left its deposits live. Cash In Hand sums
 *     `fund_payments WHERE delflag = 0` without consulting the fund, so the
 *     money stayed on the books for ever while the fund sat in the bin.
 *   - The rows were never archived either, so restoring the fund brought back
 *     an empty shell — the passbook was gone even though the deposits were
 *     still in the table, now pointing at a fund that had been deleted.
 *   - Deleting a loan did the same to its receipts.
 *
 * Adding the key fixes all three at once, because all three read it.
 *
 * Rows whose parent has already vanished would make the key impossible. They
 * are reported and the key is skipped rather than deleted: an orphaned receipt
 * is somebody's money, and a migration is not the place to decide it never
 * happened.
 */
function ensure_cascade_foreign_keys(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_cascade_fk_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    $wanted = [
        // child table      => [column, parent table, constraint name]
        ['fund_payments', 'fund_id', 'funds', 'fk_fund_payments_fund'],
        ['collections',   'loan_id', 'loans', 'fk_collections_loan'],
    ];

    try {
        $pdo = Database::pdo();
        $allDone = true;

        foreach ($wanted as [$child, $col, $parent, $name]) {
            // Already cascading? Nothing to do. A key that exists with the
            // wrong rule is left alone — dropping somebody's constraint is not
            // this function's business.
            $existing = $pdo->prepare(
                "SELECT rc.DELETE_RULE
                   FROM information_schema.REFERENTIAL_CONSTRAINTS rc
                   JOIN information_schema.KEY_COLUMN_USAGE k
                     ON k.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                    AND k.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
                  WHERE rc.CONSTRAINT_SCHEMA = DATABASE()
                    AND rc.TABLE_NAME = ? AND k.COLUMN_NAME = ?
                    AND rc.REFERENCED_TABLE_NAME = ?"
            );
            $existing->execute([$child, $col, $parent]);
            if ($existing->fetchColumn() !== false) continue;

            // Both tables have to be there, which they will not be on a
            // database still being built.
            $have = $pdo->prepare(
                "SELECT COUNT(*) FROM information_schema.TABLES
                  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?, ?)"
            );
            $have->execute([$child, $parent]);
            if ((int)$have->fetchColumn() !== 2) { $allDone = false; continue; }

            $orphans = $pdo->query(
                "SELECT COUNT(*) FROM `$child` c
                   LEFT JOIN `$parent` p ON p.`id` = c.`$col`
                  WHERE c.`$col` IS NOT NULL AND p.`id` IS NULL"
            )->fetchColumn();

            if ((int)$orphans > 0) {
                error_log(
                    "ensure_cascade_foreign_keys: $child has $orphans row(s) whose $parent no longer exists; "
                    . "the cascade key was not created. Reattach or remove them by hand — deleting money here "
                    . "is a decision for a person."
                );
                $allDone = false;
                continue;
            }

            try {
                $pdo->exec(
                    "ALTER TABLE `$child`
                       ADD CONSTRAINT `$name` FOREIGN KEY (`$col`)
                       REFERENCES `$parent` (`id`) ON DELETE CASCADE"
                );
            } catch (\Throwable $e) {
                error_log("ensure_cascade_foreign_keys: could not add $name: " . $e->getMessage());
                $allDone = false;
            }
        }

        // Only stop checking once every key is in place, so a database that
        // needed a hand gets another look on the next deploy.
        if ($allDone) @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        error_log('ensure_cascade_foreign_keys: ' . $e->getMessage());
    }
}

ensure_cascade_foreign_keys();

/**
 * Flag children the parent left behind before the cascade key existed.
 *
 * A fund deleted last week still has live deposits, and Cash In Hand is still
 * counting them. The key stops it happening again but does not go back over
 * what already happened, so the rows are brought into line with the parent
 * that is already in the recycle bin — restoring the parent unflags them
 * again, exactly as it would for a delete made today.
 */
function backfill_orphaned_soft_deletes(): void
{
    static $ran = false;
    if ($ran) return;
    $ran = true;

    $marker = sys_get_temp_dir() . '/rrgroups_orphan_delflag_' . md5(__DIR__) . '.ok';
    if (is_file($marker)) return;

    try {
        $pdo = Database::pdo();
        foreach ([['fund_payments', 'fund_id', 'funds'], ['collections', 'loan_id', 'loans']] as [$child, $col, $parent]) {
            if (!table_has_delflag($child) || !table_has_delflag($parent)) continue;

            $pdo->prepare(
                "UPDATE `$child` c
                   JOIN `$parent` p ON p.`id` = c.`$col`
                    SET c.`delflag`    = 1,
                        c.`deleted_at` = COALESCE(c.`deleted_at`, p.`deleted_at`, NOW()),
                        c.`deleted_by` = COALESCE(c.`deleted_by`, p.`deleted_by`)
                 WHERE p.`delflag` = 1 AND c.`delflag` = 0"
            )->execute();
        }
        @file_put_contents($marker, date('c'));
    } catch (\Throwable $e) {
        error_log('backfill_orphaned_soft_deletes: ' . $e->getMessage());
    }
}

backfill_orphaned_soft_deletes();

ensure_utf8mb4_charset();

/**
 * Gate a maintenance script so it is not simply a public URL.
 *
 * The repair and diagnostic scripts were written to be run from a browser on
 * production, and every one of them shipped with no authentication at all.
 * On a live site that meant anybody who guessed a filename could read
 * customer names, loan numbers, fund numbers and amounts out of a dry run —
 * and `?confirm=` would let them APPLY it. `reset_data.php` deletes the
 * business's records. None of that needed a password.
 *
 * On the CLI there is nothing to check: being able to run `php` on the server
 * already means more access than this grants. Over HTTP it takes an admin
 * token, which `bearer_token()` reads from the Authorization header or, so
 * that these stay usable from a browser address bar, from `?token=`.
 */
function require_maintenance_admin(): void
{
    if (PHP_SAPI === 'cli') return;

    $token = bearer_token();
    $claims = $token ? Jwt::decode($token) : null;
    $role = strtolower(trim((string)($claims['role'] ?? '')));

    if ($role !== 'admin') {
        http_response_code(403);
        header('Content-Type: text/plain; charset=utf-8');
        echo "Forbidden.\n\n";
        echo "This is a maintenance script. Run it from the command line, or\n";
        echo "append ?token=<your admin token> to the URL.\n\n";
        echo "Better still: delete it. It was written for one deploy, and a\n";
        echo "file that can rewrite the books should not outlive the job.\n";
        exit;
    }
}
