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

    /**
     * The column list to SELECT, from `?select=`.
     *
     * This was accepted and then thrown away: every query, whatever it asked
     * for, ran `SELECT *`. Nothing was wrong on screen — the extra columns
     * were simply ignored by the client — so it was invisible until somebody
     * measured. `profiles` answers a request for five columns with 64 KB,
     * because one row carries a 60 KB base64 avatar that the agent dropdowns
     * do not draw. Ten screens asked for less and were sent everything.
     *
     * Rules, in the order they matter:
     *
     *   - Only real columns of this table get through. Names are matched
     *     against the live column map and quoted, so nothing from the query
     *     string reaches SQL as syntax.
     *   - A select naming NO column this table has falls back to `*`. That is
     *     what the caller got before this existed; a perf change should not
     *     turn a client's typo into an empty row.
     *   - Embeds (`*, loans(*)`) are dropped rather than honoured. rest.php
     *     has never resolved them — the one caller that asked for one got a
     *     row without it and did not use it — so silently ignoring the
     *     parenthesised part keeps that exactly as it was, minus the pretence.
     *
     * @param array<string,string> $columns the table's real column map
     */
    public static function columnList(array $columns, array $hide = [], array $flags = []): string
    {
        $raw = trim((string)($_GET['select'] ?? ''));
        if ($columns === []) return '*';

        // Nothing asked for in particular: everything the table has, less
        // the columns it has declared too heavy to list. Naming one of them
        // explicitly still works — that is how the profile modal and the
        // edit form fetch one customer's papers.
        if ($raw === '' || $raw === '*') {
            if (!$hide) return '*';
            $keep = array_diff(array_keys($columns), $hide);
            if (!$keep) return '*';
            $sql = array_map(fn($c) => '`' . str_replace('`', '', $c) . '`', $keep);
            // For each hidden column the model asks to have reported, one
            // byte saying whether it holds anything. That is what lets an
            // avatar tell "no photograph" from "not fetched yet", instead
            // of asking for a picture that was never taken.
            foreach ($flags as $col => $alias) {
                if (!isset($columns[$col]) || !in_array($col, $hide, true)) continue;
                $c = '`' . str_replace('`', '', $col) . '`';
                $a = '`' . str_replace('`', '', (string)$alias) . '`';
                $sql[] = "($c IS NOT NULL AND $c <> '') AS $a";
            }
            return implode(', ', $sql);
        }

        // Strip embedded resources: `loans(*)`, `customers(id,name)`.
        $raw = preg_replace('/[A-Za-z_][A-Za-z0-9_]*\s*\([^()]*\)/', '', $raw) ?? '';

        $picked = [];
        foreach (explode(',', $raw) as $part) {
            $name = trim($part);
            if ($name === '') continue;
            if ($name === '*') return '*';
            // PostgREST allows `alias:column`; only the column is meaningful here.
            if (str_contains($name, ':')) $name = trim(substr($name, strrpos($name, ':') + 1));
            if (!isset($columns[$name])) continue;
            $picked[$name] = '`' . str_replace('`', '', $name) . '`';
        }
        if ($picked === []) return '*';

        return implode(', ', $picked);
    }}
