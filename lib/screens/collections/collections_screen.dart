import 'package:flutter/material.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../theme/confirm_dialog.dart';
import '../../widgets/page_header.dart';
import '../../theme/glass_toast.dart';
import '../../services/collection_api_service.dart';
import '../../services/loan_service.dart';
import '../../services/api_client.dart';
import '../../services/agent_collection_api_service.dart';
import '../../models/customer.dart';
import '../../models/loan_record.dart';
import '../../models/repayment_installment.dart';
import '../../models/agent_collection.dart';
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import '../../widgets/app_upload.dart';
import '../../l10n/generated/app_localizations.dart';
import '../loans/loans_screen.dart'
    show
        localizedStatusLabel,
        friendlyCollectionTypeLabel,
        collectionTypeOptionKey;
import '../../widgets/collect_payment_sheet.dart';
import '../../widgets/responsive_stat_grid.dart';

/// Maps an internal period-filter key to its localized chip label. Internal
/// keys ('Today', 'This Week', 'This Month', 'All') stay English-constant
/// since they're also used for date-range comparisons in [_matchesPeriod].
String localizedPeriodLabel(String key, AppLocalizations l10n) {
  switch (key) {
    case 'Today':
      return l10n.collectionsPeriodToday;
    case 'This Week':
      return l10n.collectionsPeriodThisWeek;
    case 'This Month':
      return l10n.collectionsPeriodThisMonth;
    case 'All':
      return l10n.loansFilterAll;
    default:
      return key;
  }
}

/// Maps an internal payment-method key to its localized display text.
/// Internal keys stay English-constant since they're round-tripped through
/// [_apiMethodValue] when saving back to the API.
String localizedPaymentMethodLabel(String key, AppLocalizations l10n) {
  switch (key) {
    case 'Cash':
      return l10n.collectionsMethodCash;
    case 'UPI':
      return l10n.collectionsMethodUpi;
    case 'Bank Transfer':
      return l10n.collectionsMethodBank;
    case 'Cheque':
      return l10n.collectionsMethodCheque;
    case 'Card':
      return l10n.collectionsMethodCard;
    default:
      return key;
  }
}

/// One loan on the "To Collect Today" list, worked out with the web
/// dashboard's rule so both apps show the same customers and amounts.
class DueTodayLine {
  DueTodayLine({
    required this.loanId,
    required this.customerId,
    required this.customerName,
    required this.loanNumber,
    required this.dueToday,
    required this.dueTodayCount,
    required this.overdue,
    required this.overdueCount,
    required this.penalty,
    required this.collectedToday,
    required this.oldestDue,
  });

  final String loanId;
  final String? customerId;
  final String customerName;
  final String loanNumber;
  final double dueToday; // instalment balance falling due today
  final int dueTodayCount;
  final double overdue; // unpaid balance of earlier instalments (arrears)
  final int overdueCount;
  final double penalty;
  final double collectedToday;
  final String? oldestDue; // yyyy-MM-dd of the oldest open instalment

  double get remaining => _r2(dueToday + overdue + penalty);
  bool get settled => remaining <= 0;
}

/// The whole "To Collect Today" sheet: every active or overdue loan with an
/// instalment due today or earlier (or penalty), plus any loan fully paid
/// today. Mirrors the web app's dueToday helper.
class DueTodaySheet {
  DueTodaySheet(this.lines);

  final List<DueTodayLine> lines;

  double get remaining => _r2(lines.fold(0, (s, l) => s + l.remaining));
  double get overdueTotal => _r2(lines.fold(0, (s, l) => s + l.overdue));
  int get settled => lines.where((l) => l.settled).length;

  /// Distinct customers who still owe something today.
  int get customers => lines
      .where((l) => !l.settled)
      .map((l) => l.customerId ?? 'loan:${l.loanId}')
      .toSet()
      .length;

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  factory DueTodaySheet.build({
    required List<LoanRecord> loans,
    required Iterable<RepaymentInstallment> schedules,
    required Map<String, double> collectedTodayByLoan,
    DateTime? now,
  }) {
    final today = dayKey(now ?? DateTime.now());

    // Open instalments per loan.
    final openByLoan = <String, List<RepaymentInstallment>>{};
    for (final row in schedules) {
      if (row.loanId.isEmpty || row.status == 'paid' || row.balance <= 0) {
        continue;
      }
      openByLoan.putIfAbsent(row.loanId, () => []).add(row);
    }

    final lines = <DueTodayLine>[];
    for (final loan in loans) {
      final status = loan.status.toLowerCase();
      if (status != 'active' && status != 'overdue') continue;

      var dueToday = 0.0, overdue = 0.0, rowPenalty = 0.0;
      var dueTodayCount = 0, overdueCount = 0;
      String? oldest;
      for (final row in openByLoan[loan.id] ?? const <RepaymentInstallment>[]) {
        final due = row.dueDate == null ? '' : dayKey(row.dueDate!);
        if (due.isEmpty || due.compareTo(today) > 0) continue;
        rowPenalty += row.penaltyAmount;
        if (due == today) {
          dueToday += row.balance;
          dueTodayCount++;
        } else {
          overdue += row.balance;
          overdueCount++;
        }
        if (oldest == null || due.compareTo(oldest) < 0) oldest = due;
      }
      final penalty =
          loan.penaltyAmount != 0 ? loan.penaltyAmount : rowPenalty;
      final collected = _r2(collectedTodayByLoan[loan.id] ?? 0);
      final line = DueTodayLine(
        loanId: loan.id,
        customerId: loan.customerId,
        customerName: loan.customerName,
        loanNumber: loan.loanNumber,
        dueToday: _r2(dueToday),
        dueTodayCount: dueTodayCount,
        overdue: _r2(overdue),
        overdueCount: overdueCount,
        penalty: _r2(penalty),
        collectedToday: collected,
        oldestDue: oldest,
      );
      if (line.remaining <= 0 && collected <= 0) continue;
      lines.add(line);
    }

    // Still owing first, oldest arrears first, then biggest amount.
    lines.sort((a, b) {
      if (a.settled != b.settled) return a.settled ? 1 : -1;
      final ao = a.oldestDue, bo = b.oldestDue;
      if (ao != null && bo != null && ao != bo) return ao.compareTo(bo);
      final byAmount = b.remaining.compareTo(a.remaining);
      if (byAmount != 0) return byAmount;
      return a.customerName.compareTo(b.customerName);
    });
    return DueTodaySheet(lines);
  }
}

double _r2(double n) => (n * 100).roundToDouble() / 100;

class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key});

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  String _query = '';
  String _period = 'All';
  bool _isLoading = true; // NEW
  String? _loadError; // NEW
  bool _showAll = false;

  final List<String> _periods = const [
    'Today',
    'This Week',
    'This Month',
    'All'
  ];

  static final DateTime _today = DateTime.now();
  List<Map<String, String>> _collections = [];
  final Map<String, String> _receiptToId = {}; // receipt_number -> id
  List<Customer> _customers = [];
  List<LoanRecord> _allLoans = [];
  List<String> _agentNames = [];
  Map<String, String> _agentNameById = {};
  Map<String, List<RepaymentInstallment>> _schedulesByLoan = {};
  List<AgentCustomerGroup> _collectionGroups = [];
  // Every unpaid instalment due today or earlier, for "To Collect Today".
  // Fetched on its own: [_schedulesByLoan] comes from a query capped at 200
  // rows, which a couple of 100-day loans use up, leaving the rest empty.
  List<RepaymentInstallment> _openDueRows = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadCollections();
    });
  }


  static const Map<int, String> _monthNames = {
    1: 'Jan',    2: 'Feb',    3: 'Mar',    4: 'Apr',
    5: 'May',    6: 'Jun',    7: 'Jul',    8: 'Aug',
    9: 'Sep',    10: 'Oct',    11: 'Nov',    12: 'Dec',
  };

  String _formatApiDate(dynamic raw) {
    if (raw == null) return '-';
    final s = raw.toString();
    // Expecting 'YYYY-MM-DD' or a full datetime string from MySQL
    try {
      final dt = DateTime.parse(s);
      final month = _monthNames[dt.month] ?? '';
      final day = dt.day.toString().padLeft(2, '0');
      return '$day $month ${dt.year}';
    } catch (_) {
      return s;
    }
  }

  String _formatAmount(dynamic raw) {
    final value = double.tryParse(raw?.toString() ?? '0') ?? 0;
    final intValue = value.round();
    final s = intValue.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final posFromEnd = s.length - i;
      buf.write(s[i]);
      if (posFromEnd > 3 && (posFromEnd - 3) % 2 == 0) buf.write(',');
    }
    return '₹$buf';
  }

  // NOTE: returns internal (English) keys — see [localizedPaymentMethodLabel]
  // for the display-ready label.
  String _formatMethod(dynamic raw) {
    switch ((raw ?? '').toString()) {
      case 'cash':
        return 'Cash';
      case 'upi':
        return 'UPI';
      case 'bank':
        return 'Bank Transfer';
      case 'cheque':
        return 'Cheque';
      case 'card':
        return 'Card';
      default:
        return (raw ?? '-').toString();
    }
  }

  String _apiMethodValue(String uiMethod) {
    switch (uiMethod) {
      case 'Cash':
        return 'cash';
      case 'UPI':
        return 'upi';
      case 'Bank Transfer':
        return 'bank';
      case 'Cheque':
        return 'cheque';
      case 'Card':
        return 'card';
      default:
        return 'cash';
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  Map<String, String> _mapRow(Map<String, dynamic> row) {
    final id = (row['id'] ?? '').toString();
    final receipt = (row['receipt_number'] ?? '').toString();
    final customerName = (row['customer_name'] ?? '').toString();
    final loanType =
        (row['loan_type'] ?? row['collection_type'] ?? '').toString().trim();
    final loanNumber = (row['loan_number'] ?? '-').toString();

    if (id.isNotEmpty && receipt.isNotEmpty) {
      _receiptToId[receipt] = id;
    }

    return {
      'id': id,
      'customer_id': (row['customer_id'] ?? '').toString(),
      'customer': customerName.isEmpty ? '-' : customerName,
      'initials': _initials(customerName.isEmpty ? '-' : customerName),
      'receipt': receipt.isEmpty ? '-' : receipt,
      'loan': loanNumber,
      'loan_id': (row['loan_id'] ?? '').toString(),
      'loan_type': loanType.isEmpty ? '-' : loanType,
      'amount': _formatAmount(row['collection_amount']),
      'date': _formatApiDate(row['collection_date']),
      'method': _formatMethod(row['payment_method']),
      'agent': (row['agent_name'] ?? 'Unassigned').toString(),
      'agent_id': (row['agent_id'] ?? '').toString(),
      'notes': (row['notes'] ?? '').toString(),
      'status': 'Collected',
    };
  }

  Future<void> _loadCollections() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    final l10n = AppLocalizations.of(context);

    try {
      final customersFuture = LoanService.instance.fetchCustomers();
      final agentsFuture = LoanService.instance.fetchAgents();
      final customers = await customersFuture;
      final agents = await agentsFuture;
      // Always bypass LoanService's cache: a collection (penalty payments
      // included) is recalculated on the backend, so cached loans and
      // schedules would keep showing the old penalty and total due.
      final loans = await LoanService.instance.fetchLoans(
        customers: customers,
        agents: agents,
        forceRefresh: true,
      );
      final scheduleRows =
          await LoanService.instance.fetchRepaymentSchedulesForLoans(
        loans.map((loan) => loan.id).toList(),
        forceRefresh: true,
      );
      final rows = await CollectionApiService.fetchCollections(
        limit: 200,
        order: 'collection_date.desc',
      );
      final collectionGroups =
          await AgentCollectionApiService.fetchAllCollectionGroups();
      final openDueRows = await ApiClient.instance.list(
        'repayment_schedule',
        query: {
          'status': 'neq.paid',
          'due_date': 'lte.${DueTodaySheet.dayKey(DateTime.now())}',
        },
      );
      final schedules = <String, List<RepaymentInstallment>>{
        for (final entry in scheduleRows.entries) entry.key: entry.value,
      };
      final mapped = rows.map(_mapRow).toList();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _allLoans = loans;
        _agentNames = agents.map((agent) => agent.name).toList()..sort();
        _agentNameById = {for (final a in agents) a.id: a.name};
        _schedulesByLoan = schedules;
        _collections = mapped;
        _collectionGroups = collectionGroups;
        _openDueRows = openDueRows.map(RepaymentInstallment.fromJson).toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
      ToastService.show(
        title: l10n.collectionsLoadFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  int _parseAmount(String amount) =>
      int.tryParse(amount.replaceAll(RegExp(r'[₹,]'), '')) ?? 0;

  static const Map<String, int> _months = {
    'Jan': 1,    'Feb': 2,    'Mar': 3,    'Apr': 4,
    'May': 5,    'Jun': 6,    'Jul': 7,    'Aug': 8,
    'Sep': 9,    'Oct': 10,    'Nov': 11,    'Dec': 12,
  };

  DateTime? _parseDate(String date) {
    final isoDate = DateTime.tryParse(date);
    if (isoDate != null) {
      return DateTime(isoDate.year, isoDate.month, isoDate.day);
    }
    final slashParts = date.split('/');
    if (slashParts.length == 3) {
      final day = int.tryParse(slashParts[0]);
      final month = int.tryParse(slashParts[1]);
      final year = int.tryParse(slashParts[2]);
      if (day != null && month != null && year != null) {
        return DateTime(year, month, day);
      }
    }
    final parts = date.split(' ');
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]);
    final month = _months[parts[1]];
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return null;
    return DateTime(year, month, day);
  }

  bool _matchesPeriod(Map<String, String> c, String period) {
    final date = _parseDate(c['date'] ?? '');
    if (date == null || period == 'All') return true;
    switch (period) {
      case 'Today':
        return date.year == _today.year &&
            date.month == _today.month &&
            date.day == _today.day;
      case 'This Week':
        final diff = _today.difference(date).inDays;
        return diff >= 0 && diff < 7;
      case 'This Month':
        return date.year == _today.year && date.month == _today.month;
      default:
        return true;
    }
  }

  List<Map<String, String>> get _filtered => _collections.where((c) {
        final q = _query.toLowerCase();
        final matchesQuery = q.isEmpty ||
            c['customer']!.toLowerCase().contains(q) ||
            c['loan']!.toLowerCase().contains(q) ||
            c['loan_type']!.toLowerCase().contains(q) ||
            c['receipt']!.toLowerCase().contains(q);
        return matchesQuery && _matchesPeriod(c, _period);
      }).toList();

  int get _todayTotal => _collections
      .where((c) => _matchesPeriod(c, 'Today'))
      .fold(0, (sum, c) => sum + _parseAmount(c['amount']!));

  int get _weekTotal => _collections
      .where((c) => _matchesPeriod(c, 'This Week'))
      .fold(0, (sum, c) => sum + _parseAmount(c['amount']!));

  int get _monthTotal => _collections
      .where((c) => _matchesPeriod(c, 'This Month'))
      .fold(0, (sum, c) => sum + _parseAmount(c['amount']!));

  String _fmt(int value) {
    final s = value.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final posFromEnd = s.length - i;
      buf.write(s[i]);
      if (posFromEnd > 3 && (posFromEnd - 3) % 2 == 0) buf.write(',');
    }
    return '₹$buf';
  }

  Map<String, List<LoanRecord>> get _loansByCustomerId {
    final byCustomerId = <String, List<LoanRecord>>{};
    for (final customer in _customers) {
      byCustomerId.putIfAbsent(customer.id, () => <LoanRecord>[]);
    }
    for (final loan in _allLoans) {
      final customer = _customers
          .where((item) =>
              item.id == loan.customerId ||
              item.customerId == loan.customerId ||
              item.fullName == loan.customerName)
          .firstOrNull;
      if (customer != null) {
        byCustomerId.putIfAbsent(customer.id, () => <LoanRecord>[]);
        byCustomerId[customer.id]!.add(loan);
        continue;
      }
      final customerId = loan.customerId;
      if (customerId != null && customerId.isNotEmpty) {
        byCustomerId.putIfAbsent(customerId, () => <LoanRecord>[]);
        byCustomerId[customerId]!.add(loan);
      }
    }
    for (final entry in byCustomerId.entries) {
      entry.value.sort((a, b) => a.loanNumber.compareTo(b.loanNumber));
    }
    return byCustomerId;
  }

  void _showAddCollectionDialog() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddCollectionDialog(
          customers: _customers,
          loansByCustomer: _loansByCustomerId,
          agents: _agentNames,
          schedulesByLoan: _schedulesByLoan,
          onSaved: (record) => _createCollectionOnBackend(record),
        ),
      ),
    );
  }

  void _showEditCollectionDialog(Map<String, String> record) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddCollectionDialog(
          customers: _customers,
          loansByCustomer: _loansByCustomerId,
          agents: _agentNames,
          schedulesByLoan: _schedulesByLoan,
          existing: record,
          onSaved: (updated) => _updateCollectionOnBackend(record, updated),
        ),
      ),
    );
  }

  // NEW: build the JSON payload the CollectionController expects and POST it
  Future<void> _createCollectionOnBackend(Map<String, String> record) async {
    final l10n = AppLocalizations.of(context);
    try {
      final payload = {
        'receipt_number': record['receipt'],
        'customer_id': record['customer_id'],
        'customer_name': record['customer'],
        'loan_id': record['loan_id'],
        'loan_number': record['loan'] == '-' ? null : record['loan'],
        'loan_type': record['loan_type'] == '-' ? null : record['loan_type'],
        'collection_amount': _parseAmount(record['amount'] ?? '0'),
        'penalty_amount': _parseAmount(record['penalty_amount'] ?? '0'),
        'payment_method': _apiMethodValue(record['method'] ?? 'Cash'),
        'collection_date': _toIsoDate(record['date']),
        'agent_id': record['agent_id'],
        'agent_name': record['agent'],
        'notes': record['notes'],
        if (record['payment_screenshot'] != null)
          'payment_screenshot': record['payment_screenshot'],
        if (record['customer_signature'] != null)
          'customer_signature': record['customer_signature'],
      };
      await CollectionApiService.createCollection(payload);
      await _loadCollections(); // refresh from source of truth
      ToastService.show(
        title: l10n.collectionsRecordedTitle,
        message: record['customer'] ?? '',
        type: ToastType.success,
      );
    } catch (e) {
      ToastService.show(
        title: l10n.collectionsSaveFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  // NEW: PATCH by real id (looked up via receipt number)
  Future<void> _updateCollectionOnBackend(
      Map<String, String> original, Map<String, String> updated) async {
    final l10n = AppLocalizations.of(context);
    final id = original['id'];
    if (id == null || id.isEmpty) {
      ToastService.show(
        title: l10n.collectionsUpdateFailedTitle,
        message: l10n.collectionsRecordIdNotFound,
        type: ToastType.error,
      );
      return;
    }
    try {
      final payload = {
        'receipt_number': updated['receipt'],
        'customer_id': updated['customer_id'],
        'customer_name': updated['customer'],
        'loan_id': updated['loan_id'],
        'loan_number': updated['loan'] == '-' ? null : updated['loan'],
        'loan_type': updated['loan_type'] == '-' ? null : updated['loan_type'],
        'collection_amount': _parseAmount(updated['amount'] ?? '0'),
        // Only re-split an edited receipt when a preset was tapped.
        if (updated['penalty_amount'] != null)
          'penalty_amount': _parseAmount(updated['penalty_amount']!),
        'payment_method': _apiMethodValue(updated['method'] ?? 'Cash'),
        'collection_date': _toIsoDate(updated['date']),
        'agent_id': updated['agent_id'],
        'agent_name': updated['agent'],
        'notes': updated['notes'],
        if (updated['payment_screenshot'] != null)
          'payment_screenshot': updated['payment_screenshot'],
        if (updated['customer_signature'] != null)
          'customer_signature': updated['customer_signature'],
      };
      await CollectionApiService.updateCollection(id, payload);
      await _loadCollections();
      ToastService.show(
        title: l10n.collectionsUpdatedTitle,
        message: updated['customer'] ?? '',
        type: ToastType.success,
      );
    } catch (e) {
      ToastService.show(
        title: l10n.collectionsUpdateApiFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  String? _toIsoDate(String? uiDate) {
    final dt = _parseDate(uiDate ?? '');
    if (dt == null) return null;
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  void _showDeleteConfirmDialog(Map<String, String> record) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: l10n.collectionsDeleteTitle,
      message: l10n.collectionsDeleteMessage(
          record['customer'] ?? '', record['receipt'] ?? ''),
      confirmLabel: l10n.collectionsActionDelete,
      confirmButtonColor: AppColors.kDanger,
    );

    if (confirmed == true && mounted) {
      final id = record['id'];
      if (id == null || id.isEmpty) {
        ToastService.show(
          title: l10n.collectionsDeleteFailedTitle,
          message: l10n.collectionsRecordIdNotFound,
          type: ToastType.error,
        );
        return;
      }
      try {
        await CollectionApiService.deleteCollection(id);
        await _loadCollections();
        ToastService.show(
          title: l10n.collectionsDeletedTitle,
          message: record['receipt'],
          type: ToastType.success,
        );
      } catch (e) {
        ToastService.show(
          title: l10n.collectionsDeleteApiFailedTitle,
          message: e.toString(),
          type: ToastType.error,
        );
      }
    }
  }

  bool _isToday(Map<String, String> row) {
    final date = _parseDate(row['date'] ?? '');
    final now = DateTime.now();
    return date != null &&
        date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  /// "To Collect Today", built from the loans, schedules and today's
  /// receipts this screen already loaded — same rule as the web app.
  DueTodaySheet get _dueSheet {
    final collectedToday = <String, double>{};
    for (final row in _collections.where(_isToday)) {
      final loanId = row['loan_id'] ?? '';
      if (loanId.isEmpty) continue;
      collectedToday[loanId] = (collectedToday[loanId] ?? 0) +
          _parseAmount(row['amount'] ?? '0');
    }
    return DueTodaySheet.build(
      loans: _allLoans,
      schedules: _openDueRows,
      collectedTodayByLoan: collectedToday,
    );
  }

  /// The collect sheet works on a loan's open instalments, so each line is
  /// paired with that loan's group.
  AgentCustomerGroup? _groupForLoan(String loanId) {
    for (final g in _collectionGroups) {
      if (g.loanId == loanId) return g;
    }
    return null;
  }

  void _showCollectPaymentSheet(AgentCustomerGroup group) {
    final overdueItems = group.payableDueItems;
    final hasPayableDue = overdueItems.isNotEmpty;
    final dueAmount = hasPayableDue ? group.overdueDueAmount : group.totalDue;
    final dueCount = hasPayableDue ? group.overdueDueCount : group.items.length;
    final isMonthlyInterest =
        group.collectionType == LoanCollectionType.monthlyInterest;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => CollectPaymentSheet(
        customerName: group.customerName,
        loanCollectionType: group.collectionType,
        subtitleLabel:
            isMonthlyInterest ? 'Monthly Interest Loan' : 'Due Amount',
        subtitleValue: isMonthlyInterest
            ? (group.loanNumbers.isNotEmpty
                ? group.loanNumbers.first
                : group.loanId)
            : AgentCollectionItem.formatAmount(dueAmount),
        prefillAmount: dueAmount,
        installmentAmount:
            group.items.isNotEmpty ? group.items.first.installmentAmount : null,
        dueAmount: dueAmount,
        penaltyAmount: group.totalPenalty,
        outstandingBalance: group.totalOutstanding,
        dueCount: dueCount,
        onSubmit: (amount, method, date, notes, paymentType, penalty) =>
            _collectAdminPayment(
                group, amount, method, date, notes, paymentType, penalty),
      ),
    );
  }

  Future<void> _collectAdminPayment(
    AgentCustomerGroup group,
    double amount,
    String method,
    DateTime date,
    String? notes,
    String paymentType,
    double penaltyAmount,
  ) async {
    final l10n = AppLocalizations.of(context);
    try {
      final createdCount = await AgentCollectionApiService.collectForCustomer(
        group: group,
        amount: amount,
        paymentMethod: method,
        collectionDate: date,
        notes: notes,
        paymentType: paymentType,
        penaltyAmount: penaltyAmount,
      );
      if (!mounted) return;
      ToastService.show(
        title: l10n.collectionsRecordedTitle,
        message:
            '${group.customerName} • $createdCount installment(s) recorded',
        type: ToastType.success,
      );
      await _loadCollections();
    } catch (e) {
      ToastService.show(
        title: l10n.collectionsSaveFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Widget _buildToCollectToday(bool isNarrow) {
    final sheet = _dueSheet;
    final lines = sheet.lines;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.kBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text('To Collect Today',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                Text(AgentCollectionItem.formatAmount(sheet.remaining),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${sheet.customers} customer${sheet.customers == 1 ? '' : 's'} • '
              '${AgentCollectionItem.formatAmount(sheet.overdueTotal)} in arrears'
              '${sheet.settled > 0 ? ' • ${sheet.settled} settled' : ''}',
              style: const TextStyle(color: AppColors.kTextMuted),
            ),
            if (lines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No pending collections',
                      style: TextStyle(color: AppColors.kTextMuted)),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              ...lines.map(_buildToCollectRow),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToCollectRow(DueTodayLine line) {
    final group = _groupForLoan(line.loanId);
    final statusParts = <String>[];
    if (line.settled) {
      statusParts.add('Paid today');
    } else {
      if (line.overdueCount > 0) {
        statusParts.add('Overdue - ${line.overdueCount}');
      }
      if (line.dueTodayCount > 0) {
        statusParts.add('Today - ${line.dueTodayCount}');
      }
    }
    final status = statusParts.join(' • ');
    final hasOverdue = line.overdueCount > 0;
    final statusColor = line.settled
        ? AppColors.kSuccess
        : hasOverdue
            ? AppColors.kDanger
            : AppColors.kWarning;
    final scheduleDates = (group?.payableDueItems ?? const [])
        .map((item) => item.dueDate)
        .whereType<DateTime>()
        .map(AgentCollectionItem.formatDate)
        .toSet()
        .toList();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(
          color: hasOverdue
              ? AppColors.kDanger.withValues(alpha: 0.25)
              : AppColors.kBorder,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: const Color(0xFFB38222),
            child: Text(_initials(line.customerName),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.customerName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  [
                    line.loanNumber,
                    if (group != null) group.displayLoanType,
                  ].join(' • '),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.kTextMuted),
                ),
                const SizedBox(height: 5),
                Text(status,
                    style: TextStyle(fontSize: 12, color: statusColor)),
                if (scheduleDates.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    scheduleDates.length == 1
                        ? 'Schedule date: ${scheduleDates.first}'
                        : 'Schedule dates: ${scheduleDates.join(', ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.kTextMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                AgentCollectionItem.formatAmount(line.remaining),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 7),
              ElevatedButton(
                onPressed: group == null || line.settled
                    ? null
                    : () => _showCollectPaymentSheet(group),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFA9791F),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 36),
                ),
                child: const Text('Collect'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTodaysCollections(bool isNarrow) {
    final rows = _collections.where(_isToday).toList();
    // Same grouping as the web app: by the collecting agent's id, named from
    // their profile, else the name on the receipt, else "Recorded directly".
    final byAgentKey = <String, List<Map<String, String>>>{};
    final agentLabel = <String, String>{};
    for (final row in rows) {
      final agentId = row['agent_id'] ?? '';
      final key = agentId.isEmpty ? '\u0000none' : agentId;
      byAgentKey.putIfAbsent(key, () => []).add(row);
      final receiptName = (row['agent'] ?? '').trim();
      agentLabel[key] = _agentNameById[agentId] ??
          (receiptName.isNotEmpty && receiptName != 'Unassigned'
              ? receiptName
              : 'Recorded directly');
    }
    double sumOf(List<Map<String, String>> list) => list.fold<double>(
        0, (sum, row) => sum + _parseAmount(row['amount'] ?? '0'));
    final sortedKeys = byAgentKey.keys.toList()
      ..sort((a, b) {
        final byAmount = sumOf(byAgentKey[b]!).compareTo(sumOf(byAgentKey[a]!));
        return byAmount != 0
            ? byAmount
            : agentLabel[a]!.compareTo(agentLabel[b]!);
      });
    final byAgent = <String, List<Map<String, String>>>{
      for (final key in sortedKeys) agentLabel[key]!: byAgentKey[key]!,
    };
    final total = sumOf(rows);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.kBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text("Today's Collections",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                Text(AgentCollectionItem.formatAmount(total),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${rows.length} receipt${rows.length == 1 ? '' : 's'} • '
              '${byAgent.length} collector${byAgent.length == 1 ? '' : 's'}',
              style: const TextStyle(color: AppColors.kTextMuted),
            ),
            if (byAgent.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No collections recorded today',
                      style: TextStyle(color: AppColors.kTextMuted)),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              ...byAgent.entries.map((entry) {
                final agentTotal = entry.value.fold<double>(
                    0, (sum, row) => sum + _parseAmount(row['amount']!));
                return Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.kBorder),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: const Color(0xFFB38222),
                        child: Text(_initials(entry.key),
                            style: const TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${entry.key}\n${entry.value.length} receipt${entry.value.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.kTextMuted),
                        ),
                      ),
                      Text(AgentCollectionItem.formatAmount(agentTotal),
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return AppShell(
      currentRoute: AppRoutes.collections,
      title: l10n.collectionsTitle,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.collectionsLoadFailedTitle,
                          style: TextStyle(color: scheme.error)),
                      const SizedBox(height: 8),
                      Text(_loadError!,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadCollections,
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 700;
                    return RefreshIndicator(
                      onRefresh: _loadCollections,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            PageHeader(
                              title: l10n.collectionsTitle,
                              subtitle: l10n.collectionsSubtitle,
                              actions: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width: 160,
                                    child: ElevatedButton.icon(
                                      onPressed: _showAddCollectionDialog,
                                      icon: const Icon(Icons.add),
                                      label: Text(l10n.collectionsAddButton),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            _buildStatCards(isNarrow, l10n),
                            const SizedBox(height: 16),
                            _buildToCollectToday(isNarrow),
                            const SizedBox(height: 16),
                            _buildTodaysCollections(isNarrow),
                            const SizedBox(height: 16),
                            _buildSearchAndFilters(l10n),
                            const SizedBox(height: 8),
                            _buildCollectionsTable(isNarrow, l10n),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildStatCards(bool isNarrow, AppLocalizations l10n) {
    final cards = [
      _StatCardData(
        label: l10n.collectionsStatTodayTotal,
        value: _fmt(_todayTotal),
        icon: Icons.account_balance_wallet_outlined,
        iconColor: AppColors.kSuccess,
        iconBg: const Color(0xFFE7F7EE),
      ),
      _StatCardData(
        label: l10n.collectionsStatThisWeek,
        value: _fmt(_weekTotal),
        icon: Icons.currency_rupee,
        iconColor: AppColors.kInfo,
        iconBg: const Color(0xFFEAF1FF),
      ),
      _StatCardData(
        label: l10n.collectionsStatThisMonth,
        value: _fmt(_monthTotal),
        icon: Icons.description_outlined,
        iconColor: const Color(0xFF7C3AED),
        iconBg: const Color(0xFFF1EAFE),
      ),
      _StatCardData(
        label: l10n.collectionsStatTotalRecords,
        value: '${_collections.length}',
        icon: Icons.check_circle_outline,
        iconColor: AppColors.kWarning,
        iconBg: const Color(0xFFFFF3DC),
      ),
    ];

    return Padding(
      padding:
          EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 24, vertical: 8),
      child: ResponsiveStatGrid(
        children: cards.map((c) => _StatCard(data: c)).toList(),
      ),
    );
  }

  Widget _buildSearchAndFilters(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.kBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.collectionsSearchHint,
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            _buildPeriodSelector(l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodSelector(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.kBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: _periods.map((p) {
          final selected = _period == p;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _period = p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? AppColors.kSurface : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 4,
                              offset: const Offset(0, 1))
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  localizedPeriodLabel(p, l10n),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.kInfo : AppColors.kTextMuted,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCollectionsTable(bool isNarrow, AppLocalizations l10n) {
    final allItems = _filtered;
    // Show only 6 items unless _showAll is expanded
    final items = _showAll ? allItems : allItems.take(6).toList();

    final table = DataTable(
      dataRowMinHeight: 60,
      dataRowMaxHeight: 70,
      headingTextStyle: const TextStyle(
        color: AppColors.kTextMuted,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
      dataTextStyle: const TextStyle(
        fontSize: 14,
        color: AppColors.kTextDark,
      ),
      dividerThickness: 0,
      columns: [
        DataColumn(label: Text(l10n.collectionsColCustomer)),
        DataColumn(label: Text(l10n.collectionsColLoanNumber)),
        DataColumn(label: Text(l10n.collectionsColAmount)),
        DataColumn(label: Text(l10n.collectionsColMethod)),
        DataColumn(label: Text(l10n.collectionsColDate)),
        DataColumn(label: Text(l10n.collectionsColAgent)),
        DataColumn(label: Text(l10n.collectionsColActions)),
      ],
      rows: items.map((c) {
        return DataRow(cells: [
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFFB38222),
                child: Text(
                  c['initials']!,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(c['customer']!,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(c['receipt']!,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.kTextMuted)),
                ],
              ),
            ],
          )),
          DataCell(Text(c['loan']!)),
          DataCell(Text(c['amount']!,
              style: const TextStyle(fontWeight: FontWeight.w700))),
          DataCell(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE4F0FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                localizedPaymentMethodLabel(c['method']!, l10n),
                style: const TextStyle(
                  color: Color(0xFF4A90E2),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          DataCell(Text(c['date']!)),
          DataCell(Text(c['agent']!)),
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                color: AppColors.kTextMuted,
                onPressed: () => _showEditCollectionDialog(c),
                tooltip: l10n.collectionsActionEdit,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppColors.kDanger,
                onPressed: () => _showDeleteConfirmDialog(c),
                tooltip: l10n.collectionsActionDelete,
              ),
            ],
          )),
        ]);
      }).toList(),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 24),
      child: allItems.isEmpty
          ? Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: AppColors.kSurface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.kBorder),
              ),
              child: Center(
                child: Text(l10n.collectionsNoneFound,
                    style: const TextStyle(color: AppColors.kTextMuted)),
              ),
            )
          : Column(
              children: [
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  color: AppColors.kSurface,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: AppColors.kBorder),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Scrollbar(
                      thumbVisibility: true,
                      trackVisibility: true,
                      notificationPredicate: (notification) =>
                          notification.depth == 0,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 900),
                          child: SingleChildScrollView(
                            child: table,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Show More / Show Less Button
                if (allItems.length > 6)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _showAll = !_showAll;
                          });
                        },
                        icon: Icon(
                          _showAll
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          color: AppColors.kInfo,
                        ),
                        label: Text(
                          _showAll
                              ? l10n.collectionsShowLess
                              : l10n.collectionsShowMore(allItems.length - 6),
                          style: const TextStyle(
                            color: AppColors.kInfo,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _StatCardData {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final Color iconBg;

  _StatCardData({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
    required this.iconBg,
  });
}

class _StatCard extends StatelessWidget {
  final _StatCardData data;
  const _StatCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Row: Number (Starting) and Icon (End)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Value / Number -> Starting, Top
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    data.value,
                    maxLines: 1,
                    style: const TextStyle(
                      color: AppColors.kTextDark,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Icon -> End, Top
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: data.iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(data.icon, color: data.iconColor, size: 18),
              ),
            ],
          ),

          const Spacer(), // Pushes text label to the bottom

          // Bottom Section: Text Label -> Starting, Down
          Text(
            data.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.kTextMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// ADD / EDIT COLLECTION SHEET (Removed Dialog Wrapping)
// ==========================================
class AddCollectionDialog extends StatefulWidget {
  final List<Customer> customers;
  final Map<String, List<LoanRecord>> loansByCustomer;
  final List<String> agents;
  final Map<String, List<RepaymentInstallment>> schedulesByLoan;
  final ValueChanged<Map<String, String>>? onSaved;
  final Map<String, String>? existing;

  const AddCollectionDialog({
    super.key,
    this.customers = const [],
    this.loansByCustomer = const {},
    this.agents = const [],
    this.schedulesByLoan = const {},
    this.onSaved,
    this.existing,
  });

  @override
  State<AddCollectionDialog> createState() => _AddCollectionDialogState();
}

class _AddCollectionDialogState extends State<AddCollectionDialog> {
  static const List<String> _paymentMethods = [
    'Cash',
    'UPI',
    'Bank Transfer',
    'Cheque'
  ];
  bool get _isEdit => widget.existing != null;

  String? _customerId;
  // Customer picker search: name, mobile, customer ID or loan number.
  final TextEditingController _customerSearchController =
      TextEditingController();
  String _customerQuery = '';
  String? _loanNumber;
  final TextEditingController _amountController = TextEditingController();
  String _paymentMethod = 'Cash';
  final TextEditingController _dateController = TextEditingController();
  String? _agent;
  String? _paymentPurpose;
  // Penalty included in the preset last tapped (₹0 for "1 EMI"). Null until
  // a preset is tapped, so editing an old receipt leaves its split alone.
  double? _presetPenalty;
  final TextEditingController _notesController = TextEditingController();
  String? _screenshotFileName;
  String? _signatureFileName;
  XFile? _screenshotFile;
  XFile? _signatureFile;

  Customer? get _selectedCustomer {
    for (final customer in widget.customers) {
      if (customer.id == _customerId) return customer;
    }
    return null;
  }

  List<LoanRecord> get _availableLoans => _customerId == null
      ? const []
      : (widget.loansByCustomer[_customerId] ?? const []);

  LoanRecord? get _selectedLoan {
    for (final loan in _availableLoans) {
      if (loan.loanNumber == _loanNumber) return loan;
    }
    return null;
  }

  List<RepaymentInstallment> _scheduleFor(LoanRecord loan) =>
      widget.schedulesByLoan[loan.id] ?? const [];

  List<RepaymentInstallment> _unpaidScheduleFor(LoanRecord loan) =>
      _scheduleFor(loan)
          .where((item) => item.balance > 0 || item.status != 'paid')
          .toList();

  double _nextInstallmentAmount(LoanRecord loan) {
    final unpaid = _unpaidScheduleFor(loan);
    return unpaid.isNotEmpty ? unpaid.first.balance : loan.emiAmount;
  }

  Iterable<RepaymentInstallment> _overdueScheduleFor(LoanRecord loan) {
    final now = DateTime.now();
    return _unpaidScheduleFor(loan).where((item) {
      final dueDate = item.dueDate;
      return item.status.toLowerCase() == 'overdue' ||
          (dueDate != null && dueDate.isBefore(now));
    });
  }

  double _overdueDueAmount(LoanRecord loan) => _overdueScheduleFor(loan)
      .fold<double>(0, (total, item) => total + item.balance + item.penaltyAmount);

  double _overduePenalty(LoanRecord loan) => _overdueScheduleFor(loan)
      .fold<double>(0, (total, item) => total + item.penaltyAmount);

  double _totalPenalty(LoanRecord loan) {
    final schedule = _scheduleFor(loan);
    if (schedule.isEmpty) return loan.penaltyAmount;
    return schedule.fold<double>(0, (total, item) => total + item.penaltyAmount);
  }

  /// How much of [amount] is penalty. The backend keeps this part off the
  /// instalments and settles it against the loan's penalty, so collecting
  /// ₹50 of a ₹100 penalty leaves ₹50 penalty and the EMIs untouched.
  double _penaltyPortion(double amount) {
    final penalty = _presetPenalty ?? 0;
    return penalty <= 0 ? 0 : (amount < penalty ? amount : penalty);
  }

  double _fullBalance(LoanRecord loan) {
    final schedule = _scheduleFor(loan);
    if (schedule.isEmpty) return loan.outstandingBalance + loan.penaltyAmount;
    return schedule.fold<double>(
        0, (total, item) => total + item.balance + item.penaltyAmount);
  }

  String get _customerName => _selectedCustomer?.fullName ?? '';

  bool get _canSave =>
      _customerId != null &&
      _amountController.text.trim().isNotEmpty &&
      (int.tryParse(_amountController.text.trim()) ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _dateController.text =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final e = widget.existing;
    if (e != null) {
      final existingCustomerId = e['customer_id'];
      if (existingCustomerId != null && existingCustomerId.isNotEmpty) {
        final match = widget.customers
            .where((c) => c.id == existingCustomerId)
            .firstOrNull;
        if (match != null) _customerId = match.id;
      }
      if (_customerId == null) {
        for (final customer in widget.customers) {
          if (customer.fullName == e['customer']) {
            _customerId = customer.id;
            break;
          }
        }
      }
      _loanNumber = (e['loan'] != null && e['loan'] != '-') ? e['loan'] : null;
      _amountController.text = _parseAmount(e['amount'] ?? '').toString();
      _paymentMethod = e['method'] ?? 'Cash';
      _dateController.text = e['date'] ?? _dateController.text;
      _agent = e['agent'];
      _notesController.text = e['notes'] ?? '';
    }
  }

  int _parseAmount(String amount) =>
      int.tryParse(amount.replaceAll(RegExp(r'[₹,]'), '')) ?? 0;

  @override
  void dispose() {
    _customerSearchController.dispose();
    _amountController.dispose();
    _dateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final l10n = AppLocalizations.of(context);
    final customer = _selectedCustomer;
    if (customer == null) {
      ToastService.show(
        title: l10n.collectionsSelectCustomerTitle,
        message: l10n.collectionsSelectCustomerMessage,
        type: ToastType.error,
      );
      return;
    }
    final amountValue = int.tryParse(_amountController.text.trim()) ?? 0;
    final selectedDate = _dateController.text.isEmpty
        ? _formatCurrentDate()
        : _dateController.text;

    final screenshotBase64 = _screenshotFile != null
        ? base64Encode(await _screenshotFile!.readAsBytes())
        : null;
    final signatureBase64 = _signatureFile != null
        ? base64Encode(await _signatureFile!.readAsBytes())
        : null;

    final record = <String, String>{
      'customer_id': customer.id,
      'customer': _customerName,
      'initials': _initials(_customerName),
      'receipt': _isEdit
          ? widget.existing!['receipt']!
          : 'RCP-${(DateTime.now().millisecondsSinceEpoch % 100000000).toString().padLeft(8, '0')}',
      if (_isEdit && widget.existing!['id'] != null)
        'id': widget.existing!['id']!,
      'loan': _loanNumber ?? '-',
      if (_selectedLoan != null) ...{
        'loan_id': _selectedLoan!.id,
        'loan_type': _selectedLoan!.collectionType.toLowerCase(),
      },
      'amount':
          '₹${amountValue.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}',
      'date': selectedDate,
      'method': _paymentMethod,
      'agent': _agent ?? 'Unassigned',
      if (_selectedLoan?.agentId != null) 'agent_id': _selectedLoan!.agentId!,
      'status': _isEdit ? widget.existing!['status']! : 'Collected',
      if (_presetPenalty != null)
        'penalty_amount':
            _penaltyPortion(amountValue.toDouble()).round().toString(),
      'notes': [
        if (_paymentPurpose != null) _paymentPurpose!,
        if (_notesController.text.trim().isNotEmpty)
          _notesController.text.trim(),
      ].join(' | '),
      if (screenshotBase64 != null) 'payment_screenshot': screenshotBase64,
      if (signatureBase64 != null) 'customer_signature': signatureBase64,
    };
    if (!mounted) return;
    widget.onSaved?.call(record);
    Navigator.of(context).pop();
    ToastService.show(
      title: _isEdit
          ? l10n.collectionsUpdatedTitle
          : l10n.collectionsRecordedTitle,
      message: record['customer'],
      type: ToastType.success,
    );
  }

  String _formatCurrentDate() {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
  }

  Future<void> _pickFile({required bool isSignature}) async {
    final l10n = AppLocalizations.of(context);
    final XFile? picked = await AppUpload.showImagePickerModal(
      context,
      title: isSignature
          ? l10n.collectionsUploadSignatureTitle
          : l10n.collectionsUploadScreenshotTitle,
    );
    if (picked == null) return;
    setState(() {
      if (isSignature) {
        _signatureFile = picked;
        _signatureFileName = picked.name;
      } else {
        _screenshotFile = picked;
        _screenshotFileName = picked.name;
      }
    });
  }

  Future<void> _selectCollectionDate() async {
    final current =
        _parseCollectionDate(_dateController.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _dateController.text =
          '${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year}';
    });
  }

  DateTime? _parseCollectionDate(String value) {
    final iso = DateTime.tryParse(value);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);
    final slash = value.split('/');
    if (slash.length == 3) {
      final day = int.tryParse(slash[0]);
      final month = int.tryParse(slash[1]);
      final year = int.tryParse(slash[2]);
      if (day != null && month != null && year != null) {
        return DateTime(year, month, day);
      }
    }
    const months = {
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final parts = value.split(' ');
    if (parts.length == 3) {
      final day = int.tryParse(parts[0]);
      final month = months[parts[1]];
      final year = int.tryParse(parts[2]);
      if (day != null && month != null && year != null) {
        return DateTime(year, month, day);
      }
    }
    return null;
  }

  void _setAmountWithPurpose(double amount, String? purpose,
      {double penalty = 0}) {
    _amountController.text = amount.round().toString();
    _paymentPurpose = purpose;
    _presetPenalty = penalty;
    _amountController.selection = TextSelection.fromPosition(
      TextPosition(offset: _amountController.text.length),
    );
    setState(() {});
  }

  /// The label half of a "Label: {amount}" summary string, so the label and
  /// value can be styled separately without new translation keys.
  String _summaryLabel(String Function(String) message) =>
      message('').replaceAll(RegExp(r'[:\s]+$'), '');

  Color _statusColor(String status) {
    final s = status.toLowerCase();
    if (s.contains('overdue') || s.contains('default')) {
      return AppColors.gold800;
    }
    return AppColors.kGold;
  }

  Widget _buildLoanSummary(LoanRecord loan, AppLocalizations l10n) {
    final totalDue = _fullBalance(loan);
    final overdueDue = _overdueDueAmount(loan);
    final statusColor = _statusColor(loan.status);

    Widget metric(String label, String value, IconData icon, {Color? accent}) {
      final color = accent ?? AppColors.gold900;
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: accent != null
              ? accent.withValues(alpha: 0.06)
              : AppColors.kSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: accent != null
                  ? accent.withValues(alpha: 0.25)
                  : AppColors.gold200),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: (accent ?? AppColors.kGold).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 14, color: accent ?? AppColors.kGold),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.gold700)),
                  const SizedBox(height: 2),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final metrics = [
      metric(_summaryLabel(l10n.collectionsSummaryPrincipal),
          loan.formattedAmount, Icons.account_balance_wallet_outlined),
      metric(
          _summaryLabel(l10n.collectionsSummaryInstallment),
          LoanRecord.formatRupees(_nextInstallmentAmount(loan)),
          Icons.event_repeat_outlined),
      metric(_summaryLabel(l10n.collectionsSummaryOutstanding),
          loan.formattedOutstanding, Icons.hourglass_bottom_outlined),
      metric(_summaryLabel(l10n.collectionsSummaryOverdueDue),
          LoanRecord.formatRupees(overdueDue), Icons.warning_amber_outlined,
          accent: overdueDue > 0 ? AppColors.gold700 : null),
      metric(_summaryLabel(l10n.collectionsSummaryPenalty),
          loan.formattedPenalty, Icons.gavel_outlined,
          accent: loan.penaltyAmount > 0 ? AppColors.gold700 : null),
    ];

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gold200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: collection type, status and agent.
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.gold50, AppColors.gold100],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.receipt_long_outlined,
                    size: 18, color: AppColors.kGoldDark),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(friendlyCollectionTypeLabel(loan, l10n),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.gold900)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(localizedStatusLabel(loan.status, l10n),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: statusColor)),
                ),
                const Spacer(),
                const Icon(Icons.person_outline,
                    size: 16, color: AppColors.gold700),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(loan.agentName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.gold800)),
                ),
              ],
            ),
          ),
          // Body: two-column metric tiles.
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(builder: (context, constraints) {
              const gap = 8.0;
              final tileWidth = (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final tile in metrics)
                    SizedBox(width: tileWidth, child: tile),
                ],
              );
            }),
          ),
          // Footer: total due.
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.gold500, AppColors.gold700],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(_summaryLabel(l10n.collectionsSummaryTotalDue),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ),
                Text(LoanRecord.formatRupees(totalDue),
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountPresets(LoanRecord loan, AppLocalizations l10n) {
    final installment = _nextInstallmentAmount(loan);
    final principalPartPayment = loan.outstandingBalance;
    final fullBalance = _fullBalance(loan);
    final overdueDue = _overdueDueAmount(loan);
    final isInterestOnly = collectionTypeOptionKey(loan) == 'Monthly Interest';
    final entered = _parseAmount(_amountController.text).toDouble();
    final isPenaltyPayment =
        _paymentPurpose == AgentCollectionApiService.penaltyNote;
    final remaining =
        (fullBalance - entered).clamp(0, double.infinity).toDouble();
    final penaltyRemaining = (loan.penaltyAmount - _penaltyPortion(entered))
        .clamp(0, double.infinity)
        .toDouble();

    Widget preset(String label, double amount, IconData icon, Color color,
        [String? purpose, double penalty = 0]) {
      // A labelled preset stays selected when the amount is edited, so
      // typing ₹50 after tapping Penalty is still a penalty payment.
      final selected = entered > 0 &&
          _paymentPurpose == purpose &&
          (purpose != null || entered == amount.roundToDouble());
      return Material(
        color: selected ? color.withValues(alpha: 0.10) : AppColors.kSurface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () =>
              _setAmountWithPurpose(amount, purpose, penalty: penalty),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? color : AppColors.gold200,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.gold700)),
                      const SizedBox(height: 2),
                      Text(LoanRecord.formatRupees(amount),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: selected ? color : AppColors.gold900)),
                    ],
                  ),
                ),
                if (selected) Icon(Icons.check_circle, size: 16, color: color),
              ],
            ),
          ),
        ),
      );
    }

    final presets = [
      preset(
        isInterestOnly
            ? l10n.collectionsPresetFillInterest
            : l10n.collectionsPresetOneEmi,
        installment,
        Icons.bolt,
        AppColors.kGold,
        isInterestOnly ? l10n.collectionsPurposeMonthlyInterest : null,
      ),
      if (overdueDue > 0)
        preset(l10n.collectionsPresetPayDue, overdueDue,
            Icons.warning_amber_outlined, AppColors.gold700, null,
            _overduePenalty(loan)),
      preset(
          l10n.collectionsPresetPrincipalPartPayment,
          principalPartPayment,
          Icons.payments_outlined,
          AppColors.kGoldDark,
          l10n.collectionsPresetPrincipalPartPayment),
      preset(l10n.collectionsPresetFullBalance, fullBalance,
          Icons.done_all_rounded, AppColors.gold700, null,
          _totalPenalty(loan)),
      // The penalty part is sent as `penalty_amount`, which is what keeps it
      // off the instalments. The note only labels the receipt, so it stays
      // untranslated.
      if (loan.penaltyAmount > 0)
        preset(
            l10n.collectionsPresetPenalty,
            loan.penaltyAmount,
            Icons.gavel_outlined,
            AppColors.gold800,
            AgentCollectionApiService.penaltyNote,
            loan.penaltyAmount),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          const gap = 8.0;
          final tileWidth = (constraints.maxWidth - gap) / 2;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final tile in presets)
                SizedBox(width: tileWidth, child: tile),
            ],
          );
        }),
        if (entered > 0) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.gold50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.gold200),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 14, color: AppColors.kGoldDark),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isPenaltyPayment
                        ? l10n.collectionsPenaltySummaryLine(
                            LoanRecord.formatRupees(entered),
                            LoanRecord.formatRupees(penaltyRemaining))
                        : l10n.collectionsPaymentSummaryLine(
                            LoanRecord.formatRupees(entered),
                            LoanRecord.formatRupees(remaining)),
                    style:
                        const TextStyle(fontSize: 12, color: AppColors.gold900),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Customers matching the search box by name, mobile, customer ID or any
  /// of their loan numbers. Names that start with the query rank first.
  List<Customer> get _matchingCustomers {
    final query = _customerQuery.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final digits = query.replaceAll(RegExp(r'\D'), '');

    bool matches(Customer customer) {
      if (customer.fullName.toLowerCase().contains(query)) return true;
      if (customer.customerId.toLowerCase().contains(query)) return true;
      final mobile = (customer.mobile ?? '').replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 3 && mobile.contains(digits)) return true;
      final loans = widget.loansByCustomer[customer.id] ?? const [];
      return loans.any((loan) => loan.loanNumber.toLowerCase().contains(query));
    }

    final results = widget.customers.where(matches).toList()
      ..sort((a, b) {
        final aStarts = a.fullName.toLowerCase().startsWith(query) ? 0 : 1;
        final bStarts = b.fullName.toLowerCase().startsWith(query) ? 0 : 1;
        if (aStarts != bStarts) return aStarts - bStarts;
        return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
      });
    return results;
  }

  void _selectCustomer(String? customerId) {
    FocusScope.of(context).unfocus();
    _customerSearchController.clear();
    setState(() {
      _customerQuery = '';
      _customerId = customerId;
      _loanNumber = null;
      _agent = null;
      _paymentPurpose = null;
      _presetPenalty = null;
      _amountController.clear();
    });
  }

  /// "RR007 • 98765 43210" style detail line for a customer.
  String _customerDetailLine(Customer customer) => [
        customer.customerId,
        customer.mobile ?? '',
      ].where((part) => part.trim().isNotEmpty).join(' • ');

  Widget _customerAvatar(Customer customer, {double radius = 18}) =>
      CircleAvatar(
        radius: radius,
        backgroundColor: AppColors.gold100,
        child: Text(
          _initials(customer.fullName.isEmpty ? '?' : customer.fullName),
          style: TextStyle(
              fontSize: radius * 0.72,
              fontWeight: FontWeight.w700,
              color: AppColors.gold800),
        ),
      );

  /// Search box for picking the customer. Typing lists the matching
  /// customers; tapping one selects it and shows it as a card with a
  /// "Change" action to search again.
  Widget _buildCustomerPicker(AppLocalizations l10n) {
    final selected = _selectedCustomer;
    if (selected != null) {
      final loanCount = widget.loansByCustomer[selected.id]?.length ?? 0;
      final detail = _customerDetailLine(selected);
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: AppColors.gold50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.gold200),
        ),
        child: Row(
          children: [
            _customerAvatar(selected, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(selected.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.kTextDark)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (detail.isNotEmpty) detail,
                      l10n.collectionsCustomerLoanCount(loanCount),
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.kTextMuted),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () => _selectCustomer(null),
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: Text(l10n.collectionsChangeCustomer),
              style: TextButton.styleFrom(foregroundColor: AppColors.kGold),
            ),
          ],
        ),
      );
    }

    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.kBorder),
    );
    final matches = _matchingCustomers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _customerSearchController,
          enabled: widget.customers.isNotEmpty,
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _customerQuery = v),
          onSubmitted: (_) {
            if (matches.length == 1) _selectCustomer(matches.first.id);
          },
          decoration: InputDecoration(
            isDense: true,
            hintText: l10n.collectionsCustomerSearchHint,
            hintMaxLines: 1,
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _customerQuery.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _customerSearchController.clear();
                      setState(() => _customerQuery = '');
                    },
                  ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            border: border,
            enabledBorder: border,
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.kGold, width: 1.4),
            ),
          ),
        ),
        if (_customerQuery.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              color: AppColors.kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.kBorder),
              boxShadow: [
                BoxShadow(
                  color: AppColors.ink900.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const Icon(Icons.person_search_outlined,
                            size: 18, color: AppColors.kTextMuted),
                        const SizedBox(width: 8),
                        Text(
                          l10n.collectionsCustomerNoMatches,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.kTextMuted),
                        ),
                      ],
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: matches.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppColors.kBorder),
                      itemBuilder: (context, i) {
                        final customer = matches[i];
                        final loanCount =
                            widget.loansByCustomer[customer.id]?.length ?? 0;
                        final detail = _customerDetailLine(customer);
                        return ListTile(
                          dense: true,
                          leading: _customerAvatar(customer),
                          title: Text(
                            customer.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.kTextDark),
                          ),
                          subtitle: detail.isEmpty
                              ? null
                              : Text(
                                  detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.kTextMuted),
                                ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: loanCount > 0
                                  ? AppColors.gold50
                                  : AppColors.ink50,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              l10n.collectionsCustomerLoanCount(loanCount),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: loanCount > 0
                                      ? AppColors.gold700
                                      : AppColors.kTextMuted),
                            ),
                          ),
                          onTap: () => _selectCustomer(customer.id),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final availableLoans = _availableLoans;
    final selectedLoan = _selectedLoan;

    InputDecoration _modernDecoration(
        {required String hint, IconData? iconData}) {
      return InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
        suffixIcon: iconData != null
            ? Icon(iconData, color: AppColors.kTextMuted, size: 20)
            : null,
        filled: true,
        fillColor: Colors.grey.shade50,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              BorderSide(color: Theme.of(context).primaryColor, width: 1.5),
        ),
      );
    }

    return AppShell(
      currentRoute: AppRoutes.collections,
      title: _isEdit ? l10n.collectionsEditTitle : l10n.collectionsAddButton,
      showBackButton: true,
      body: Container(
        color: Colors.white,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(l10n.collectionsCustomerRequiredLabel),
              _buildCustomerPicker(l10n),
              const SizedBox(height: 16),

              _label(l10n.collectionsLoanNumberLabel),
              DropdownButtonFormField<String>(
                key: ValueKey('loan-$_customerId'),
                isExpanded: true,
                initialValue: _loanNumber,
                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: AppColors.kTextMuted),
                decoration: _modernDecoration(
                  hint: _customerId == null
                      ? l10n.collectionsSelectCustomerFirstHint
                      : l10n.collectionsSelectLoanHint,
                  iconData: Icons.account_balance_wallet_outlined,
                ),
                items: availableLoans
                    .map((loan) => DropdownMenuItem(
                          value: loan.loanNumber,
                          child: Text(
                            '${loan.loanNumber} • ${LoanRecord.formatRupees(loan.principalAmount)}\n'
                            '${friendlyCollectionTypeLabel(loan, l10n)}: ${LoanRecord.formatRupees(loan.emiAmount)} • '
                            '${l10n.collectionsOutstandingAbbrev}: ${loan.formattedOutstandingWithPenalty} '
                            '(${localizedStatusLabel(loan.status, l10n)})',
                            style: const TextStyle(fontSize: 13, height: 1.4),
                          ),
                        ))
                    .toList(),
                onChanged: _customerId == null
                    ? null
                    : (v) => setState(() {
                          _loanNumber = v;
                          _agent = _selectedLoan?.agentName;
                          // A preset belongs to the loan it was tapped on.
                          _paymentPurpose = null;
                          _presetPenalty = null;
                        }),
              ),

              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 12),
                child: Text(
                  selectedLoan == null
                      ? l10n.collectionsSelectLoanPrompt
                      : l10n.collectionsLoansLinkedCount(availableLoans.length),
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic),
                ),
              ),

              if (selectedLoan != null) ...[
                _buildLoanSummary(selectedLoan, l10n),
                const SizedBox(height: 16),
                _buildAmountPresets(selectedLoan, l10n),
                const SizedBox(height: 16),
              ],

              _label(l10n.collectionsAmountReceivedLabel),
              // Hero Amount Field (Colorful & Large)
              TextField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppColors.kTextDark),
                decoration: InputDecoration(
                  prefixText: '₹  ',
                  prefixStyle: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54),
                  hintText: '0',
                  filled: true,
                  fillColor:
                      AppColors.kSuccess.withOpacity(0.08), // Light green tint
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                          color: AppColors.kSuccess.withOpacity(0.3))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                          color: AppColors.kSuccess, width: 2)),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 20),

              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _label(l10n.collectionsPaymentMethodLabel),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _paymentMethod,
                          icon: const Icon(Icons.payment_rounded,
                              size: 20, color: AppColors.kTextMuted),
                          decoration: _modernDecoration(hint: ''),
                          items: _paymentMethods
                              .map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(
                                      localizedPaymentMethodLabel(m, l10n))))
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _paymentMethod = v ?? 'Cash'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _label(l10n.collectionsCollectionDateLabel),
                        TextField(
                          controller: _dateController,
                          readOnly: true,
                          onTap: _selectCollectionDate,
                          decoration: _modernDecoration(
                            hint: '',
                            iconData: Icons.calendar_month_rounded,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _label(l10n.collectionsColAgent),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _agent,
                icon: const Icon(Icons.person_outline,
                    color: AppColors.kTextMuted),
                decoration:
                    _modernDecoration(hint: l10n.collectionsSelectAgentHint),
                items: {
                  ...widget.agents,
                  'Unassigned',
                  if (selectedLoan?.agentName.isNotEmpty == true)
                    selectedLoan!.agentName,
                }
                    .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                    .toList(),
                onChanged: (v) => setState(() => _agent = v),
              ),
              const SizedBox(height: 16),

              _label(l10n.collectionsNotesLabel),
              TextField(
                controller: _notesController,
                maxLines: 3,
                decoration: _modernDecoration(hint: l10n.collectionsNotesHint),
              ),
              const SizedBox(height: 20),

              // Upload Boxes
              _label(l10n.collectionsPaymentScreenshotLabel),
              _UploadBox(
                fileName: _screenshotFileName,
                onTap: () => _pickFile(isSignature: false),
              ),
              const SizedBox(height: 16),

              _label(l10n.collectionsCustomerSignatureLabel),
              _UploadBox(
                fileName: _signatureFileName,
                accent: true,
                onTap: () => _pickFile(isSignature: true),
              ),
              const SizedBox(height: 24),

              // Actions sit at the end of the form and scroll with it.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.collectionsCancelButton,
                          style: const TextStyle(color: AppColors.kTextDark)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.kSuccess,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _canSave ? _save : null,
                      icon: const Icon(Icons.check_circle_outline, size: 20),
                      label: Text(
                        _isEdit
                            ? l10n.collectionsUpdateButton
                            : l10n.collectionsSaveButton,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.kTextMuted)),
      );
}

class _UploadBox extends StatelessWidget {
  final String? fileName;
  final VoidCallback onTap;
  final bool accent;

  const _UploadBox(
      {required this.fileName, required this.onTap, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasFile = fileName != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: hasFile
              ? (accent ? const Color(0xFFF0FDF4) : const Color(0xFFF0F5FF))
              : AppColors.kBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: hasFile
                  ? (accent ? AppColors.kSuccess : AppColors.kInfo)
                  : AppColors.kBorder,
              style: hasFile ? BorderStyle.solid : BorderStyle.none),
        ),
        child: Row(
          children: [
            Icon(
              hasFile
                  ? Icons.check_circle_outline
                  : Icons.cloud_upload_outlined,
              color: hasFile
                  ? (accent ? AppColors.kSuccess : AppColors.kInfo)
                  : AppColors.kTextMuted,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasFile ? fileName! : l10n.collectionsUploadPlaceholder,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: hasFile
                      ? (accent ? AppColors.kSuccess : AppColors.kInfo)
                      : AppColors.kTextMuted,
                  fontWeight: hasFile ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
