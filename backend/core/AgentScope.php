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
 * Three shapes of ownership:
 *
 *   OWNED    the record names its agent: loans and funds carry `assigned_agent`.
 *
 *   DERIVED  the record hangs off one that does. A repayment instalment has no
 *            agent of its own; it belongs to whoever holds the loan. Scoping
 *            these through the parent is what stops the child table becoming
 *            the way around the parent's rule.
 *
 *   CHIT     the group follows the people in it. A chit group has no agent of
 *            its own — it is visible to whoever handles one of its members'
 *            customers, which is decided once when the customer is created.
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
        'loans' => 'assigned_agent',
        'funds' => 'assigned_agent',
    ];

    /**
     * The customers an agent may read.
     *
     * `customers` was the last table still trusting the browser: its docblock
     * said "Read: any authenticated user (frontend scopes rows per role)", and
     * a signed-in customer could pull the whole borrower directory — every
     * name, mobile number, address, Aadhaar and PAN in the business. The React
     * screens never showed it, which is exactly why nobody noticed; a request
     * does not have to go through a screen.
     *
     * Assignment alone is too narrow, though. A loan or a fund names its own
     * agent, and that does not have to be the customer's: reassigning a
     * customer leaves the old agent still holding the loan, and they have to
     * be able to read the name on it. So an agent sees their own customers
     * plus the customers behind the work they hold — the same "own work"
     * principle `collections` and `fund_payments` already use below.
     */
    private const CUSTOMERS_FOR_AGENT =
        "`assigned_agent` = ?
         OR `id` IN (SELECT `customer_id` FROM `loans` WHERE `assigned_agent` = ? AND `customer_id` IS NOT NULL)
         OR `id` IN (SELECT `customer_id` FROM `funds` WHERE `assigned_agent` = ? AND `customer_id` IS NOT NULL)
         OR `id` IN (SELECT `customer_id` FROM `chit_members` `cm`
                      WHERE `cm`.`delflag` = 0 AND `cm`.`customer_id` IS NOT NULL
                        AND `cm`.`group_id` IN (
                              SELECT `m2`.`group_id` FROM `chit_members` `m2`
                                JOIN `customers` `c2` ON `c2`.`id` = `m2`.`customer_id`
                               WHERE `c2`.`assigned_agent` = ? AND `m2`.`delflag` = 0 AND `c2`.`delflag` = 0))";

    /**
     * The chit groups an agent can see: the ones holding a member who is one
     * of their customers.
     *
     * Chit groups briefly carried an `assigned_agent` of their own, which meant
     * the same agent had to be named twice — once on the customer and again on
     * every group they joined — and the two could disagree. A customer already
     * names their agent when they are created, and a chit member already names
     * their customer, so the group follows the people in it. Nothing to keep in
     * step, and nothing to forget to set.
     *
     * A member with no customer record belongs to nobody and stays admin-only,
     * which is the safe direction: an unlinked row is a gap in the data, not a
     * reason to widen who can read it.
     */
    private const CHIT_GROUPS_FOR_AGENT =
        "SELECT `m`.`group_id` FROM `chit_members` `m`
           JOIN `customers` `c` ON `c`.`id` = `m`.`customer_id`
          WHERE `c`.`assigned_agent` = ? AND `m`.`delflag` = 0 AND `c`.`delflag` = 0";

    /** Chit tables, and the column each one joins back to the group by. */
    private const CHIT = [
        'chit_groups'    => 'id',
        'chit_members'   => 'group_id',
        'chit_schedules' => 'group_id',
        'chit_passbook'  => 'group_id',
        'chit_payments'  => 'group_id',
        'chit_auctions'  => 'group_id',
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
     * settles chit cash by agent, so group visibility is the whole rule.
     */
    private const DERIVED = [
        'repayment_schedule' => ['loan_id',  'loans',       null],
        'collections'        => ['loan_id',  'loans',       'agent_id'],
        'fund_payments'      => ['fund_id',  'funds',       'agent_id'],
        'fund_payouts'       => ['fund_id',  'funds',       'agent_id'],
    ];

    /** True when this table has a rule at all. */
    public static function covers(string $table): bool
    {
        return $table === 'customers'
            || isset(self::OWNED[$table]) || isset(self::DERIVED[$table]) || isset(self::CHIT[$table]);
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

        if ($table === 'customers') {
            QueryParser::addScope(
                '(' . self::CUSTOMERS_FOR_AGENT . ')',
                [$userId, $userId, $userId, $userId]
            );
            return;
        }

        if (isset(self::OWNED[$table])) {
            $col = self::OWNED[$table];
            QueryParser::addScope("`$col` = ?", [$userId]);
            return;
        }

        if (isset(self::CHIT[$table])) {
            $col = self::CHIT[$table];
            QueryParser::addScope("`$col` IN (" . self::CHIT_GROUPS_FOR_AGENT . ")", [$userId]);
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
