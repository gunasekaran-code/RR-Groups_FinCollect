enum AgentCollectionStatus { overdue, dueToday, pending, paid }

/// The four collection "shapes" your product supports. Everything about
/// which buttons/boxes CollectPaymentSheet shows, and how the backend
/// applies a payment, is driven off this enum instead of scattered string
/// checks on `loanType`.
enum LoanCollectionType { weekly, monthlyEmi, daily, monthlyInterest, other }

/// Normalizes a raw `loan_type` / `collection_type` string (e.g. "Weekly",
/// "Monthly EMI", "monthly_interest", "Daily Loan") into a
/// [LoanCollectionType]. Centralizing this means the sheet, the list
/// screen, and the API service all agree on what "this is a daily loan"
/// means, instead of each doing their own `.toLowerCase().contains(...)`.
LoanCollectionType parseLoanCollectionType(String raw) {
  final v = raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  // Check monthlyinterest before the generic "monthly" check below.
  if (v.contains('monthlyinterest') || v.contains('interest')) {
    return LoanCollectionType.monthlyInterest;
  }
  if (v.contains('daily')) return LoanCollectionType.daily;
  if (v.contains('weekly')) return LoanCollectionType.weekly;
  if (v.contains('monthly') || v.contains('emi')) {
    return LoanCollectionType.monthlyEmi;
  }
  return LoanCollectionType.other;
}

class AgentCollectionItem {
  final String id;
  final String? scheduleId;
  final String loanId;
  final String loanType;
  final String loanName;
  final String? customerId;
  final String customerName;
  final String loanNumber;
  final double dueAmount;
  final double installmentAmount;
  final double penaltyAmount;

  /// Penalty still owed on the whole loan (`loans.penalty_amount`). Unlike
  /// [penaltyAmount] it includes late instalments whose EMI is already paid,
  /// so it is the figure to collect against.
  final double? loanPenaltyAmount;
  final DateTime? dueDate;
  final String rawStatus;
  final String? contactPhone;
  final String? agentId;
  final String? agentName;
  final String? address;
  final double? latitude;
  final double? longitude;
  final double? outstandingBalance;

  const AgentCollectionItem({
    required this.id,
    this.scheduleId,
    required this.loanId,
    required this.loanType,
    required this.loanName,
    this.customerId,
    required this.customerName,
    required this.loanNumber,
    required this.dueAmount,
    this.installmentAmount = 0,
    this.penaltyAmount = 0,
    this.loanPenaltyAmount,
    this.dueDate,
    required this.rawStatus,
    this.contactPhone,
    this.agentId,
    this.agentName,
    this.address,
    this.latitude,
    this.longitude,
    this.outstandingBalance,
  });

  factory AgentCollectionItem.fromJson(Map<String, dynamic> json) {
    double parseDouble(dynamic raw) {
      if (raw == null) return 0;
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw.toString()) ?? 0;
    }

    double? parseDoubleOrNull(dynamic raw) {
      if (raw == null) return null;
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw.toString());
    }

    final dueAmount = parseDouble(
      json['due_amount'] ?? json['balance'] ?? json['emi_amount'],
    );

    return AgentCollectionItem(
      id: (json['id'] ?? '').toString(),
      scheduleId: json['schedule_id']?.toString(),
      loanId: (json['loan_id'] ?? '').toString(),
      loanType: (json['loan_type'] ?? json['collection_type'] ?? 'Monthly')
          .toString(),
      loanName: (json['loan_name'] ??
              json['scheme_name'] ??
              json['collection_name'] ??
              json['loan_number'] ??
              '-')
          .toString(),
      customerId: json['customer_id']?.toString(),
      customerName: (json['customer_name'] ?? '-').toString(),
      loanNumber: (json['loan_number'] ?? '-').toString(),
      dueAmount: dueAmount,
      installmentAmount: parseDouble(json['emi_amount']),
      penaltyAmount: parseDouble(json['penalty_amount']),
      loanPenaltyAmount: parseDoubleOrNull(json['loan_penalty_amount']),
      dueDate: _parseDate(json['due_date']),
      rawStatus: (json['status'] ?? 'pending').toString().toLowerCase(),
      contactPhone: (json['contact_phone'] ?? json['phone'])?.toString(),
      agentId: json['agent_id']?.toString(),
      agentName: json['agent_name']?.toString(),
      address: (json['address'] ??
              json['customer_address'] ??
              json['location_address'])
          ?.toString(),
      latitude: parseDoubleOrNull(json['latitude'] ?? json['lat']),
      longitude:
          parseDoubleOrNull(json['longitude'] ?? json['lng'] ?? json['lon']),
      outstandingBalance: parseDoubleOrNull(
        json['outstanding_balance'] ?? json['loan_balance'],
      ),
    );
  }

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString());
  }

  String get initials => _initialsFor(customerName);

  /// The normalized type this item belongs to. Everything else
  /// (penalty applicability, which buttons to show) should read off this
  /// rather than re-parsing `loanType` in multiple places.
  LoanCollectionType get collectionType => parseLoanCollectionType(loanType);

  /// Weekly, monthly-EMI and monthly-interest loans carry an overdue
  /// penalty. Daily loans never do — even if a stray `penalty_amount`
  /// value shows up from the backend, the UI should ignore it for them.
  bool get appliesPenalty =>
      collectionType == LoanCollectionType.weekly ||
      collectionType == LoanCollectionType.monthlyEmi ||
      collectionType == LoanCollectionType.monthlyInterest;

  bool get isMonthlyInterest =>
      collectionType == LoanCollectionType.monthlyInterest;

  /// Penalty amount gated by loan type — use this instead of
  /// [penaltyAmount] directly anywhere you're deciding what to *display*.
  double get effectivePenalty => appliesPenalty ? penaltyAmount : 0;

  String get displayLoanType {
    final value = loanType.trim();
    if (value.isEmpty) return 'Loan';
    final lower = value.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}';
  }

  String get displayLoanName {
    final value = loanName.trim();
    if (value.isNotEmpty && value != '-') return value;
    return loanNumber;
  }

  String get uniqueName =>
      '$customerName • $displayLoanType • $displayLoanName';

  bool get isPaid => rawStatus == 'paid' || rawStatus == 'collected';

  AgentCollectionStatus get status {
    if (isPaid) return AgentCollectionStatus.paid;
    // The backend reconciles repayment_schedule.status to "overdue".
    // Keep that database status authoritative so a row due today is not
    // accidentally counted as overdue because of a timezone/date fallback.
    if (rawStatus == 'overdue') return AgentCollectionStatus.overdue;
    final due = dueDate;
    if (due != null) {
      final now = DateTime.now();
      final dueOnly = DateTime(due.year, due.month, due.day);
      final today = DateTime(now.year, now.month, now.day);
      if (dueOnly.isAtSameMomentAs(today)) {
        return AgentCollectionStatus.dueToday;
      }
    }
    return AgentCollectionStatus.pending;
  }

  String get statusLabel => _labelFor(status);

  String get formattedDueAmount => formatAmount(dueAmount);

  String get formattedPenaltyAmount => formatAmount(effectivePenalty);

  String get formattedTotalDue => formatAmount(dueAmount + effectivePenalty);

  String get formattedDueDate => formatDate(dueDate);

  static String formatDate(DateTime? d) {
    if (d == null) return '-';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
  }

  static String formatAmount(double value) {
    final intValue = value.round();
    final isNegative = intValue < 0;
    final digits = intValue.abs().toString();

    String grouped;
    if (digits.length <= 3) {
      grouped = digits;
    } else {
      final lastThree = digits.substring(digits.length - 3);
      var remaining = digits.substring(0, digits.length - 3);
      final groups = <String>[];
      while (remaining.length > 2) {
        groups.insert(0, remaining.substring(remaining.length - 2));
        remaining = remaining.substring(0, remaining.length - 2);
      }
      if (remaining.isNotEmpty) groups.insert(0, remaining);
      grouped = '${groups.join(',')},$lastThree';
    }

    return '${isNegative ? '-' : ''}₹$grouped';
  }
}

String _initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

String _labelFor(AgentCollectionStatus status) {
  switch (status) {
    case AgentCollectionStatus.overdue:
      return 'Overdue';
    case AgentCollectionStatus.dueToday:
      return 'Due Today';
    case AgentCollectionStatus.paid:
      return 'Collected';
    case AgentCollectionStatus.pending:
      return 'Active';
  }
}

class AgentCustomerGroup {
  final String customerId;
  final String customerName;
  final String loanId;
  final String loanType;
  final String loanName;
  final String? contactPhone;
  final String? address;
  final double? latitude;
  final double? longitude;
  final List<AgentCollectionItem> items;

  const AgentCustomerGroup({
    required this.customerId,
    required this.customerName,
    required this.loanId,
    required this.loanType,
    required this.loanName,
    required this.items,
    this.contactPhone,
    this.address,
    this.latitude,
    this.longitude,
  });

  List<String> get loanNumbers =>
      items.map((e) => e.loanNumber).toSet().toList();

  /// A group is created per (customer, loan), so every item in it shares
  /// the same loan type — safe to read off the first item.
  LoanCollectionType get collectionType =>
      items.isNotEmpty ? items.first.collectionType : LoanCollectionType.other;

  bool get appliesPenalty =>
      items.isNotEmpty ? items.first.appliesPenalty : false;

  bool get isMonthlyInterest =>
      collectionType == LoanCollectionType.monthlyInterest;

  String get displayLoanType {
    final value = loanType.trim();
    if (value.isEmpty) return 'Loan';
    final lower = value.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}';
  }

  String get displayLoanName {
    final value = loanName.trim();
    if (value.isNotEmpty && value != '-') return value;
    return loanNumbers.isNotEmpty ? loanNumbers.first : '-';
  }

  String get uniqueName =>
      '$customerName • $displayLoanType • $displayLoanName';

  List<String> get loanIds => items.map((e) => e.loanId).toSet().toList();

  double get totalDue => items.fold(0.0, (sum, i) => sum + i.dueAmount);

  /// Penalty still owed across the group's loans, gated by loan type —
  /// daily loans never contribute here. Read from the loan rather than
  /// summed over the open instalments: a late instalment keeps its penalty
  /// after its EMI is paid, and a paid instalment is not in [items].
  double get totalPenalty {
    final seenLoans = <String>{};
    double sum = 0;
    for (final i in items) {
      if (!i.appliesPenalty) continue;
      if (i.loanPenaltyAmount == null) {
        sum += i.penaltyAmount;
      } else if (seenLoans.add(i.loanId)) {
        sum += i.loanPenaltyAmount!;
      }
    }
    return sum;
  }

  double get totalDueWithPenalty => totalDue + totalPenalty;

  /// For monthly-interest loans this doubles as "remaining principal".
  double get totalOutstanding {
    final seenLoans = <String>{};
    double sum = 0;
    bool any = false;
    for (final i in items) {
      if (i.outstandingBalance == null) continue;
      if (!seenLoans.add(i.loanId)) continue;
      any = true;
      sum += i.outstandingBalance!;
    }
    return any ? sum : totalDue;
  }

  /// For monthly-interest loans this is the interest currently due
  /// (reuses `installmentAmount`, which the API/service layer populates
  /// from `emi_amount` — for an interest loan that field represents the
  /// month's interest, not principal).
  double get monthlyInterestDue =>
      items.isNotEmpty ? items.first.installmentAmount : 0;

  List<AgentCollectionItem> get overdueItems => items
      .where((item) => item.status == AgentCollectionStatus.overdue)
      .toList();

  /// Open installments that should be included in today's Pay Dues action.
  /// This includes both past-due rows and the installment due today.
  List<AgentCollectionItem> get payableDueItems => items
      .where((item) =>
          item.status == AgentCollectionStatus.overdue ||
          item.status == AgentCollectionStatus.dueToday)
      .toList();

  List<AgentCollectionItem> get overdueDueItems => items
      .where((item) => item.status == AgentCollectionStatus.overdue)
      .toList();

  List<AgentCollectionItem> get dueTodayItems => items
      .where((item) => item.status == AgentCollectionStatus.dueToday)
      .toList();

  int get overdueCount => overdueDueItems.length;

  int get dueTodayCount => dueTodayItems.length;

  int get overdueDueCount => payableDueItems.length;

  double get overdueEmi {
    for (final item in items) {
      if (item.installmentAmount > 0) return item.installmentAmount;
    }
    return 0;
  }

  /// Uses each repayment schedule row's actual remaining balance. Do not
  /// derive this from an EMI multiplied by row count because partial
  /// payments can leave different balances on different schedule rows.
  /// Excludes penalty — that is collected separately (see [totalPenalty]).
  double get overdueDueAmount =>
      payableDueItems.fold(0, (sum, item) => sum + item.dueAmount);

  DateTime? get nearestDueDate {
    final dates = items.map((e) => e.dueDate).whereType<DateTime>().toList();
    if (dates.isEmpty) return null;
    dates.sort();
    return dates.first;
  }

  bool get hasOverdue =>
      items.any((i) => i.status == AgentCollectionStatus.overdue);
  bool get hasDueToday =>
      items.any((i) => i.status == AgentCollectionStatus.dueToday);

  AgentCollectionStatus get status {
    if (hasOverdue) return AgentCollectionStatus.overdue;
    if (hasDueToday) return AgentCollectionStatus.dueToday;
    return AgentCollectionStatus.pending;
  }

  String get statusLabel => _labelFor(status);

  String get initials => _initialsFor(customerName);

  bool get hasLocation =>
      (latitude != null && longitude != null) ||
      (address != null && address!.trim().isNotEmpty);

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (customerName.toLowerCase().contains(q)) return true;
    if (customerId.toLowerCase().contains(q)) return true;
    if (loanId.toLowerCase().contains(q)) return true;
    if (loanType.toLowerCase().contains(q)) return true;
    if (loanName.toLowerCase().contains(q)) return true;
    return items.any((i) =>
        i.loanNumber.toLowerCase().contains(q) ||
        i.loanId.toLowerCase().contains(q) ||
        i.loanType.toLowerCase().contains(q) ||
        i.loanName.toLowerCase().contains(q));
  }

  static List<AgentCustomerGroup> groupItems(List<AgentCollectionItem> items) {
    final map = <String, List<AgentCollectionItem>>{};
    for (final item in items) {
      final customerKey =
          (item.customerId != null && item.customerId!.isNotEmpty)
              ? item.customerId!
              : item.customerName;
      final loanKey = item.loanId.isNotEmpty ? item.loanId : item.loanNumber;
      final key = '$customerKey|$loanKey';
      map.putIfAbsent(key, () => []).add(item);
    }

    final groups = map.entries.map((entry) {
      final groupItems = [...entry.value]..sort((a, b) {
          final aDate = a.dueDate ?? DateTime(2100);
          final bDate = b.dueDate ?? DateTime(2100);
          return aDate.compareTo(bDate);
        });
      final first = groupItems.first;
      final withAddress = groupItems.firstWhere(
        (i) => i.address != null && i.address!.trim().isNotEmpty,
        orElse: () => first,
      );
      final withPhone = groupItems.firstWhere(
        (i) => i.contactPhone != null && i.contactPhone!.trim().isNotEmpty,
        orElse: () => first,
      );
      return AgentCustomerGroup(
        customerId: first.customerId ?? first.customerName,
        customerName: first.customerName,
        loanId: first.loanId,
        loanType: first.loanType,
        loanName: first.loanName,
        items: groupItems,
        contactPhone: withPhone.contactPhone,
        address: withAddress.address,
        latitude: withAddress.latitude,
        longitude: withAddress.longitude,
      );
    }).toList();

    groups.sort((a, b) {
      int rank(AgentCollectionStatus s) {
        if (s == AgentCollectionStatus.overdue) return 0;
        if (s == AgentCollectionStatus.dueToday) return 1;
        return 2;
      }

      final rankCompare = rank(a.status).compareTo(rank(b.status));
      if (rankCompare != 0) return rankCompare;
      final aDate = a.nearestDueDate ?? DateTime(2100);
      final bDate = b.nearestDueDate ?? DateTime(2100);
      return aDate.compareTo(bDate);
    });

    return groups;
  }
}
