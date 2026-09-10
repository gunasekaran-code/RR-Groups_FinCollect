<?php
/**
 * One agent's book of customers, and whether each has paid.
 *
 * Answering "has this customer paid?" needs four tables at once — the loan for
 * what is owed, the schedule for what falls due and when, collections for what
 * came in, and chit_passbook for the chit side. Doing that in the browser would
 * mean pulling every customer, loan, instalment and receipt down to the client
 * and joining them there, which is both slow and a leak: an agent's book is
 * admin-only information.
 *
 * So it is computed here, in one pass, and the screen renders what comes back.
 */
class AgentPortfolio
{
    /**
     * @param string      $agentId profiles.id of the agent
     * @param string|null $onDate  the day "collected today" is measured against
     */
    public static function forAgent(string $agentId, ?string $onDate = null): array
    {
        $pdo   = Database::pdo();
        $today = $onDate ?: date('Y-m-d');

        $stmt = $pdo->prepare(
            "SELECT id, full_name, email, mobile, role, status, user_code, avatar_url, created_at
               FROM profiles WHERE id = ? AND delflag = 0 LIMIT 1"
        );
        $stmt->execute([$agentId]);
        $agent = $stmt->fetch();
        if (!$agent) json_error('That agent no longer exists', 404);

        $orphans   = self::unlinkedLoans($pdo, $agentId, $today);
        $customers = self::customersOf($pdo, $agentId, (string)$agent['full_name']);
        if (!$customers) {
            return [
                'agent' => $agent, 'as_of' => $today, 'customers' => [],
                'unlinked_loans' => $orphans, 'summary' => self::emptySummary(),
            ];
        }

        $ids     = array_column($customers, 'id');
        $loans   = self::loansByCustomer($pdo, $ids);
        $due     = self::nextDueByCustomer($pdo, $ids, $today);
        $paid    = self::collectionsByCustomer($pdo, $ids, $today, $agentId);
        $chits   = self::chitDueByCustomer($pdo, $ids, $today);
        // The three products a customer can hold, itemised. The totals above
        // answer "how much"; these answer "on what".
        $loanList = self::loanList($pdo, $ids, $agentId, $today);
        $chitList = self::chitList($pdo, $ids, $today);
        $fundList = self::fundList($pdo, $ids, $agentId);

        $rows = [];
        foreach ($customers as $c) {
            $id = $c['id'];
            $rows[] = self::describe($c, $loans[$id] ?? null, $due[$id] ?? null,
                                    $paid[$id] ?? null, $chits[$id] ?? null, $agentId, $today,
                                    $loanList[$id] ?? [], $chitList[$id] ?? [], $fundList[$id] ?? []);
        }

        // Whoever needs chasing first: overdue, then due today, then the rest.
        $rank = ['overdue' => 0, 'due_today' => 1, 'upcoming' => 2, 'collected' => 3, 'settled' => 4, 'no_loan' => 5];
        usort($rows, function ($a, $b) use ($rank) {
            $ra = $rank[$a['status']] ?? 9;
            $rb = $rank[$b['status']] ?? 9;
            if ($ra !== $rb) return $ra <=> $rb;
            return $b['days_overdue'] <=> $a['days_overdue']
                ?: strcasecmp($a['full_name'], $b['full_name']);
        });

        return [
            'agent'          => $agent,
            'as_of'          => $today,
            'customers'      => $rows,
            // Loans the agent is collecting on that point at no customer.
            'unlinked_loans' => $orphans,
            'summary'        => self::summarize($rows, $orphans),
        ];
    }

    /**
     * Reattach a loose loan to a customer, and everything hanging off it.
     *
     * The receipts against the loan are moved with it — they were cut loose by
     * the same `ON DELETE SET NULL` that orphaned the loan, and leaving them
     * behind would put the loan on a customer's book showing nothing ever paid.
     *
     * @return array{loan: array, collections_relinked: int}
     */
    public static function attachLoan(string $loanId, string $customerId): array
    {
        $pdo = Database::pdo();

        $stmt = $pdo->prepare('SELECT * FROM `loans` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$loanId]);
        $loan = $stmt->fetch();
        if (!$loan) json_error('That loan no longer exists', 404);

        $stmt = $pdo->prepare('SELECT * FROM `customers` WHERE `id` = ? AND `delflag` = 0 LIMIT 1');
        $stmt->execute([$customerId]);
        $customer = $stmt->fetch();
        if (!$customer) json_error('That customer no longer exists', 404);

        $pdo->beginTransaction();
        try {
            $pdo->prepare(
                'UPDATE `loans` SET `customer_id` = ?, `customer_name` = ? WHERE `id` = ?'
            )->execute([$customerId, $customer['full_name'], $loanId]);

            $moved = $pdo->prepare(
                'UPDATE `collections` SET `customer_id` = ?, `customer_name` = ?
                  WHERE `loan_id` = ? AND (`customer_id` IS NULL OR `customer_id` = ?)'
            );
            $moved->execute([$customerId, $customer['full_name'], $loanId, $loan['customer_id']]);
            $relinked = $moved->rowCount();

            $pdo->commit();
        } catch (\Throwable $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            throw $e;
        }

        // The loan's figures and the customer's directory status both follow
        // from the link that just changed.
        LoanRecalc::sync($loanId);
        Customer::recalcLoanStatus([$customerId]);

        $stmt = $pdo->prepare('SELECT * FROM `loans` WHERE `id` = ? LIMIT 1');
        $stmt->execute([$loanId]);

        return [
            'loan'                 => $stmt->fetch() ?: null,
            'collections_relinked' => $relinked,
        ];
    }
    // ─────────────────────────── who is under them ─────────────────────────

    /**
     * A customer counts as this agent's when they are assigned to them, or when
     * a loan of theirs is. Older rows stored the agent's *name* in
     * customers.assigned_agent instead of their id, and those customers would
     * otherwise vanish from the agent's book entirely.
     */
    private static function customersOf(PDO $pdo, string $agentId, string $agentName): array
    {
        $stmt = $pdo->prepare(
            "SELECT DISTINCT c.id, c.customer_id, c.full_name, c.mobile, c.address,
                    c.loan_status, c.assigned_agent, c.latitude, c.longitude, c.created_at
               FROM customers c
               LEFT JOIN loans l ON l.customer_id = c.id AND l.delflag = 0
               LEFT JOIN funds f ON f.customer_id = c.id AND f.delflag = 0
              WHERE c.delflag = 0
                AND (c.assigned_agent = :aid OR c.assigned_agent = :aname
                     OR l.assigned_agent = :aid2 OR f.assigned_agent = :aid3)
              ORDER BY c.full_name ASC"
        );
        $stmt->execute([':aid' => $agentId, ':aname' => $agentName,
                        ':aid2' => $agentId, ':aid3' => $agentId]);
        return $stmt->fetchAll() ?: [];
    }

    /**
     * Loans assigned to this agent whose customer row is missing or deleted.
     *
     * These are real money — the agent's Collections screen lists them, because
     * that screen works from loans — but a book built from customers cannot
     * show them, and silently dropping a loan with dues on it would make the
     * two screens disagree with no way to see why. They are reported separately
     * so an admin can reattach them.
     */
    private static function unlinkedLoans(PDO $pdo, string $agentId, string $today): array
    {
        $stmt = $pdo->prepare(
            "SELECT l.id, l.loan_number, l.customer_name, l.emi, l.outstanding_balance,
                    l.penalty_amount, l.status,
                    (SELECT MIN(s.due_date) FROM repayment_schedule s
                      WHERE s.loan_id = l.id AND s.delflag = 0
                        AND s.status <> 'paid' AND s.balance > 0)     AS next_due_date,
                    (SELECT COALESCE(SUM(s.balance), 0) FROM repayment_schedule s
                      WHERE s.loan_id = l.id AND s.delflag = 0
                        AND s.status <> 'paid' AND s.due_date <= ?)   AS due_now
               FROM loans l
              WHERE l.delflag = 0 AND l.assigned_agent = ?
                AND (l.customer_id IS NULL
                     OR l.customer_id NOT IN (SELECT id FROM customers WHERE delflag = 0))
              ORDER BY l.status = 'overdue' DESC, l.loan_number ASC"
        );
        $stmt->execute([$today, $agentId]);

        return array_map(static function ($r) {
            return [
                'id'            => $r['id'],
                'loan_number'   => $r['loan_number'],
                'customer_name' => $r['customer_name'],
                'emi'           => (float)$r['emi'],
                'outstanding'   => (float)$r['outstanding_balance'],
                'penalty'       => (float)$r['penalty_amount'],
                'due_now'       => round((float)$r['due_now'], 2),
                'next_due_date' => $r['next_due_date'],
                'status'        => $r['status'],
            ];
        }, $stmt->fetchAll() ?: []);
    }
    // ──────────────────────────── the four reads ───────────────────────────

    private static function loansByCustomer(PDO $pdo, array $ids): array
    {
        $ph = self::placeholders($ids);
        $stmt = $pdo->prepare(
            "SELECT customer_id,
                    COUNT(*)                                             AS loans,
                    SUM(status = 'active' OR status = 'overdue')         AS open_loans,
                    SUM(status = 'overdue')                              AS overdue_loans,
                    COALESCE(SUM(outstanding_balance), 0)                AS outstanding,
                    COALESCE(SUM(penalty_amount), 0)                     AS penalty,
                    COALESCE(SUM(total_repayment), 0)                    AS total_repayment,
                    MIN(loan_number)                                     AS loan_number
               FROM loans
              WHERE delflag = 0 AND customer_id IN ($ph)
              GROUP BY customer_id"
        );
        $stmt->execute($ids);
        return self::keyBy($stmt->fetchAll(), 'customer_id');
    }

    /**
     * The earliest instalment still owed, and what is already past its date.
     * A loan closed or fully paid contributes nothing.
     */
    private static function nextDueByCustomer(PDO $pdo, array $ids, string $today): array
    {
        $ph = self::placeholders($ids);
        $stmt = $pdo->prepare(
            "SELECT l.customer_id,
                    MIN(CASE WHEN s.due_date >= ? THEN s.due_date END)            AS next_due_date,
                    MIN(CASE WHEN s.due_date <  ? THEN s.due_date END)            AS oldest_overdue_date,
                    COALESCE(SUM(CASE WHEN s.due_date <= ? THEN s.balance END), 0) AS due_now,
                    COALESCE(SUM(CASE WHEN s.due_date <  ? THEN s.balance END), 0) AS overdue_amount,
                    SUM(s.due_date = ?)                                            AS due_today_count
               FROM repayment_schedule s
               JOIN loans l ON l.id = s.loan_id AND l.delflag = 0 AND l.status <> 'closed'
              WHERE s.delflag = 0 AND s.status <> 'paid' AND s.balance > 0
                AND l.customer_id IN ($ph)
              GROUP BY l.customer_id"
        );
        $stmt->execute(array_merge([$today, $today, $today, $today, $today], $ids));
        return self::keyBy($stmt->fetchAll(), 'customer_id');
    }

    private static function collectionsByCustomer(PDO $pdo, array $ids, string $today, string $agentId): array
    {
        $ph    = self::placeholders($ids);
        $month = substr($today, 0, 7) . '-01';
        // COALESCE(collection_date, DATE(created_at)) throughout: a receipt saved
        // without a date still happened on the day it was entered, and dropping
        // it would show a paid customer as unpaid.
        $stmt = $pdo->prepare(
            "SELECT customer_id,
                    COALESCE(SUM(CASE WHEN COALESCE(collection_date, DATE(created_at)) = ?
                                      THEN collection_amount END), 0)                AS collected_today,
                    COALESCE(SUM(CASE WHEN COALESCE(collection_date, DATE(created_at)) = ?
                                       AND agent_id = ? THEN collection_amount END), 0) AS collected_today_by_agent,
                    COALESCE(SUM(CASE WHEN COALESCE(collection_date, DATE(created_at)) >= ?
                                      THEN collection_amount END), 0)                AS collected_this_month,
                    COALESCE(SUM(collection_amount), 0)                              AS collected_total,
                    MAX(COALESCE(collection_date, DATE(created_at)))                 AS last_collection_date
               FROM collections
              WHERE delflag = 0 AND customer_id IN ($ph)
              GROUP BY customer_id"
        );
        // The agent id is what separates "paid" from "paid, but not to this
        // agent" — an admin looking at a book wants to see the difference.
        $stmt->execute(array_merge([$today, $today, $agentId, $month], $ids));
        $rows = self::keyBy($stmt->fetchAll(), 'customer_id');

        // The amount of the most recent receipt, so the screen can show what
        // came in last rather than only when.
        $stmt = $pdo->prepare(
            "SELECT c.customer_id, c.collection_amount, c.agent_name, c.payment_method,
                    COALESCE(c.collection_date, DATE(c.created_at)) AS on_date
               FROM collections c
              WHERE c.delflag = 0 AND c.customer_id IN ($ph)
              ORDER BY COALESCE(c.collection_date, DATE(c.created_at)) ASC, c.created_at ASC"
        );
        $stmt->execute($ids);
        foreach ($stmt->fetchAll() as $r) {          // ascending, so the last write wins
            $cid = $r['customer_id'];
            if (!isset($rows[$cid])) continue;
            $rows[$cid]['last_collection_amount'] = (float)$r['collection_amount'];
            $rows[$cid]['last_collection_by']     = $r['agent_name'];
            $rows[$cid]['last_collection_method'] = $r['payment_method'];
        }
        return $rows;
    }

    /** What the customer still owes on the chit side, from the stored passbook. */
    private static function chitDueByCustomer(PDO $pdo, array $ids, string $today): array
    {
        $ph = self::placeholders($ids);
        $stmt = $pdo->prepare(
            "SELECT customer_id,
                    COUNT(DISTINCT group_id)                                        AS chit_groups,
                    COALESCE(SUM(CASE WHEN due_date <= ? THEN balance END), 0)       AS chit_due_now,
                    SUM(payment_status = 'overdue' OR (is_overdue = 1 AND payment_status <> 'paid')) AS chit_overdue_draws
               FROM chit_passbook
              WHERE delflag = 0 AND payment_status <> 'paid' AND customer_id IN ($ph)
              GROUP BY customer_id"
        );
        $stmt->execute(array_merge([$today], $ids));
        return self::keyBy($stmt->fetchAll(), 'customer_id');
    }

    // ───────────────────────── what each one holds ─────────────────────────

    /**
     * Every loan the customer holds, with its own next due date.
     *
     * The book used to show only a single "outstanding" figure per customer,
     * which is useless the moment someone holds three loans: the admin could
     * see ₹1,43,500 owing but not which loan it sat on, nor which of them was
     * the late one.
     */
    private static function loanList(PDO $pdo, array $ids, string $agentId, string $today): array
    {
        $ph = self::placeholders($ids);
        $stmt = $pdo->prepare(
            "SELECT l.id, l.customer_id, l.loan_number, l.loan_type, l.loan_amount, l.emi,
                    l.total_repayment, l.outstanding_balance, l.penalty_amount, l.status,
                    l.start_date, l.assigned_agent,
                    (SELECT MIN(s.due_date) FROM repayment_schedule s
                      WHERE s.loan_id = l.id AND s.delflag = 0
                        AND s.status <> 'paid' AND s.balance > 0)          AS next_due_date,
                    (SELECT COALESCE(SUM(s.balance), 0) FROM repayment_schedule s
                      WHERE s.loan_id = l.id AND s.delflag = 0
                        AND s.status <> 'paid' AND s.due_date <= ?)        AS due_now
               FROM loans l
              WHERE l.delflag = 0 AND l.customer_id IN ($ph)
              ORDER BY l.status = 'overdue' DESC, l.created_at ASC"
        );
        $stmt->execute(array_merge([$today], $ids));

        $out = [];
        foreach ($stmt->fetchAll() as $r) {
            $out[$r['customer_id']][] = [
                'id'            => $r['id'],
                'loan_number'   => $r['loan_number'],
                'loan_type'     => $r['loan_type'],
                'loan_amount'   => (float)$r['loan_amount'],
                'emi'           => (float)$r['emi'],
                'outstanding'   => (float)$r['outstanding_balance'],
                'penalty'       => (float)$r['penalty_amount'],
                'due_now'       => round((float)$r['due_now'], 2),
                'next_due_date' => $r['next_due_date'],
                'status'        => $r['status'],
                // Whether this particular loan is the agent's, or whether they
                // reach the customer some other way.
                'is_agents'     => $r['assigned_agent'] === $agentId,
            ];
        }
        return $out;
    }

    /** Every chit group the customer is a member of, read from the passbook. */
    private static function chitList(PDO $pdo, array $ids, string $today): array
    {
        $ph = self::placeholders($ids);
        $stmt = $pdo->prepare(
            "SELECT p.customer_id, p.group_id, p.group_number, p.group_name, p.member_id,
                    COUNT(*)                                                   AS total_draws,
                    SUM(p.payment_status = 'paid')                             AS paid_draws,
                    COALESCE(SUM(CASE WHEN p.due_date <= ? AND p.payment_status <> 'paid'
                                      THEN p.balance END), 0)                  AS due_now,
                    COALESCE(SUM(CASE WHEN p.payment_status <> 'paid'
                                      THEN p.balance END), 0)                  AS balance,
                    MIN(CASE WHEN p.payment_status <> 'paid' THEN p.due_date END) AS next_due_date,
                    MAX(p.is_overdue AND p.payment_status <> 'paid')           AS has_overdue,
                    MAX(p.payable_amount)                                      AS contribution
               FROM chit_passbook p
              WHERE p.delflag = 0 AND p.customer_id IN ($ph)
              GROUP BY p.customer_id, p.group_id, p.group_number, p.group_name, p.member_id
              ORDER BY p.group_number ASC"
        );
        $stmt->execute(array_merge([$today], $ids));

        $out = [];
        foreach ($stmt->fetchAll() as $r) {
            $out[$r['customer_id']][] = [
                'group_id'      => $r['group_id'],
                'member_id'     => $r['member_id'],
                'group_number'  => $r['group_number'],
                'group_name'    => $r['group_name'],
                'contribution'  => (float)$r['contribution'],
                'total_draws'   => (int)$r['total_draws'],
                'paid_draws'    => (int)$r['paid_draws'],
                'due_now'       => round((float)$r['due_now'], 2),
                'balance'       => round((float)$r['balance'], 2),
                'next_due_date' => $r['next_due_date'],
                'status'        => (int)$r['has_overdue'] ? 'overdue'
                    : ((int)$r['paid_draws'] >= (int)$r['total_draws'] ? 'paid' : 'pending'),
            ];
        }
        return $out;
    }

    /**
     * Every savings fund the customer holds.
     *
     * Matched on the customer, not on funds.assigned_agent: most funds were
     * created without an agent on them, and filtering by that column would have
     * hidden a customer's savings from the very agent who collects them.
     */
    private static function fundList(PDO $pdo, array $ids, string $agentId): array
    {
        $ph = self::placeholders($ids);
        $stmt = $pdo->prepare(
            "SELECT f.id, f.customer_id, f.fund_number, f.weekly_amount, f.weeks, f.units,
                    f.deposit_amount, f.total_amount, f.collected_amount, f.bonus,
                    f.start_date, f.maturity_date, f.status, f.assigned_agent,
                    (SELECT MAX(COALESCE(fp.payment_date, DATE(fp.created_at)))
                       FROM fund_payments fp
                      WHERE fp.fund_id = f.id AND fp.delflag = 0)      AS last_payment_date,
                    (SELECT COUNT(*) FROM fund_payments fp
                      WHERE fp.fund_id = f.id AND fp.delflag = 0)      AS payments
               FROM funds f
              WHERE f.delflag = 0 AND f.customer_id IN ($ph)
              ORDER BY f.status = 'active' DESC, f.created_at ASC"
        );
        $stmt->execute($ids);

        $out = [];
        foreach ($stmt->fetchAll() as $r) {
            $target = (float)$r['deposit_amount'] ?: (float)$r['weekly_amount'] * (int)$r['weeks'];
            $out[$r['customer_id']][] = [
                'id'                => $r['id'],
                'fund_number'       => $r['fund_number'],
                'weekly_amount'     => (float)$r['weekly_amount'],
                'weeks'             => (int)$r['weeks'],
                'units'             => (float)$r['units'],
                'target_amount'     => round($target, 2),
                'maturity_amount'   => (float)$r['total_amount'],
                'collected_amount'  => (float)$r['collected_amount'],
                // What is left to save into the fund. A matured or closed fund
                // owes nothing regardless of where the arithmetic lands.
                'balance'           => $r['status'] === 'active'
                    ? round(max(0, $target - (float)$r['collected_amount']), 2) : 0.0,
                'payments'          => (int)$r['payments'],
                'last_payment_date' => $r['last_payment_date'],
                'maturity_date'     => $r['maturity_date'],
                'status'            => $r['status'],
                'is_agents'         => $r['assigned_agent'] === $agentId,
            ];
        }
        return $out;
    }
    // ─────────────────────────────── shaping ───────────────────────────────

    private static function describe(array $c, ?array $loan, ?array $due, ?array $paid,
                                     ?array $chit, string $agentId, string $today,
                                     array $loanList = [], array $chitList = [],
                                     array $fundList = []): array
    {
        $outstanding    = (float)($loan['outstanding'] ?? 0);
        $penalty        = (float)($loan['penalty'] ?? 0);
        $overdueAmount  = (float)($due['overdue_amount'] ?? 0);
        $dueNow         = (float)($due['due_now'] ?? 0);
        $chitDue        = (float)($chit['chit_due_now'] ?? 0);
        $collectedToday = (float)($paid['collected_today'] ?? 0);
        $byThisAgent    = (float)($paid['collected_today_by_agent'] ?? 0);

        $oldest = $due['oldest_overdue_date'] ?? null;
        $daysOverdue = $oldest
            ? max(0, (int)floor((strtotime($today) - strtotime($oldest)) / 86400))
            : 0;

        // The order matters: money in today is the answer to "have they paid?",
        // even for someone who is also behind on an older instalment.
        if ($collectedToday > 0)                                    $status = 'collected';
        elseif ($overdueAmount > 0 || ($chit['chit_overdue_draws'] ?? 0) > 0) $status = 'overdue';
        elseif ((int)($due['due_today_count'] ?? 0) > 0 || $chitDue > 0)      $status = 'due_today';
        elseif (!$loan && !$chitList && !$fundList)                 $status = 'no_loan';
        elseif ($outstanding <= 0.01 && $chitDue <= 0.01)           $status = 'settled';
        else                                                        $status = 'upcoming';

        return [
            'id'               => $c['id'],
            'customer_id'      => $c['customer_id'],
            'full_name'        => $c['full_name'],
            'mobile'           => $c['mobile'],
            'address'          => $c['address'],
            'loan_status'      => $c['loan_status'],
            'directly_assigned'=> ($c['assigned_agent'] ?? null) === $agentId,

            'loans'            => (int)($loan['loans'] ?? 0),
            'open_loans'       => (int)($loan['open_loans'] ?? 0),
            'loan_number'      => $loan['loan_number'] ?? null,
            'outstanding'      => round($outstanding, 2),
            'penalty'          => round($penalty, 2),

            'next_due_date'    => $due['next_due_date'] ?? null,
            'due_now'          => round($dueNow, 2),
            'overdue_amount'   => round($overdueAmount, 2),
            'days_overdue'     => $daysOverdue,

            'collected_today'  => round($collectedToday, 2),
            // A receipt taken by someone else still counts as collected, but the
            // admin should be able to see it was not this agent who took it.
            'collected_by_other_agent' => $collectedToday > 0 && $byThisAgent <= 0,
            'collected_this_month'     => round((float)($paid['collected_this_month'] ?? 0), 2),
            'collected_total'          => round((float)($paid['collected_total'] ?? 0), 2),
            'last_collection_date'     => $paid['last_collection_date'] ?? null,
            'last_collection_amount'   => round((float)($paid['last_collection_amount'] ?? 0), 2),
            'last_collection_by'       => $paid['last_collection_by'] ?? null,

            'chit_groups'      => count($chitList),
            'chit_due'         => round($chitDue, 2),
            'chit_balance'     => round(array_sum(array_column($chitList, 'balance')), 2),

            'funds'            => count($fundList),
            'fund_balance'     => round(array_sum(array_column($fundList, 'balance')), 2),
            'fund_saved'       => round(array_sum(array_column($fundList, 'collected_amount')), 2),

            // The itemised holdings behind those totals.
            'loan_list'        => $loanList,
            'chit_list'        => $chitList,
            'fund_list'        => $fundList,

            'status'           => $status,
        ];
    }

    private static function summarize(array $rows, array $orphans = []): array
    {
        $s = self::emptySummary();
        $s['customers'] = count($rows);
        $s['unlinked_loans'] = count($orphans);
        foreach ($rows as $r) {
            $s['open_loans']           += $r['open_loans'];
            $s['outstanding']          += $r['outstanding'];
            $s['penalty']              += $r['penalty'];
            $s['due_today']            += $r['due_now'];
            $s['overdue_amount']       += $r['overdue_amount'];
            $s['collected_today']      += $r['collected_today'];
            $s['collected_this_month'] += $r['collected_this_month'];
            $s['chit_due']             += $r['chit_due'];
            $s['fund_balance']         += $r['fund_balance'];
            $s['loan_count']           += $r['loans'];
            $s['chit_count']           += $r['chit_groups'];
            $s['fund_count']           += $r['funds'];
            if ($r['status'] === 'collected') $s['collected_count']++;
            if ($r['status'] === 'overdue')   $s['overdue_count']++;
            if ($r['status'] === 'due_today') $s['due_today_count']++;
        }
        foreach (['outstanding', 'penalty', 'due_today', 'overdue_amount',
                  'collected_today', 'collected_this_month', 'chit_due', 'fund_balance'] as $k) {
            $s[$k] = round($s[$k], 2);
        }
        // "8 of 12 collected today" needs the denominator to be the people who
        // actually owed something today, not everyone on the books.
        $s['pending_today'] = $s['due_today_count'] + $s['overdue_count'];
        return $s;
    }

    private static function emptySummary(): array
    {
        return [
            'customers' => 0, 'open_loans' => 0, 'outstanding' => 0.0, 'penalty' => 0.0,
            'due_today' => 0.0, 'overdue_amount' => 0.0, 'collected_today' => 0.0,
            'collected_this_month' => 0.0, 'chit_due' => 0.0, 'fund_balance' => 0.0,
            'collected_count' => 0, 'overdue_count' => 0, 'due_today_count' => 0,
            'pending_today' => 0,
            'loan_count' => 0, 'chit_count' => 0, 'fund_count' => 0,
            'unlinked_loans' => 0,
        ];
    }

    // ─────────────────────────────── plumbing ──────────────────────────────

    private static function placeholders(array $ids): string
    {
        return implode(',', array_fill(0, count($ids), '?'));
    }

    private static function keyBy(array $rows, string $key): array
    {
        $out = [];
        foreach ($rows as $r) $out[$r[$key]] = $r;
        return $out;
    }
}
