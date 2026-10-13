// models/fund.dart

enum FundStatus { active, matured, closed }

// models/fund.dart
extension FundStatusX on FundStatus {
  String get label {
    switch (this) {
      case FundStatus.active:
        return 'active';
      case FundStatus.matured:
        return 'matured';
      case FundStatus.closed:
        return 'closed';
    }
  }

  static FundStatus fromString(String? v) {
    switch (v?.toLowerCase()) {
      case 'matured':
        return FundStatus.matured;
      case 'closed':
      case 'settled':
        return FundStatus.closed;
      default:
        return FundStatus.active;
    }
  }
}

class FundEntry {
  final int week;
  final DateTime date;
  final double amount;
  final double? balanceAfter;
  final String? method;
  final String? notes;
  final bool isBonus;
  final bool isClosure;
  final bool paid;

  FundEntry({
    required this.week,
    required this.date,
    required this.amount,
    this.balanceAfter,
    this.method,
    this.notes,
    this.isBonus = false,
    this.isClosure = false,
    required this.paid,
  });

  factory FundEntry.fromJson(Map<String, dynamic> json) {
    // Backend `fund_payments` table uses `week_no`, `payment_date`,
    // `payment_method` and `amount`. Some older responses may vary,
    // so fall back to alternative keys when present.
    final weekVal = (json['week_no'] ?? json['week']) as dynamic;
    final dateStr = (json['payment_date'] ??
            json['due_date'] ??
            json['payment_at'] ??
            json['created_at'])
        ?.toString();
    final amt = _toDouble(json['amount'] ?? json['payment_amount']);
    final methodVal = (json['payment_method'] ?? json['method'])?.toString();
    final notesVal = (json['notes'] ?? json['description'])?.toString();
    final entryType =
        (json['entry_type'] ?? json['type'])?.toString().toLowerCase();
    final isBonus = entryType == 'bonus' ||
        (notesVal?.toLowerCase().contains('bonus') ?? false);
    final isClosure = entryType == 'closure' ||
        (notesVal?.toLowerCase().contains('closure') ?? false) ||
        (notesVal?.toLowerCase().contains('settled') ?? false);
    final paidFlag =
        (json['paid'] == true || json['paid'] == 1 || json['paid'] == '1');

    return FundEntry(
      week: weekVal is num
          ? weekVal.toInt()
          : int.tryParse(weekVal?.toString() ?? '') ?? 0,
      date: DateTime.tryParse(dateStr ?? '') ?? DateTime.now(),
      amount: amt,
      balanceAfter: _toDoubleOrNull(json['balance_after']),
      method: methodVal,
      notes: notesVal,
      isBonus: isBonus,
      isClosure: isClosure,
      // Treat an entry as paid when a payment_date exists, amount > 0,
      // or an explicit paid flag is present.
      paid: paidFlag || (amt > 0) || (dateStr != null && dateStr.isNotEmpty),
    );
  }
}

double? _toDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// One row of `fund_payouts` — money that has actually gone back to the
/// customer, with the cash_out ledger entry it wrote.
class FundPayoutRecord {
  final String id;
  final String fundId;

  /// maturity (deposits + bonus) · settlement (deposits, closed early) ·
  /// partial (the share of the deposits belonging to units closed early).
  final String kind;
  final double unitsClosed;
  final double depositAmount;
  final double bonusAmount;
  final double payoutAmount;
  final DateTime? payoutDate;
  final String paymentMethod;
  final String? agentName;
  final String? notes;

  const FundPayoutRecord({
    required this.id,
    required this.fundId,
    required this.kind,
    required this.unitsClosed,
    required this.depositAmount,
    required this.bonusAmount,
    required this.payoutAmount,
    required this.payoutDate,
    required this.paymentMethod,
    this.agentName,
    this.notes,
  });

  bool get isPartial => kind == 'partial';
  bool get bonusPaid => bonusAmount > 0;

  factory FundPayoutRecord.fromJson(Map<String, dynamic> json) {
    return FundPayoutRecord(
      id: json['id'].toString(),
      fundId: json['fund_id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'settlement',
      unitsClosed: _toDouble(json['units_closed']),
      depositAmount: _toDouble(json['deposit_amount']),
      bonusAmount: _toDouble(json['bonus_amount']),
      payoutAmount: _toDouble(json['payout_amount']),
      payoutDate: DateTime.tryParse(json['payout_date']?.toString() ?? ''),
      paymentMethod: json['payment_method']?.toString() ?? 'cash',
      agentName: json['agent_name']?.toString(),
      notes: json['notes']?.toString(),
    );
  }
}

/// What the server says paying this fund out would hand over today.
///
/// Every figure here is decided by `FundService` against the rows in the
/// database — the deposits actually received and the bonus only where it was
/// earned. The client used to work the same numbers out from the columns it
/// happened to hold and got a fund closed short of its target wrong, offering
/// to pay the full deposit back rather than what had come in.
class FundPayoutPreview {
  final String fundId;
  final FundStatus status;

  /// maturity (the bonus is earned) or settlement (closed early, it is not).
  final String kind;

  /// The customer's own deposits still owed back to them.
  final double depositAmount;

  /// The bonus being paid — zero on anything but a matured fund.
  final double bonusAmount;

  /// Payable right now: deposits + whatever bonus was earned.
  final double payoutAmount;

  /// weekly × weeks — what the customer signed up to deposit, bonus excluded.
  final double depositTarget;
  final double collected;
  final double remaining;

  /// What the scheme pays if it runs to term: the whole deposit plus the whole
  /// bonus. Shown on a fund still collecting, which has no payable amount yet.
  final double maturityPayout;
  final double weeklyAmount;
  final double fullBonus;
  final int weeksPaid;
  final int weeks;
  final bool bonusEarned;
  final bool canPay;
  final String? blockedReason;

  /// The payout already recorded against this fund, if it has been paid.
  final FundPayoutRecord? alreadyPaid;

  const FundPayoutPreview({
    required this.fundId,
    required this.status,
    required this.kind,
    required this.depositAmount,
    required this.bonusAmount,
    required this.payoutAmount,
    required this.depositTarget,
    required this.collected,
    required this.remaining,
    required this.maturityPayout,
    required this.weeklyAmount,
    required this.fullBonus,
    required this.weeksPaid,
    required this.weeks,
    required this.bonusEarned,
    required this.canPay,
    this.blockedReason,
    this.alreadyPaid,
  });

  bool get isPaidOut => alreadyPaid != null;

  factory FundPayoutPreview.fromJson(Map<String, dynamic> json) {
    final paid = json['already_paid'];
    return FundPayoutPreview(
      fundId: json['fund_id']?.toString() ?? '',
      status: FundStatusX.fromString(json['status']?.toString()),
      kind: json['kind']?.toString() ?? 'settlement',
      depositAmount: _toDouble(json['deposit_amount']),
      bonusAmount: _toDouble(json['bonus_amount']),
      payoutAmount: _toDouble(json['payout_amount']),
      depositTarget: _toDouble(json['deposit_target']),
      collected: _toDouble(json['collected']),
      remaining: _toDouble(json['remaining']),
      maturityPayout: _toDouble(json['maturity_payout']),
      weeklyAmount: _toDouble(json['weekly_amount']),
      fullBonus: _toDouble(json['full_bonus']),
      weeksPaid: _toDouble(json['weeks_paid']).toInt(),
      weeks: _toDouble(json['weeks']).toInt(),
      bonusEarned: json['bonus_earned'] == true,
      canPay: json['can_pay'] == true,
      blockedReason: json['blocked_reason']?.toString(),
      alreadyPaid: paid is Map
          ? FundPayoutRecord.fromJson(Map<String, dynamic>.from(paid))
          : null,
    );
  }
}

class Fund {
  final String id;
  final String code;
  final String customerId;
  final String customerName;
  final String? assignedAgentId;
  final String? agentName;
  final double units;
  final FundStatus status;
  final double weeklyAmount;
  final int numberOfWeeks;
  final double maturityBonus;
  final DateTime startDate;
  final DateTime maturityDate;

  /// Amount actually collected so far (backend column: collected_amount).
  final double depositedAmount;
  final int entriesPaid;
  final DateTime? payoutDate;
  final double? recordedPayoutAmount;

  /// What the server says this fund is worth today. Absent only when the row
  /// came from somewhere that does not carry one (a create/update response),
  /// in which case every getter below falls back to the local arithmetic.
  final FundPayoutPreview? preview;

  Fund({
    required this.id,
    required this.code,
    required this.customerId,
    required this.customerName,
    this.assignedAgentId,
    this.agentName,
    this.units = 1,
    required this.status,
    required this.weeklyAmount,
    required this.numberOfWeeks,
    required this.maturityBonus,
    required this.startDate,
    required this.maturityDate,
    required this.depositedAmount,
    required this.entriesPaid,
    this.payoutDate,
    this.recordedPayoutAmount,
    this.preview,
  });

  /// weekly × weeks — what the customer signed up to deposit. The server sends
  /// the same figure as `deposit_target`, which stays right after a partial
  /// closure has shrunk the scheme.
  double get totalDeposit =>
      preview?.depositTarget ?? weeklyAmount * numberOfWeeks;

  /// The payout already recorded in `fund_payouts`, once there is one.
  FundPayoutRecord? get paidOut => preview?.alreadyPaid;

  /// What would be handed over right now — the server's figure, not ours.
  ///
  /// A fund still collecting has nothing payable, so this is 0 for one; the
  /// card shows [maturityPayout] there instead. A fund closed early pays back
  /// the deposits actually received and no bonus, which is the case the old
  /// client-side arithmetic got wrong.
  double get payoutAmount =>
      paidOut?.payoutAmount ??
      preview?.payoutAmount ??
      recordedPayoutAmount ??
      (effectiveStatus == FundStatus.closed ? depositedAmount : maturityPayout);

  /// A deployed-server settlement only stores `status = closed`; newer
  /// deployments additionally return a payout record/date. Every one of those
  /// forms means the operator must not be offered the payout button again.
  bool get isPaidOut =>
      paidOut != null ||
      payoutDate != null ||
      effectiveStatus == FundStatus.closed;

  /// What the scheme pays if it runs to term: the whole deposit plus the whole
  /// bonus. This is the fund's contract value, not what is payable today.
  double get maturityPayout =>
      preview?.maturityPayout ?? totalDeposit + maturityBonus;

  FundStatus get effectiveStatus {
    // The server derives the status from the deposits and freezes it once the
    // fund is paid out, so where it has spoken it is the answer.
    if (preview != null) return preview!.status;
    if (status == FundStatus.closed) return FundStatus.closed;
    if (depositedAmount >= totalDeposit - 0.01 && totalDeposit > 0) {
      return FundStatus.matured;
    }
    return FundStatus.active;
  }

  double get remainingToSettle =>
      preview?.remaining ?? totalDeposit - depositedAmount;

  /// Whether the money can actually go out. The server's answer covers a fund
  /// still collecting, one already paid, and one that never took a deposit;
  /// the fallback is for rows that arrived without a preview.
  bool get canPayOut =>
      preview?.canPay ??
      (!isPaidOut && effectiveStatus != FundStatus.active && payoutAmount > 0);

  /// Why not, when [canPayOut] is false.
  String? get payoutBlockedReason => preview?.blockedReason;
  double get depositedPercent =>
      totalDeposit == 0 ? 0 : (depositedAmount / totalDeposit) * 100;

  /// Maps directly onto the `funds` table:
  /// id, fund_number, customer_id, customer_name, weekly_amount, weeks,
  /// bonus, deposit_amount, total_amount, collected_amount, start_date,
  /// maturity_date, status, created_at
  factory Fund.fromJson(Map<String, dynamic> json) {
    return Fund(
      id: json['id'].toString(),
      code: json['fund_number']?.toString() ?? json['code']?.toString() ?? '',
      customerId: json['customer_id']?.toString() ?? '',
      customerName: json['customer_name']?.toString() ?? 'Unknown Customer',
      assignedAgentId: json['assigned_agent']?.toString(),
      agentName: json['agent_name']?.toString(),
      units: _toDouble(json['units']) == 0 ? 1 : _toDouble(json['units']),
      status: FundStatusX.fromString(json['status']?.toString()),
      weeklyAmount: _toDouble(json['weekly_amount']),
      numberOfWeeks:
          _toDouble(json['weeks'] ?? json['number_of_weeks']).toInt(),
      maturityBonus: _toDouble(json['bonus'] ?? json['maturity_bonus']),
      startDate: DateTime.tryParse(json['start_date']?.toString() ?? '') ??
          DateTime.now(),
      maturityDate:
          DateTime.tryParse(json['maturity_date']?.toString() ?? '') ??
              DateTime.now(),
      depositedAmount:
          _toDouble(json['collected_amount'] ?? json['deposited_amount']),
      entriesPaid: _toDouble(json['entries_paid']).toInt(),
      payoutDate: DateTime.tryParse(json['payout_date']?.toString() ?? ''),
      recordedPayoutAmount: json['payout_amount'] == null
          ? null
          : _toDouble(json['payout_amount']),
      preview: json['payout_preview'] is Map
          ? FundPayoutPreview.fromJson(
              Map<String, dynamic>.from(json['payout_preview'] as Map))
          : null,
    );
  }

  /// Used for both create and update payloads — matches backend column names.
  Map<String, dynamic> toCreateJson() {
    return {
      'fund_number': code,
      'customer_id': customerId,
      'customer_name': customerName,
      'assigned_agent': assignedAgentId,
      'agent_name': agentName,
      'units': units,
      'weekly_amount': weeklyAmount,
      'weeks': numberOfWeeks,
      'bonus': maturityBonus,
      'deposit_amount': totalDeposit,
      // The fund's contract value — deposit target + bonus — never what a
      // payout would hand over today, which for a closed fund is less.
      'total_amount': maturityPayout,
      'start_date':
          '${startDate.year.toString().padLeft(4, '0')}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}',
      'maturity_date':
          '${maturityDate.year.toString().padLeft(4, '0')}-${maturityDate.month.toString().padLeft(2, '0')}-${maturityDate.day.toString().padLeft(2, '0')}',
    };
  }

  Fund copyWith({
    String? id,
    String? code,
    String? customerId,
    String? customerName,
    String? assignedAgentId,
    String? agentName,
    double? units,
    FundStatus? status,
    double? weeklyAmount,
    int? numberOfWeeks,
    double? maturityBonus,
    DateTime? startDate,
    DateTime? maturityDate,
    double? depositedAmount,
    int? entriesPaid,
    DateTime? payoutDate,
    double? recordedPayoutAmount,
    FundPayoutPreview? preview,
  }) {
    return Fund(
      id: id ?? this.id,
      code: code ?? this.code,
      customerId: customerId ?? this.customerId,
      customerName: customerName ?? this.customerName,
      assignedAgentId: assignedAgentId ?? this.assignedAgentId,
      agentName: agentName ?? this.agentName,
      units: units ?? this.units,
      status: status ?? this.status,
      weeklyAmount: weeklyAmount ?? this.weeklyAmount,
      numberOfWeeks: numberOfWeeks ?? this.numberOfWeeks,
      maturityBonus: maturityBonus ?? this.maturityBonus,
      startDate: startDate ?? this.startDate,
      maturityDate: maturityDate ?? this.maturityDate,
      depositedAmount: depositedAmount ?? this.depositedAmount,
      entriesPaid: entriesPaid ?? this.entriesPaid,
      payoutDate: payoutDate ?? this.payoutDate,
      recordedPayoutAmount: recordedPayoutAmount ?? this.recordedPayoutAmount,
      preview: preview ?? this.preview,
    );
  }
}

class FundsSummary {
  final int totalFunds;
  final int activeFunds;
  final double maturityPayoutTotal;
  final double collectedTotal;

  FundsSummary({
    required this.totalFunds,
    required this.activeFunds,
    required this.maturityPayoutTotal,
    required this.collectedTotal,
  });

  factory FundsSummary.fromJson(Map<String, dynamic> json) {
    return FundsSummary(
      totalFunds: (json['total_funds'] as num?)?.toInt() ?? 0,
      activeFunds: (json['active_funds'] as num?)?.toInt() ?? 0,
      maturityPayoutTotal: _toDouble(json['maturity_payout_total']),
      collectedTotal: _toDouble(json['collected_total']),
    );
  }
}

double _toDouble(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

/// One fund as the server sees it right now: the row, every payout recorded
/// against it, and what a payout would hand over today.
///
/// Returned from `funds.php` by every read *and* every write, so a screen never
/// has to guess what the server decided — after a payout the same call that
/// made it comes back carrying the stored `fund_payouts` row.
class FundSheet {
  final Fund fund;
  final List<FundPayoutRecord> payouts;
  final FundPayoutPreview? preview;

  const FundSheet({
    required this.fund,
    required this.payouts,
    required this.preview,
  });

  /// The maturity/settlement payout, once the fund has been paid out. Partial
  /// closures are excluded: they hand over a share and leave the fund running.
  FundPayoutRecord? get finalPayout {
    if (preview?.alreadyPaid != null) return preview!.alreadyPaid;
    for (final p in payouts) {
      if (!p.isPartial) return p;
    }
    return null;
  }

  List<FundPayoutRecord> get partialPayouts =>
      payouts.where((p) => p.isPartial).toList();

  factory FundSheet.fromJson(Map<String, dynamic> json) {
    final preview = json['payout'] is Map
        ? FundPayoutPreview.fromJson(
            Map<String, dynamic>.from(json['payout'] as Map))
        : null;

    final fundRow = json['fund'] is Map
        ? Map<String, dynamic>.from(json['fund'] as Map)
        : <String, dynamic>{};

    final payoutRows =
        json['payouts'] is List ? json['payouts'] as List : const [];

    return FundSheet(
      // Threaded onto the row so the Fund's own getters read the server's
      // figures rather than recomputing them.
      fund: Fund.fromJson({
        ...fundRow,
        if (preview != null) 'payout_preview': json['payout'],
      }),
      payouts: payoutRows
          .map((r) =>
              FundPayoutRecord.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList(),
      preview: preview,
    );
  }
}
