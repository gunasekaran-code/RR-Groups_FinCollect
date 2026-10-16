/// Models for the "agent portfolio" endpoint.
///
/// These mirror, field for field, what `AgentPortfolio::forAgent()` returns
/// on the PHP side (see `AgentPortfolio::describe()` and `::summarize()`),
/// and what `AgentPortfolio::attachLoan()` returns for the relink action.
///
/// Kept intentionally defensive about JSON shapes: PHP's `json_encode` can
/// hand back numeric strings, nulls, or `0`/`1` for booleans depending on how
/// a column was typed, so every field is parsed through the `_as*` helpers
/// below rather than cast directly.
library agent_portfolio_model;

double _asDouble(dynamic v) {
  if (v == null) return 0.0;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toInt();
  if (v is String) {
    return int.tryParse(v) ?? (double.tryParse(v)?.toInt() ?? 0);
  }
  return 0;
}

bool _asBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == '1' || v.toLowerCase() == 'true';
  return false;
}

String _asString(dynamic v, {String fallback = ''}) =>
    v == null ? fallback : v.toString();

String? _asStringOrNull(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

List<T> _asList<T>(dynamic v, T Function(Map<String, dynamic>) fromJson) {
  if (v is! List) return <T>[];
  return v
      .whereType<Map>()
      .map((e) => fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

// ---------------------------------------------------------------------------
// profiles row for the agent themselves
// ---------------------------------------------------------------------------
class AgentInfo {
  final String id;
  final String fullName;
  final String? email;
  final String? mobile;
  final String? role;
  final String? status;
  final String? userCode;
  final String? avatarUrl;
  final String? createdAt;

  AgentInfo({
    required this.id,
    required this.fullName,
    this.email,
    this.mobile,
    this.role,
    this.status,
    this.userCode,
    this.avatarUrl,
    this.createdAt,
  });

  factory AgentInfo.fromJson(Map<String, dynamic> j) => AgentInfo(
        id: _asString(j['id']),
        fullName: _asString(j['full_name']),
        email: _asStringOrNull(j['email']),
        mobile: _asStringOrNull(j['mobile']),
        role: _asStringOrNull(j['role']),
        status: _asStringOrNull(j['status']),
        userCode: _asStringOrNull(j['user_code']),
        avatarUrl: _asStringOrNull(j['avatar_url']),
        createdAt: _asStringOrNull(j['created_at']),
      );
}

// ---------------------------------------------------------------------------
// one loan held by a customer (AgentPortfolio::loanList)
// ---------------------------------------------------------------------------
class LoanItem {
  final String id;
  final String loanNumber;
  final String? loanType;
  final double loanAmount;
  final double emi;
  final double outstanding;
  final double penalty;
  final double dueNow;
  final String? nextDueDate;
  final String status; // active | overdue | closed
  final bool isAgents;

  LoanItem({
    required this.id,
    required this.loanNumber,
    this.loanType,
    required this.loanAmount,
    required this.emi,
    required this.outstanding,
    required this.penalty,
    required this.dueNow,
    this.nextDueDate,
    required this.status,
    required this.isAgents,
  });

  factory LoanItem.fromJson(Map<String, dynamic> j) => LoanItem(
        id: _asString(j['id']),
        loanNumber: _asString(j['loan_number']),
        loanType: _asStringOrNull(j['loan_type']),
        loanAmount: _asDouble(j['loan_amount']),
        emi: _asDouble(j['emi']),
        outstanding: _asDouble(j['outstanding']),
        penalty: _asDouble(j['penalty']),
        dueNow: _asDouble(j['due_now']),
        nextDueDate: _asStringOrNull(j['next_due_date']),
        status: _asString(j['status'], fallback: 'active'),
        isAgents: _asBool(j['is_agents']),
      );
}

// ---------------------------------------------------------------------------
// one chit group membership (AgentPortfolio::chitList)
// ---------------------------------------------------------------------------
class ChitItem {
  final String groupId;
  final String memberId;
  final String groupNumber;
  final String groupName;
  final double contribution; // per-draw payable amount
  final int totalDraws;
  final int paidDraws;
  final double dueNow;
  final double balance;
  final String? nextDueDate;
  final String status; // overdue | paid | pending

  ChitItem({
    required this.groupId,
    required this.memberId,
    required this.groupNumber,
    required this.groupName,
    required this.contribution,
    required this.totalDraws,
    required this.paidDraws,
    required this.dueNow,
    required this.balance,
    this.nextDueDate,
    required this.status,
  });

  factory ChitItem.fromJson(Map<String, dynamic> j) => ChitItem(
        groupId: _asString(j['group_id']),
        memberId: _asString(j['member_id']),
        groupNumber: _asString(j['group_number']),
        groupName: _asString(j['group_name']),
        contribution: _asDouble(j['contribution']),
        totalDraws: _asInt(j['total_draws']),
        paidDraws: _asInt(j['paid_draws']),
        dueNow: _asDouble(j['due_now']),
        balance: _asDouble(j['balance']),
        nextDueDate: _asStringOrNull(j['next_due_date']),
        status: _asString(j['status'], fallback: 'pending'),
      );
}

// ---------------------------------------------------------------------------
// one savings fund (AgentPortfolio::fundList)
// ---------------------------------------------------------------------------
class FundItem {
  final String id;
  final String fundNumber;
  final double weeklyAmount;
  final int weeks;
  final double units;
  final double targetAmount;
  final double maturityAmount;
  final double collectedAmount;
  final double balance; // what's left to save
  final int payments;
  final String? lastPaymentDate;
  final String? maturityDate;
  final String status; // active | matured | closed
  final bool isAgents;

  FundItem({
    required this.id,
    required this.fundNumber,
    required this.weeklyAmount,
    required this.weeks,
    required this.units,
    required this.targetAmount,
    required this.maturityAmount,
    required this.collectedAmount,
    required this.balance,
    required this.payments,
    this.lastPaymentDate,
    this.maturityDate,
    required this.status,
    required this.isAgents,
  });

  factory FundItem.fromJson(Map<String, dynamic> j) => FundItem(
        id: _asString(j['id']),
        fundNumber: _asString(j['fund_number']),
        weeklyAmount: _asDouble(j['weekly_amount']),
        weeks: _asInt(j['weeks']),
        units: _asDouble(j['units']),
        targetAmount: _asDouble(j['target_amount']),
        maturityAmount: _asDouble(j['maturity_amount']),
        collectedAmount: _asDouble(j['collected_amount']),
        balance: _asDouble(j['balance']),
        payments: _asInt(j['payments']),
        lastPaymentDate: _asStringOrNull(j['last_payment_date']),
        maturityDate: _asStringOrNull(j['maturity_date']),
        status: _asString(j['status'], fallback: 'active'),
        isAgents: _asBool(j['is_agents']),
      );
}

// ---------------------------------------------------------------------------
// a loan pointing at no live customer (AgentPortfolio::unlinkedLoans)
// ---------------------------------------------------------------------------
class UnlinkedLoan {
  final String id;
  final String loanNumber;
  final String customerName;
  final double emi;
  final double outstanding;
  final double penalty;
  final double dueNow;
  final String? nextDueDate;
  final String status;

  UnlinkedLoan({
    required this.id,
    required this.loanNumber,
    required this.customerName,
    required this.emi,
    required this.outstanding,
    required this.penalty,
    required this.dueNow,
    this.nextDueDate,
    required this.status,
  });

  factory UnlinkedLoan.fromJson(Map<String, dynamic> j) => UnlinkedLoan(
        id: _asString(j['id']),
        loanNumber: _asString(j['loan_number']),
        customerName: _asString(j['customer_name']),
        emi: _asDouble(j['emi']),
        outstanding: _asDouble(j['outstanding']),
        penalty: _asDouble(j['penalty']),
        dueNow: _asDouble(j['due_now']),
        nextDueDate: _asStringOrNull(j['next_due_date']),
        status: _asString(j['status'], fallback: 'active'),
      );
}

// ---------------------------------------------------------------------------
// one row of the book — a customer, and where they stand
// (AgentPortfolio::describe)
// ---------------------------------------------------------------------------
class AgentCustomer {
  final String id; // customers.id (uuid/pk)
  final String customerId; // customers.customer_id (display code, e.g. RRG-CUS-0001)
  final String fullName;
  final String mobile;
  final String address;
  final String? loanStatus;
  final bool directlyAssigned;

  final int loans;
  final int openLoans;
  final String? loanNumber;
  final double outstanding;
  final double penalty;

  final String? nextDueDate;
  final double dueNow;
  final double overdueAmount;
  final int daysOverdue;

  final double collectedToday;
  final bool collectedByOtherAgent;
  final double collectedThisMonth;
  final double collectedTotal;
  final String? lastCollectionDate;
  final double lastCollectionAmount;
  final String? lastCollectionBy;

  final int chitGroups;
  final double chitDue;
  final double chitBalance;

  final int funds;
  final double fundBalance;
  final double fundSaved;

  final List<LoanItem> loanList;
  final List<ChitItem> chitList;
  final List<FundItem> fundList;

  /// overdue | due_today | upcoming | collected | settled | no_loan
  final String status;

  AgentCustomer({
    required this.id,
    required this.customerId,
    required this.fullName,
    required this.mobile,
    required this.address,
    this.loanStatus,
    required this.directlyAssigned,
    required this.loans,
    required this.openLoans,
    this.loanNumber,
    required this.outstanding,
    required this.penalty,
    this.nextDueDate,
    required this.dueNow,
    required this.overdueAmount,
    required this.daysOverdue,
    required this.collectedToday,
    required this.collectedByOtherAgent,
    required this.collectedThisMonth,
    required this.collectedTotal,
    this.lastCollectionDate,
    required this.lastCollectionAmount,
    this.lastCollectionBy,
    required this.chitGroups,
    required this.chitDue,
    required this.chitBalance,
    required this.funds,
    required this.fundBalance,
    required this.fundSaved,
    required this.loanList,
    required this.chitList,
    required this.fundList,
    required this.status,
  });

  factory AgentCustomer.fromJson(Map<String, dynamic> j) => AgentCustomer(
        id: _asString(j['id']),
        customerId: _asString(j['customer_id']),
        fullName: _asString(j['full_name']),
        mobile: _asString(j['mobile']),
        address: _asString(j['address']),
        loanStatus: _asStringOrNull(j['loan_status']),
        directlyAssigned: _asBool(j['directly_assigned']),
        loans: _asInt(j['loans']),
        openLoans: _asInt(j['open_loans']),
        loanNumber: _asStringOrNull(j['loan_number']),
        outstanding: _asDouble(j['outstanding']),
        penalty: _asDouble(j['penalty']),
        nextDueDate: _asStringOrNull(j['next_due_date']),
        dueNow: _asDouble(j['due_now']),
        overdueAmount: _asDouble(j['overdue_amount']),
        daysOverdue: _asInt(j['days_overdue']),
        collectedToday: _asDouble(j['collected_today']),
        collectedByOtherAgent: _asBool(j['collected_by_other_agent']),
        collectedThisMonth: _asDouble(j['collected_this_month']),
        collectedTotal: _asDouble(j['collected_total']),
        lastCollectionDate: _asStringOrNull(j['last_collection_date']),
        lastCollectionAmount: _asDouble(j['last_collection_amount']),
        lastCollectionBy: _asStringOrNull(j['last_collection_by']),
        chitGroups: _asInt(j['chit_groups']),
        chitDue: _asDouble(j['chit_due']),
        chitBalance: _asDouble(j['chit_balance']),
        funds: _asInt(j['funds']),
        fundBalance: _asDouble(j['fund_balance']),
        fundSaved: _asDouble(j['fund_saved']),
        loanList: _asList(j['loan_list'], LoanItem.fromJson),
        chitList: _asList(j['chit_list'], ChitItem.fromJson),
        fundList: _asList(j['fund_list'], FundItem.fromJson),
        status: _asString(j['status'], fallback: 'upcoming'),
      );
}

// ---------------------------------------------------------------------------
// summary totals (AgentPortfolio::summarize / ::emptySummary)
// ---------------------------------------------------------------------------
class AgentPortfolioSummary {
  final int customers;
  final int openLoans;
  final double outstanding;
  final double penalty;
  final double dueToday;
  final double overdueAmount;
  final double collectedToday;
  final double collectedThisMonth;
  final double chitDue;
  final double fundBalance;
  final int collectedCount;
  final int overdueCount;
  final int dueTodayCount;
  final int pendingToday;
  final int loanCount;
  final int chitCount;
  final int fundCount;
  final int unlinkedLoans;

  AgentPortfolioSummary({
    required this.customers,
    required this.openLoans,
    required this.outstanding,
    required this.penalty,
    required this.dueToday,
    required this.overdueAmount,
    required this.collectedToday,
    required this.collectedThisMonth,
    required this.chitDue,
    required this.fundBalance,
    required this.collectedCount,
    required this.overdueCount,
    required this.dueTodayCount,
    required this.pendingToday,
    required this.loanCount,
    required this.chitCount,
    required this.fundCount,
    required this.unlinkedLoans,
  });

  factory AgentPortfolioSummary.empty() => AgentPortfolioSummary(
        customers: 0,
        openLoans: 0,
        outstanding: 0,
        penalty: 0,
        dueToday: 0,
        overdueAmount: 0,
        collectedToday: 0,
        collectedThisMonth: 0,
        chitDue: 0,
        fundBalance: 0,
        collectedCount: 0,
        overdueCount: 0,
        dueTodayCount: 0,
        pendingToday: 0,
        loanCount: 0,
        chitCount: 0,
        fundCount: 0,
        unlinkedLoans: 0,
      );

  factory AgentPortfolioSummary.fromJson(Map<String, dynamic> j) =>
      AgentPortfolioSummary(
        customers: _asInt(j['customers']),
        openLoans: _asInt(j['open_loans']),
        outstanding: _asDouble(j['outstanding']),
        penalty: _asDouble(j['penalty']),
        dueToday: _asDouble(j['due_today']),
        overdueAmount: _asDouble(j['overdue_amount']),
        collectedToday: _asDouble(j['collected_today']),
        collectedThisMonth: _asDouble(j['collected_this_month']),
        chitDue: _asDouble(j['chit_due']),
        fundBalance: _asDouble(j['fund_balance']),
        collectedCount: _asInt(j['collected_count']),
        overdueCount: _asInt(j['overdue_count']),
        dueTodayCount: _asInt(j['due_today_count']),
        pendingToday: _asInt(j['pending_today']),
        loanCount: _asInt(j['loan_count']),
        chitCount: _asInt(j['chit_count']),
        fundCount: _asInt(j['fund_count']),
        unlinkedLoans: _asInt(j['unlinked_loans']),
      );
}

// ---------------------------------------------------------------------------
// the whole GET ?action=portfolio response
// ---------------------------------------------------------------------------
class AgentPortfolioResponse {
  final AgentInfo agent;
  final String asOf;
  final List<AgentCustomer> customers;
  final List<UnlinkedLoan> unlinkedLoans;
  final AgentPortfolioSummary summary;

  AgentPortfolioResponse({
    required this.agent,
    required this.asOf,
    required this.customers,
    required this.unlinkedLoans,
    required this.summary,
  });

  factory AgentPortfolioResponse.empty(String agentId, String agentName) =>
      AgentPortfolioResponse(
        agent: AgentInfo(id: agentId, fullName: agentName),
        asOf: '',
        customers: const [],
        unlinkedLoans: const [],
        summary: AgentPortfolioSummary.empty(),
      );

  factory AgentPortfolioResponse.fromJson(Map<String, dynamic> j) =>
      AgentPortfolioResponse(
        agent: j['agent'] is Map
            ? AgentInfo.fromJson(Map<String, dynamic>.from(j['agent']))
            : AgentInfo(id: '', fullName: ''),
        asOf: _asString(j['as_of']),
        customers: _asList(j['customers'], AgentCustomer.fromJson),
        unlinkedLoans: _asList(j['unlinked_loans'], UnlinkedLoan.fromJson),
        summary: j['summary'] is Map
            ? AgentPortfolioSummary.fromJson(
                Map<String, dynamic>.from(j['summary']))
            : AgentPortfolioSummary.empty(),
      );
}