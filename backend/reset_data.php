<?php
/**
 * Empty the database of operational data, keeping one admin login and the
 * company settings.
 *
 * Usage
 *   Browser (production):  https://rrgroupscbe.com/backend/reset_data.php
 *   CLI (local):           php backend/reset_data.php
 *
 * Both forms are a DRY RUN by default: they report exactly what would be
 * removed and change nothing. Add ?confirm=YES-DELETE-EVERYTHING (or the
 * --confirm flag on the CLI) to actually perform it.
 *
 * The admin to keep is matched by email, admin@fincollect.in unless
 * ?keep_admin=<email> names another. If that lookup does not find exactly one
 * live admin the script refuses to touch anything — without that guard, running
 * this against a database whose admin uses a different address would delete
 * every login and lock everybody out.
 *
 * DELETE THIS FILE once the reset is done. Anyone who can reach the URL can
 * empty the database.
 */
error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('max_execution_time', 300);

$isCli = php_sapi_name() === 'cli';
if (!$isCli) {
    header('Content-Type: application/json; charset=utf-8');
    header('Access-Control-Allow-Origin: *');
}

$argvFlags = $isCli ? array_slice($argv, 1) : [];
$confirmed = $isCli
    ? in_array('--confirm', $argvFlags, true)
    : (($_GET['confirm'] ?? '') === 'YES-DELETE-EVERYTHING');

$keepEmail = 'admin@fincollect.in';
foreach ($argvFlags as $a) {
    if (str_starts_with($a, '--keep-admin=')) $keepEmail = substr($a, 13);
}
if (!$isCli && !empty($_GET['keep_admin'])) $keepEmail = (string)$_GET['keep_admin'];

$report = [
    'timestamp'  => date('c'),
    'mode'       => $confirmed ? 'EXECUTE' : 'DRY RUN - nothing was changed',
    'keep_admin' => $keepEmail,
    'errors'     => [],
];

function finish(array $report, bool $isCli): void
{
    $flags = JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE;
    if ($isCli) $flags |= JSON_UNESCAPED_SLASHES;
    echo json_encode($report, $flags), "\n";
    exit(empty($report['errors']) ? 0 : 1);
}

// -- connect ---------------------------------------------------------------
try {
    $cfg = require __DIR__ . '/config.php';
    $d   = $cfg['db'];
    $pdo = new PDO(
        "mysql:host={$d['host']};port={$d['port']};dbname={$d['name']};charset=utf8mb4",
        $d['user'], $d['pass'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
    );
    $pdo->exec('SET NAMES utf8mb4');
    $report['database'] = $d['name'];
} catch (Throwable $e) {
    $report['errors']['connect'] = $e->getMessage();
    finish($report, $isCli);
}

// -- what survives ---------------------------------------------------------
// `profiles` and `biometric_credentials` are pruned rather than emptied, so
// they are not in the wipe list; `settings` is left alone entirely.
$keepWhole = ['settings'];
$prune     = ['profiles', 'biometric_credentials'];
$wipe = [
    'account_ledger', 'chit_groups', 'chit_members', 'chit_passbook',
    'chit_payments', 'chit_schedules', 'collections', 'customers',
    'fund_payments', 'funds', 'handovers', 'loans', 'notifications',
    'promo_popups', 'push_subscriptions', 'recycle_bin', 'repayment_schedule',
];

$present = $pdo->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN);

// A table this script has never heard of would otherwise keep its rows without
// anyone noticing, so name it in the report instead of guessing.
$unknown = array_values(array_diff($present, $keepWhole, $prune, $wipe));
if ($unknown) $report['unrecognised_tables_left_untouched'] = $unknown;
$missing = array_values(array_diff($wipe, $present));
if ($missing) $report['listed_but_absent'] = $missing;

// -- the guard -------------------------------------------------------------
$st = $pdo->prepare(
    "SELECT id, email, full_name, user_code, role FROM profiles
      WHERE email = ? AND role = 'admin' AND (delflag IS NULL OR delflag = 0)"
);
$st->execute([$keepEmail]);
$admins = $st->fetchAll();

if (count($admins) !== 1) {
    $report['errors']['admin_lookup'] =
        count($admins) . " live admin profile(s) matched '$keepEmail' - expected exactly 1. "
        . 'Nothing was changed. Pass ?keep_admin=<email> naming the admin to keep.';
    $report['available_admins'] = $pdo->query(
        "SELECT email, full_name, user_code FROM profiles
          WHERE role = 'admin' AND (delflag IS NULL OR delflag = 0)"
    )->fetchAll();
    finish($report, $isCli);
}
$adminId = $admins[0]['id'];
$report['keeping'] = $admins[0];

// -- counts before ---------------------------------------------------------
$before = [];
foreach ($present as $t) $before[$t] = (int)$pdo->query("SELECT COUNT(*) FROM `$t`")->fetchColumn();
$report['rows_before'] = $before;

$st = $pdo->prepare('SELECT COUNT(*) FROM profiles WHERE id <> ?');
$st->execute([$adminId]);
$profilesGoing = (int)$st->fetchColumn();

$st = $pdo->prepare('SELECT COUNT(*) FROM biometric_credentials WHERE user_id <> ?');
$st->execute([$adminId]);
$bioGoing = (int)$st->fetchColumn();

$report['would_delete'] = [
    'profiles'              => $profilesGoing,
    'biometric_credentials' => $bioGoing,
] + array_intersect_key($before, array_flip($wipe));

if (!$confirmed) {
    $report['next_step'] = $isCli
        ? 'php backend/reset_data.php --confirm'
        : 'Take a phpMyAdmin backup, then reload this URL with ?confirm=YES-DELETE-EVERYTHING';
    finish($report, $isCli);
}

// -- do it -----------------------------------------------------------------
// DELETE rather than TRUNCATE: TRUNCATE is DDL and commits implicitly, which
// would leave a half-emptied database behind if a later statement failed.
try {
    $pdo->exec('SET FOREIGN_KEY_CHECKS = 0');
    $pdo->beginTransaction();

    $deleted = [];
    foreach ($wipe as $t) {
        if (!in_array($t, $present, true)) continue;
        $deleted[$t] = $pdo->exec("DELETE FROM `$t`");
    }

    $st = $pdo->prepare('DELETE FROM biometric_credentials WHERE user_id <> ?');
    $st->execute([$adminId]);
    $deleted['biometric_credentials'] = $st->rowCount();

    $st = $pdo->prepare('DELETE FROM profiles WHERE id <> ?');
    $st->execute([$adminId]);
    $deleted['profiles'] = $st->rowCount();

    // An admin pinned to a customer row that no longer exists would make the
    // customer-scoped screens read against a dangling id.
    $st = $pdo->prepare('UPDATE profiles SET customer_id = NULL WHERE id = ? AND customer_id IS NOT NULL');
    $st->execute([$adminId]);
    if ($st->rowCount()) $deleted['admin_customer_id_cleared'] = 1;

    // The surviving admin is the first admin again.
    $pdo->prepare("UPDATE profiles SET user_code = 'RRG-ADM-0001' WHERE id = ?")->execute([$adminId]);

    $pdo->commit();
    $pdo->exec('SET FOREIGN_KEY_CHECKS = 1');

    $report['deleted'] = $deleted;
} catch (Throwable $e) {
    if ($pdo->inTransaction()) $pdo->rollBack();
    $pdo->exec('SET FOREIGN_KEY_CHECKS = 1');
    $report['errors']['reset'] = $e->getMessage();
    $report['mode'] = 'FAILED - rolled back, database unchanged';
    finish($report, $isCli);
}

$after = [];
foreach ($present as $t) $after[$t] = (int)$pdo->query("SELECT COUNT(*) FROM `$t`")->fetchColumn();
$report['rows_after'] = $after;
$report['remaining_logins'] = $pdo->query('SELECT email, full_name, user_code, role FROM profiles')->fetchAll();
$report['done'] = 'Database reset. Delete backend/reset_data.php now.';

finish($report, $isCli);
