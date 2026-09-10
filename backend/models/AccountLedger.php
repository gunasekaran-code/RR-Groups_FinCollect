<?php
// ============================================================
//  AccountLedger Model — Executive Account Book & Net Balance
//  Provides real-time financial aggregation across all modules:
//    - Loans (disbursements, active/overdue outstanding balances, collections)
//    - Chits (chit groups, collections, pending balances)
//    - Funds (savings funds, collections, pending balances)
//    - Handovers & Custom Ledger adjustments (capital, expenses, custom lent)
// ============================================================

class AccountLedger extends Model
{
    protected static string $table = 'account_ledger';

    // Entry Types
    public const TYPE_CASH_IN        = 'cash_in';
    public const TYPE_CAPITAL        = 'capital';
    public const TYPE_CASH_OUT       = 'cash_out';
    public const TYPE_EXPENSE        = 'expense';
    public const TYPE_LENT_OUT       = 'lent_out';
    public const TYPE_LENT_ACTIVE    = 'lent_active';
    public const TYPE_LENT_OVERDUE   = 'lent_overdue';
    public const TYPE_LENT_COLLECTED = 'lent_collected';

    public const CASH_TYPES = [
        self::TYPE_CASH_IN,
        self::TYPE_CAPITAL,
        self::TYPE_CASH_OUT,
        self::TYPE_EXPENSE,
    ];

    public const LENT_TYPES = [
        self::TYPE_LENT_OUT,
        self::TYPE_LENT_ACTIVE,
        self::TYPE_LENT_OVERDUE,
        self::TYPE_LENT_COLLECTED,
    ];

    public const ALL_TYPES = [
        self::TYPE_CASH_IN,
        self::TYPE_CAPITAL,
        self::TYPE_CASH_OUT,
        self::TYPE_EXPENSE,
        self::TYPE_LENT_OUT,
        self::TYPE_LENT_ACTIVE,
        self::TYPE_LENT_OVERDUE,
        self::TYPE_LENT_COLLECTED,
    ];

    /**
     * Compute full, live real-time financial position directly from the database.
     * Guaranteed single-source-of-truth for Account Book & Net Balance.
     */
    public static function getRealtimeSummary(): array
    {
        $pdo = Database::pdo();

        // 1. Loan Collections Received
        $stmt = $pdo->prepare("SELECT COALESCE(SUM(collection_amount), 0) FROM collections WHERE delflag = 0");
        $stmt->execute();
        $loanCollections = (float)$stmt->fetchColumn();

        // 2. Fund Deposits Received
        $stmt = $pdo->prepare("SELECT COALESCE(SUM(amount), 0) FROM fund_payments WHERE delflag = 0");
        $stmt->execute();
        $fundDeposits = (float)$stmt->fetchColumn();

        // 3. Cash In / Capital additions from the ledger.
        //    ChitPassbookService::collect() writes a 'cash_in' row for every
        //    chit contribution, so chit money is already inside this figure.
        $stmt = $pdo->prepare("SELECT COALESCE(SUM(amount), 0) FROM account_ledger WHERE delflag = 0 AND entry_type IN ('cash_in', 'capital')");
        $stmt->execute();
        $ledgerCashIn = (float)$stmt->fetchColumn();

        // 4. The chit slice of that, for the breakdown only — never added again.
        //    It used to be summed independently off chit_members, which counted
        //    every contribution twice in Cash In Hand and, because it took the
        //    full contribution_amount for anyone marked 'partial', counted money
        //    that had not arrived. The receipt's own ledger_id is the exact
        //    link; anything unlinked simply reports as other cash in, which
        //    changes the labels but never the total.
        $stmt = $pdo->prepare(
            "SELECT COALESCE(SUM(al.amount), 0)
               FROM account_ledger al
              WHERE al.delflag = 0
                AND al.entry_type IN ('cash_in', 'capital')
                AND EXISTS (SELECT 1 FROM chit_payments cp
                             WHERE cp.ledger_id = al.id AND cp.delflag = 0)"
        );
        $stmt->execute();
        $chitCollected = (float)$stmt->fetchColumn();

        // 5. Custom Cash Out / Expenses from ledger. A settled chit auction
        //    writes its prize here as a cash_out, so the biggest movement in a
        //    chit group needs no special case to leave Cash In Hand.
        $stmt = $pdo->prepare("SELECT COALESCE(SUM(amount), 0) FROM account_ledger WHERE delflag = 0 AND entry_type IN ('cash_out', 'expense')");
        $stmt->execute();
        $customCashOut = (float)$stmt->fetchColumn();

        // 5b. The chit-payout slice of that, for the breakdown only — never
        //     subtracted again. Matched through the auction's own ledger_id
        //     rather than by category text, so a renamed category cannot turn
        //     a payout into an ordinary expense on screen.
        $stmt = $pdo->prepare(
            "SELECT COALESCE(SUM(al.amount), 0)
               FROM account_ledger al
              WHERE al.delflag = 0
                AND al.entry_type IN ('cash_out', 'expense')
                AND EXISTS (SELECT 1 FROM chit_auctions ca
                             WHERE ca.ledger_id = al.id AND ca.delflag = 0)"
        );
        $stmt->execute();
        $chitPayouts = (float)$stmt->fetchColumn();

        // 6. Loan principal handed to customers — cash that physically left.
        //    'pending' is excluded: a loan awaiting approval has not been paid
        //    out. This is the money-out side of `collections`, which is already
        //    counted coming back in, so a closed loan nets out to its interest.
        //
        //    The loan amount is not the amount handed over. On the weekly plan
        //    and the 100-day daily plan the interest is deducted at
        //    disbursement: a ₹10,000 weekly loan puts ₹9,000 in the borrower's
        //    hand and the ₹1,000 never leaves the safe. Taking the full
        //    ₹10,000 off Cash In Hand understated it by the interest on every
        //    such loan.
        //
        //    Which plan a loan is on cannot be read off `loan_type` alone —
        //    the daily plans differ from each other and the choice between
        //    them is not stored — but the totals say it plainly. Interest
        //    added on top repays principal + interest; interest taken upfront
        //    repays the principal alone. So the amount that left is always
        //    `total_repayment − total_interest`, which is the principal on the
        //    plans that add and the principal less the interest on the plans
        //    that deduct. Loans written before those totals were stored fall
        //    back to the loan amount, which is what they were.
        $stmt = $pdo->prepare(
            "SELECT COALESCE(SUM(
                        CASE WHEN COALESCE(total_repayment, 0) > 0
                             THEN GREATEST(COALESCE(total_repayment, 0) - COALESCE(total_interest, 0), 0)
                             ELSE COALESCE(loan_amount, 0)
                        END), 0)
               FROM loans
              WHERE delflag = 0 AND status IN ('active', 'overdue', 'closed')"
        );
        $stmt->execute();
        $loansDisbursed = (float)$stmt->fetchColumn();

        // The slice of principal that was never handed over — the upfront
        // interest sitting in the safe. Reported so the Cash In Hand card can
        // say why it did not fall by the whole loan; it is not added to
        // anything, because not subtracting it is what keeps it there.
        $stmt = $pdo->prepare(
            "SELECT COALESCE(SUM(
                        CASE WHEN COALESCE(total_repayment, 0) > 0
                             THEN GREATEST(COALESCE(loan_amount, 0)
                                           - GREATEST(COALESCE(total_repayment, 0) - COALESCE(total_interest, 0), 0), 0)
                             ELSE 0
                        END), 0)
               FROM loans
              WHERE delflag = 0 AND status IN ('active', 'overdue', 'closed')"
        );
        $stmt->execute();
        $upfrontInterestHeld = (float)$stmt->fetchColumn();

        // 7. Market lending recorded by hand. Only 'lent_out' is money leaving
        //    the safe — 'lent_active' and 'lent_overdue' are reclassifications
        //    of debt that already exists, and moving them would take the cash
        //    out a second time.
        $stmt = $pdo->prepare("SELECT COALESCE(SUM(amount), 0) FROM account_ledger WHERE delflag = 0 AND entry_type = 'lent_out'");
        $stmt->execute();
        $customLentDisbursed = (float)$stmt->fetchColumn();

        $stmt = $pdo->prepare("SELECT COALESCE(SUM(amount), 0) FROM account_ledger WHERE delflag = 0 AND entry_type = 'lent_collected'");
        $stmt->execute();
        $customLentCollected = (float)$stmt->fetchColumn();

        // Cash In Hand (கையிருப்பு) — what is actually in the safe.
        //
        // Every rupee handed to a customer has to come off this. It previously
        // only ever added: lending ₹10,000 out of ₹20,000 capital still showed
        // ₹20,000 in hand and ₹33,000 net, counting the same money as both cash
        // and receivable.
        //
        // The figure is deliberately allowed to go negative. Clamping it at
        // zero reported "you have nothing" when the truth was "you have paid
        // out more than you have recorded taking in" — which is the one thing
        // this number exists to reveal.
        $cashInHand = $loanCollections + $fundDeposits + $ledgerCashIn + $customLentCollected
                    - $customCashOut - $loansDisbursed - $customLentDisbursed;

        // Kept under its old name for the screens that read it: ledger cash in
        // with the chit receipts shown on their own line.
        $customCashIn = $ledgerCashIn;
        $otherCashIn  = $ledgerCashIn - $chitCollected;
        $otherCashOut = $customCashOut - $chitPayouts;

        // 6. Active Loans Outstanding
        $stmt = $pdo->prepare("SELECT COUNT(*) as count, COALESCE(SUM(outstanding_balance), 0) as outstanding FROM loans WHERE delflag = 0 AND status = 'active'");
        $stmt->execute();
        $activeLoansRow = $stmt->fetch(PDO::FETCH_ASSOC) ?: ['count' => 0, 'outstanding' => 0];
        $activeLoansCount = (int)($activeLoansRow['count'] ?? 0);
        $activeLoanOutstanding = (float)($activeLoansRow['outstanding'] ?? 0);

        // 7. Overdue Loans Outstanding
        $stmt = $pdo->prepare("SELECT COUNT(*) as count, COALESCE(SUM(outstanding_balance), 0) as outstanding FROM loans WHERE delflag = 0 AND status = 'overdue'");
        $stmt->execute();
        $overdueLoansRow = $stmt->fetch(PDO::FETCH_ASSOC) ?: ['count' => 0, 'outstanding' => 0];
        $overdueLoansCount = (int)($overdueLoansRow['count'] ?? 0);
        $overdueLoanOutstanding = (float)($overdueLoansRow['outstanding'] ?? 0);

        $totalLoanOutstanding = $activeLoanOutstanding + $overdueLoanOutstanding;

        // Total Loans Principal Disbursed — the same figure already taken off
        // Cash In Hand above.
        $totalLoansGiven = $loansDisbursed;

        // 8. Chit Groups (Active)
        $stmt = $pdo->prepare("SELECT COUNT(*) as count, COALESCE(SUM(group_value), 0) as group_val, COALESCE(SUM(collected_amount), 0) as coll, COALESCE(SUM(pending_amount), 0) as pend FROM chit_groups WHERE delflag = 0 AND status = 'active'");
        $stmt->execute();
        $chitRow = $stmt->fetch(PDO::FETCH_ASSOC) ?: ['count' => 0, 'group_val' => 0, 'coll' => 0, 'pend' => 0];
        $activeChitsCount = (int)($chitRow['count'] ?? 0);
        $chitGroupValue = (float)($chitRow['group_val'] ?? 0);
        $chitCollectedAmount = (float)($chitRow['coll'] ?? 0);
        $chitPendingAmount = (float)($chitRow['pend'] ?? 0);

        // 9. Savings Funds (Active)
        $stmt = $pdo->prepare("SELECT COUNT(*) as count, COALESCE(SUM(IFNULL(deposit_amount, total_amount)), 0) as total_dep, COALESCE(SUM(collected_amount), 0) as coll FROM funds WHERE delflag = 0 AND status = 'active'");
        $stmt->execute();
        $fundRow = $stmt->fetch(PDO::FETCH_ASSOC) ?: ['count' => 0, 'total_dep' => 0, 'coll' => 0];
        $activeFundsCount = (int)($fundRow['count'] ?? 0);
        $fundTotalDeposit = (float)($fundRow['total_dep'] ?? 0);
        $fundCollectedAmount = (float)($fundRow['coll'] ?? 0);
        $fundPendingAmount = max(0, $fundTotalDeposit - $fundCollectedAmount);

        // 10. Custom Lent Out & Recovered
        $stmt = $pdo->prepare("SELECT COALESCE(SUM(amount), 0) FROM account_ledger WHERE delflag = 0 AND entry_type IN ('lent_out', 'lent_active', 'lent_overdue')");
        $stmt->execute();
        $customLentOut = (float)$stmt->fetchColumn();

        $customLentNet = max(0, $customLentOut - $customLentCollected);

        // Total Outstanding Money Lent (வெளி கடன்) — only debt the business is
        // actually exposed on: a loan's principal already left the safe, a
        // fund's deposit target is a maturity payout the business must
        // eventually honor, and a custom entry is cash handed over by hand.
        //
        // Chit pending is deliberately left out. `chit_groups.pending_amount`
        // is contributions the group's own members have not yet paid in —
        // money the business is waiting to collect, not money it disbursed —
        // so it is reported on its own (chitPendingAmount) but never summed
        // into "money lent".
        $outstandingMoneyLent = $totalLoanOutstanding + $fundPendingAmount + $customLentNet;

        // Net Balance (மொத்த இருப்பு) — the money the business actually holds.
        //
        // It used to be cash + everything owed to us, which counted a loan's
        // repayment as an asset the day it was written: ₹20,000 of capital lent
        // out at interest read as ₹33,000 before a rupee had been collected.
        // Money owed is already its own card; adding it here made the headline
        // figure rise every time money went *out* of the door.
        //
        // Net Balance is now the cash position, and only turns into profit as
        // the loan is actually repaid.
        $netBalance = $cashInHand;

        return [
            // Cash In Hand
            'loanCollections'        => $loanCollections,
            'fundDeposits'           => $fundDeposits,
            'chitCollected'          => $chitCollected,
            'customCashIn'           => $customCashIn,
            'otherCashIn'            => $otherCashIn,
            'customCashOut'          => $customCashOut,
            'otherCashOut'           => $otherCashOut,
            'chitPayouts'            => $chitPayouts,
            'loansDisbursed'         => $loansDisbursed,
            'upfrontInterestHeld'    => $upfrontInterestHeld,
            'customLentDisbursed'    => $customLentDisbursed,
            'cashInHand'             => $cashInHand,

            // Loans
            'activeLoansCount'       => $activeLoansCount,
            'activeLoanOutstanding'  => $activeLoanOutstanding,
            'overdueLoansCount'      => $overdueLoansCount,
            'overdueLoanOutstanding' => $overdueLoanOutstanding,
            'totalLoanOutstanding'   => $totalLoanOutstanding,
            'totalLoansGiven'        => $totalLoansGiven,

            // Chits
            'activeChitsCount'       => $activeChitsCount,
            'chitGroupValue'         => $chitGroupValue,
            'chitCollectedAmount'    => $chitCollectedAmount,
            'chitPendingAmount'      => $chitPendingAmount,

            // Funds
            'activeFundsCount'       => $activeFundsCount,
            'fundTotalDeposit'       => $fundTotalDeposit,
            'fundCollectedAmount'    => $fundCollectedAmount,
            'fundPendingAmount'      => $fundPendingAmount,

            // Custom Lent
            'customLentOut'          => $customLentOut,
            'customLentCollected'    => $customLentCollected,
            'customLentNet'          => $customLentNet,

            // Totals
            'outstandingMoneyLent'   => $outstandingMoneyLent,
            'netBalance'             => $netBalance,
        ];
    }

    /**
     * Fetch a unified, chronologically ordered transaction stream across all financial operations.
     */
    public static function getUnifiedTransactions(int $limit = 500, int $offset = 0, ?string $filterType = null): array
    {
        $pdo = Database::pdo();
        $queries = [];

        // 1. Account Ledger Entries.
        //    A chit contribution lives here too, so the module has to come from
        //    the category — hardcoding 'ledger' filed every chit receipt under
        //    Custom/Expenses and left the Chit Groups filter empty.
        $queries[] = "
            SELECT 
                id,
                entry_date as txn_date,
                entry_date,
                title,
                CASE
                    WHEN LOWER(category) LIKE '%chit%' THEN 'chit'
                    WHEN LOWER(category) LIKE '%fund%' THEN 'fund'
                    WHEN LOWER(category) LIKE '%loan%' THEN 'loan'
                    ELSE 'ledger'
                END as module,
                category,
                entry_type as txn_type,
                entry_type,
                amount,
                notes,
                agent_name as collector,
                1 as is_custom,
                created_at
            FROM account_ledger
            WHERE delflag = 0
        ";

        // 2. Loan Collections
        $queries[] = "
            SELECT 
                id,
                DATE(COALESCE(collection_date, created_at)) as txn_date,
                DATE(COALESCE(collection_date, created_at)) as entry_date,
                CONCAT('Loan Collection: ', IFNULL(customer_name, 'Customer'), ' (', IFNULL(loan_number, ''), ')') as title,
                'loan' as module,
                'Loan Collection' as category,
                'cash_in' as txn_type,
                'cash_in' as entry_type,
                collection_amount as amount,
                CONCAT('Receipt: ', IFNULL(receipt_number, 'N/A'), ' | Method: ', UPPER(IFNULL(payment_method, 'CASH')), ' | Collector: ', IFNULL(agent_name, 'Direct')) as notes,
                agent_name as collector,
                0 as is_custom,
                created_at
            FROM collections
            WHERE delflag = 0
        ";

        // 3. Fund Payments / Deposits
        $queries[] = "
            SELECT 
                id,
                DATE(COALESCE(payment_date, created_at)) as txn_date,
                DATE(COALESCE(payment_date, created_at)) as entry_date,
                CONCAT('Fund Deposit: ', IFNULL(customer_name, 'Customer'), ' (', IFNULL(fund_number, ''), ' - W', IFNULL(week_no, 1), ')') as title,
                'fund' as module,
                'Fund Deposit' as category,
                'cash_in' as txn_type,
                'cash_in' as entry_type,
                amount,
                CONCAT('Method: ', UPPER(IFNULL(payment_method, 'CASH')), ' | Collector: ', IFNULL(agent_name, 'Direct')) as notes,
                agent_name as collector,
                0 as is_custom,
                created_at
            FROM fund_payments
            WHERE delflag = 0
        ";

        // Combine
        $unionSql = implode(" UNION ALL ", $queries);
        $sql = "SELECT * FROM ($unionSql) as combined_stream ";

        $params = [];
        if ($filterType === 'cash') {
            $sql .= " WHERE txn_type IN ('cash_in', 'capital', 'cash_out', 'expense')";
        } elseif ($filterType === 'lent') {
            $sql .= " WHERE txn_type IN ('lent_out', 'lent_active', 'lent_overdue', 'lent_collected')";
        }

        $sql .= " ORDER BY txn_date DESC, created_at DESC LIMIT " . (int)$limit . " OFFSET " . (int)$offset;

        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

        return array_map(function ($row) {
            $row['amount'] = (float)$row['amount'];
            $row['is_custom'] = (bool)($row['is_custom'] ?? 0);
            return $row;
        }, $rows);
    }

    /**
     * Fetch all outstanding debtors / balances across Loans, Chit Groups, Funds, and Custom Money Lent.
     */
    public static function getOutstandingDebtors(): array
    {
        $pdo = Database::pdo();
        $outstanding = [];

        // 1. Outstanding Loans
        $loans = $pdo->query("
            SELECT 
                id,
                loan_number as ref_number,
                customer_name as debtor_name,
                'loan' as module,
                'Loan Outstanding' as category,
                loan_amount as total_disbursed,
                total_repayment,
                (total_repayment - outstanding_balance) as amount_paid,
                outstanding_balance,
                start_date,
                status,
                agent_name as collector_name,
                created_at
            FROM loans
            WHERE delflag = 0 AND outstanding_balance > 0 AND status IN ('active', 'overdue')
            ORDER BY outstanding_balance DESC
        ")->fetchAll(PDO::FETCH_ASSOC);

        foreach ($loans as $l) {
            $outstanding[] = [
                'id' => $l['id'],
                'title' => ($l['debtor_name'] ?? 'Customer') . ' (' . $l['ref_number'] . ')',
                'debtor_name' => $l['debtor_name'] ?? 'Unknown Customer',
                'ref_number' => $l['ref_number'],
                'module' => 'loan',
                'category' => 'Loan Outstanding',
                'section' => 'lent',
                'entry_type' => $l['status'] === 'overdue' ? 'lent_overdue' : 'lent_active',
                'total_amount' => (float)$l['total_repayment'],
                'paid_amount' => (float)$l['amount_paid'],
                'amount' => (float)$l['outstanding_balance'],
                'status' => $l['status'],
                'collector' => $l['collector_name'] ?? 'Direct',
                'entry_date' => $l['start_date'] ?? substr($l['created_at'], 0, 10),
                'notes' => 'Loan Repayment: ' . $l['total_repayment'] . ' | Paid: ' . $l['amount_paid'] . ' | Balance: ' . $l['outstanding_balance'],
                'is_custom' => false
            ];
        }

        // 2. Chit Pending Groups
        $chits = $pdo->query("
            SELECT 
                g.id,
                g.group_number as ref_number,
                g.group_name as debtor_name,
                'chit' as module,
                'Chit Pending' as category,
                g.group_value as total_given,
                g.collected_amount as amount_paid,
                g.pending_amount as outstanding_amount,
                g.start_date,
                g.status,
                'Office' as collector_name,
                g.created_at
            FROM chit_groups g
            WHERE g.delflag = 0 AND g.pending_amount > 0 AND g.status = 'active'
            ORDER BY g.pending_amount DESC
        ")->fetchAll(PDO::FETCH_ASSOC);

        foreach ($chits as $c) {
            $outstanding[] = [
                'id' => $c['id'],
                'title' => 'Chit Group: ' . $c['debtor_name'] . ' (' . $c['ref_number'] . ')',
                'debtor_name' => $c['debtor_name'],
                'ref_number' => $c['ref_number'],
                'module' => 'chit',
                'category' => 'Chit Pending',
                'section' => 'lent',
                'entry_type' => 'lent_active',
                'total_amount' => (float)$c['total_given'],
                'paid_amount' => (float)$c['amount_paid'],
                'amount' => (float)$c['outstanding_amount'],
                'status' => $c['status'],
                'collector' => 'Office',
                'entry_date' => $c['start_date'] ?? substr($c['created_at'], 0, 10),
                'notes' => 'Total Value: ' . $c['total_given'] . ' | Collected: ' . $c['amount_paid'] . ' | Pending: ' . $c['outstanding_amount'],
                'is_custom' => false
            ];
        }

        // 3. Funds Pending
        $funds = $pdo->query("
            SELECT 
                f.id,
                f.fund_number as ref_number,
                f.customer_name as debtor_name,
                'fund' as module,
                'Fund Remaining' as category,
                f.deposit_amount as total_given,
                f.collected_amount as amount_paid,
                (f.deposit_amount - f.collected_amount) as outstanding_amount,
                f.start_date,
                f.status,
                f.agent_name as collector_name,
                f.created_at
            FROM funds f
            WHERE f.delflag = 0 AND f.status = 'active' AND (f.deposit_amount - f.collected_amount) > 0
            ORDER BY (f.deposit_amount - f.collected_amount) DESC
        ")->fetchAll(PDO::FETCH_ASSOC);

        foreach ($funds as $f) {
            $outstanding[] = [
                'id' => $f['id'],
                'title' => 'Fund Pending: ' . ($f['debtor_name'] ?? 'Customer') . ' (' . $f['ref_number'] . ')',
                'debtor_name' => $f['debtor_name'] ?? 'Customer',
                'ref_number' => $f['ref_number'],
                'module' => 'fund',
                'category' => 'Fund Remaining',
                'section' => 'lent',
                'entry_type' => 'lent_active',
                'total_amount' => (float)$f['total_given'],
                'paid_amount' => (float)$f['amount_paid'],
                'amount' => (float)$f['outstanding_amount'],
                'status' => $f['status'],
                'collector' => $f['collector_name'] ?? 'Direct',
                'entry_date' => $f['start_date'] ?? substr($f['created_at'], 0, 10),
                'notes' => 'Target: ' . $f['total_given'] . ' | Deposited: ' . $f['amount_paid'] . ' | Remaining: ' . $f['outstanding_amount'],
                'is_custom' => false
            ];
        }

        // 4. Custom Money Lent in account_ledger
        $customLent = $pdo->query("
            SELECT 
                id,
                'CUSTOM' as ref_number,
                title as debtor_name,
                'ledger' as module,
                category,
                amount as total_given,
                0 as amount_paid,
                amount as outstanding_amount,
                entry_date as start_date,
                entry_type as status,
                'Admin' as collector_name,
                notes,
                created_at
            FROM account_ledger
            WHERE delflag = 0 AND entry_type IN ('lent_out', 'lent_active', 'lent_overdue')
            ORDER BY entry_date DESC
        ")->fetchAll(PDO::FETCH_ASSOC);

        foreach ($customLent as $cl) {
            $outstanding[] = [
                'id' => $cl['id'],
                'title' => $cl['debtor_name'],
                'debtor_name' => $cl['debtor_name'],
                'ref_number' => $cl['ref_number'],
                'module' => 'ledger',
                'category' => $cl['category'] ?? 'Money Lent',
                'section' => 'lent',
                'entry_type' => $cl['status'],
                'total_amount' => (float)$cl['total_given'],
                'paid_amount' => 0.0,
                'amount' => (float)$cl['outstanding_amount'],
                'status' => $cl['status'],
                'collector' => 'Admin',
                'entry_date' => $cl['start_date'] ?? substr($cl['created_at'], 0, 10),
                'notes' => $cl['notes'] ?? 'Custom money lent entry',
                'is_custom' => true
            ];
        }

        return $outstanding;
    }

    /**
     * Validate an account ledger entry payload before saving.
     */
    public static function validateEntry(array $data): array
    {
        $errors = [];

        $title = trim($data['title'] ?? '');
        if ($title === '') {
            $errors[] = 'Title is required';
        }

        $amount = (float)($data['amount'] ?? 0);
        if ($amount <= 0) {
            $errors[] = 'Amount must be greater than zero';
        }

        $entryType = trim($data['entry_type'] ?? '');
        if ($entryType === '' || !in_array($entryType, self::ALL_TYPES, true)) {
            $errors[] = 'Valid entry type is required';
        }

        return $errors;
    }
}
