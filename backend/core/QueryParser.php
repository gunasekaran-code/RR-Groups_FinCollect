<?php
// Parses PostgREST-lite query params ($_GET) into SQL WHERE / ORDER / LIMIT.
// Filters:  column=<op>.<value>   ops: eq, neq, gt, gte, lt, lte, like, ilike, in, is

class QueryParser
{
    private const RESERVED = ['table', 'select', 'order', 'limit', 'offset', 'upsert', 'on_conflict', 'action', 'token'];

    /**
     * Clauses the server adds on its own behalf, ANDed into every WHERE built
     * for the rest of the request.
     *
     * $_GET filters can only ever say `column op value`, which is enough to
     * hide another agent's loans but not to express "a collection on one of my
     * loans *or* one I took myself" — and turning that into an id list would
     * put thousands of placeholders in the query. A scope is a small piece of
     * SQL with its own bindings instead.
     *
     * @var array<int,array{0:string,1:array}>
     */
    private static array $scopes = [];

    /** Add a clause the caller cannot see, override or remove. */
    public static function addScope(string $sql, array $binds = []): void
    {
        $sql = trim($sql);
        if ($sql === '') return;
        foreach (self::$scopes as $existing) {
            if ($existing[0] === $sql && $existing[1] === $binds) return;   // idempotent
        }
        self::$scopes[] = [$sql, $binds];
    }

    /** Drop every registered scope. For tests, which share one process. */
    public static function resetScopes(): void
    {
        self::$scopes = [];
    }

    /** @return array{0:string,1:array} [sqlFragment, binds] */
    public static function where(array $columns): array
    {
        if (empty($columns)) {
            // A scope must still bite on a table with no column map, or the
            // absence of one would be a way past it.
            $sql = ''; $binds = [];
            foreach (self::$scopes as [$clause, $b]) {
                $sql .= ($sql === '' ? ' WHERE ' : ' AND ') . "($clause)";
                foreach ($b as $one) $binds[] = $one;
            }
            return [$sql, $binds];
        }
        $clauses = [];
        $binds = [];
        foreach ($_GET as $key => $raw) {
            if (in_array($key, self::RESERVED, true)) {
                continue;
            }
            if (!isset($columns[$key])) {
                continue;
            }
            $col = "`$key`";
            $dot = strpos($raw, '.');
            $op = $dot === false ? 'eq' : substr($raw, 0, $dot);
            $val = $dot === false ? $raw : substr($raw, $dot + 1);

            switch ($op) {
                case 'eq':  $clauses[] = "$col = ?";  $binds[] = $val; break;
                case 'neq': $clauses[] = "$col <> ?"; $binds[] = $val; break;
                case 'gt':  $clauses[] = "$col > ?";  $binds[] = $val; break;
                case 'gte': $clauses[] = "$col >= ?"; $binds[] = $val; break;
                case 'lt':  $clauses[] = "$col < ?";  $binds[] = $val; break;
                case 'lte': $clauses[] = "$col <= ?"; $binds[] = $val; break;
                case 'like':
                case 'ilike': $clauses[] = "$col LIKE ?"; $binds[] = $val; break;
                case 'is':
                    if (strtolower($val) === 'null')        { $clauses[] = "$col IS NULL"; }
                    elseif (strtolower($val) === 'not.null') { $clauses[] = "$col IS NOT NULL"; }
                    else { $clauses[] = "$col = ?"; $binds[] = $val; }
                    break;
                case 'in':
                    $items = ($list = trim($val, '()')) === '' ? [] : explode(',', $list);
                    if (!$items) { $clauses[] = '1 = 0'; break; }
                    $ph = implode(',', array_fill(0, count($items), '?'));
                    $clauses[] = "$col IN ($ph)";
                    foreach ($items as $it) { $binds[] = trim($it, '"'); }
                    break;
                default:
                    json_error("Unsupported filter operator: $op", 400);
            }
        }
        // Scopes go on last so a caller's filter can only ever narrow the
        // result further, never widen it past what the scope allows.
        foreach (self::$scopes as [$clause, $scopeBinds]) {
            $clauses[] = "($clause)";
            foreach ($scopeBinds as $one) $binds[] = $one;
        }

        $sql = $clauses ? (' WHERE ' . implode(' AND ', $clauses)) : '';
        return [$sql, $binds];
    }

    public static function order(array $columns): string
    {
        $order = $_GET['order'] ?? '';
        if ($order === '' || empty($columns)) {
            return '';
        }
        $parts = [];
        foreach (explode(',', $order) as $spec) {
            $spec = trim($spec);
            if ($spec === '') continue;
            $bits = explode('.', $spec);
            $col = $bits[0];
            if (!isset($columns[$col])) {
                continue;
            }
            $dir = (isset($bits[1]) && strtolower($bits[1]) === 'desc') ? 'DESC' : 'ASC';
            $parts[] = "`$col` $dir";
        }
        return $parts ? (' ORDER BY ' . implode(', ', $parts)) : '';
    }

    public static function limit(): string
    {
        if (isset($_GET['limit']) && ctype_digit((string)$_GET['limit'])) {
            $sql = ' LIMIT ' . (int)$_GET['limit'];
            if (isset($_GET['offset']) && ctype_digit((string)$_GET['offset'])) {
                $sql .= ' OFFSET ' . (int)$_GET['offset'];
            }
            return $sql;
        }
        return '';
    }
}
