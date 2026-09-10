<?php
/**
 * Narrows what a signed-in agent can read to the records assigned to them.
 *
 * Every controller used to carry the same line in its docblock — "Read: any
 * authenticated user (frontend scopes rows per role)" — which is not a rule,
 * it is a hope. `rest.php` handed an agent the whole book and trusted the
 * React screen to hide the rest of it. Some screens did (the agent dashboard,
 * the route sheet); the shared ones did not, so an agent opening Funds or
 * Loans saw every customer in the business, and anything the browser can be
 * persuaded not to render is still a request away.
 *
 * The rule lives here instead, and is injected as a SQL clause before
 * QueryParser builds the WHERE — the same seam the soft-delete filter uses —
 * so it applies to every read through rest.php rather than being remembered
 * per screen.
 *
 * Two shapes of ownership:
 *
 *   OWNED    the record names its agent: loans, funds and chit groups all
 *            carry `assigned_agent`.
 *
 *   DERIVED  the record hangs off one that does. A repayment instalment has no
 *            agent of its own; it belongs to whoever holds the loan. Scoping
 *            these through the parent is what stops the child table becoming
 *            the way around the parent's rule.
 *
 * Because the clause is ANDed on last, a caller's own filter can only narrow
 * the result further. Asking for another agent's loan by id returns nothing
 * rather than quietly returning your own — no intersection logic needed, and
 * no operator the parser might not recognise can widen it.
 */
class AgentScope
{
    /** table => the column naming the agent it belongs to. */
    private const OWNED = [
        'loans'       => 'assigned_agent',
        'funds'       => 'assigned_agent',
        'chit_groups' => 'assigned_agent',
    ];

    /**
     * table => [foreign key on this table, parent table, column recording who
     * did the work — or null when the parent alone decides].
     *
     * `collections` and `fund_payments` carry that last column, and it is not
     * the same question as who holds the loan: it is the agent who physically
     * took the money and still owes it at handover. If a loan is reassigned,
     * the cash already in the old agent's pocket does not move with it, so
     * their own receipts stay visible to them — the Cash Handover screen counts
     * exactly these rows, and scoping them by the parent alone would tell an
     * agent they owe less than they are holding.
     *
     * Chit contributions are deliberately not given that clause: no screen
     * settles chit cash by agent, so the group's assignment is the whole rule.
     */
    private const DERIVED = [
        'repayment_schedule' => ['loan_id',  'loans',       null],
        'collections'        => ['loan_id',  'loans',       'agent_id'],
        'fund_payments'      => ['fund_id',  'funds',       'agent_id'],
        'chit_members'       => ['group_id', 'chit_groups', null],
        'chit_schedules'     => ['group_id', 'chit_groups', null],
        'chit_passbook'      => ['group_id', 'chit_groups', null],
        'chit_payments'      => ['group_id', 'chit_groups', null],
        'chit_auctions'      => ['group_id', 'chit_groups', null],
    ];

    /** True when this table has a rule at all. */
    public static function covers(string $table): bool
    {
        return isset(self::OWNED[$table]) || isset(self::DERIVED[$table]);
    }

    /**
     * Apply the agent's scope to $table for the rest of the request.
     *
     * Admins and customers are untouched — a customer is pinned to their own
     * `customer_id` by their own controllers, which is a different rule.
     * Calling this more than once for the same table is harmless.
     */
    public static function apply(string $table, string $role, ?string $userId): void
    {
        if ($role !== 'agent' || !$userId) return;

        if (isset(self::OWNED[$table])) {
            $col = self::OWNED[$table];
            QueryParser::addScope("`$col` = ?", [$userId]);
            return;
        }

        if (!isset(self::DERIVED[$table])) return;

        [$fk, $parent, $ownWork] = self::DERIVED[$table];
        $parentCol = self::OWNED[$parent] ?? 'assigned_agent';

        // A subquery rather than a list of ids: an agent with two thousand
        // collections would otherwise put two thousand placeholders in every
        // query, and the list would be stale the moment a loan is reassigned.
        $clause = "`$fk` IN (SELECT `id` FROM `$parent` WHERE `$parentCol` = ?)";
        $binds  = [$userId];

        if ($ownWork !== null) {
            $clause .= " OR `$ownWork` = ?";
            $binds[] = $userId;
        }

        QueryParser::addScope($clause, $binds);
    }
}
