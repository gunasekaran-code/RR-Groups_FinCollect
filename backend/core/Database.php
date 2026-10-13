<?php
// PDO connection singleton.

class Database
{
    private static ?PDO $pdo = null;

    public static function pdo(): PDO
    {
        if (self::$pdo instanceof PDO) {
            return self::$pdo;
        }
        $d = config('db');
        $charset = !empty($d['charset']) ? $d['charset'] : 'utf8mb4';
        $dsn = "mysql:host={$d['host']};port={$d['port']};dbname={$d['name']};charset={$charset}";
        try {
            self::$pdo = new PDO($dsn, $d['user'], $d['pass'], [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES   => false,
                PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
            ]);
            // SET NAMES already sets character_set_client, _connection and
            // _results *and* the collation. `SET CHARACTER SET utf8mb4` used to
            // follow it here and silently undid half of it: that statement
            // resets collation_connection to the DATABASE's own default
            // collation, not the charset's.
            //
            // Whether that mattered depended on the server. Locally the database
            // defaults to utf8mb4_unicode_ci, so nothing moved. On cPanel the
            // database defaults to utf8mb4_general_ci — and ALTER DATABASE is
            // usually denied to a shared-hosting user, so it stays that way —
            // which left every bound string at general_ci while every column the
            // schema created is unicode_ci. Comparing the two is illegal, and a
            // chit payout died on exactly that: "Illegal mix of collations
            // (utf8mb4_general_ci,COERCIBLE) and (utf8mb4_unicode_ci,COERCIBLE)".
            self::$pdo->exec("SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci");
            try {
                self::$pdo->exec("SET SESSION sql_mode=(SELECT REPLACE(@@sql_mode,'ONLY_FULL_GROUP_BY',''))");
            } catch (Throwable $e) {
                // Ignore if not supported
            }
        } catch (PDOException $e) {
            json_error('Database connection failed: ' . $e->getMessage(), 500);
        }
        return self::$pdo;
    }
}
