import 'package:flutter/material.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../theme/glass_toast.dart';
import '../../models/agent_collection.dart';
import '../../services/agent_collection_api_service.dart';
import '../../services/collection_api_service.dart';
import '../../services/api_client.dart';
import '../../models/loan_record.dart';
import '../../models/repayment_installment.dart';
import '../collections/collections_screen.dart' show DueTodaySheet, DueTodayLine;
import '../../services/session_service.dart';
import '../../models/payment_history.dart';
import '../../utils/location_launcher.dart';
import '../../screens/agent_collection/agent_collection_detail_screen.dart';
import '../../widgets/collect_payment_sheet.dart';

const Color _kGold = Color(0xFFA9791F);
const Color _kGoldTint = Color(0xFFFBF3E1);

class AgentCollectionScreen extends StatefulWidget {
  const AgentCollectionScreen({super.key});

  @override
  State<AgentCollectionScreen> createState() => _AgentCollectionScreenState();
}

class _AgentCollectionScreenState extends State<AgentCollectionScreen> {
  bool _isLoading = true;
  String? _loadError;
  List<AgentCustomerGroup> _groups = [];
  List<PaymentHistoryItem> _todaysCollections = [];
  DueTodaySheet _dueSheet = DueTodaySheet(const []);
  String _query = '';

  // Keyed by "customerId|loanId" so it survives the list reload after a
  // collection is recorded (the API returns fresh group objects each time).
  final Map<String, double> _collectedTodayByGroup = {};

  int get _collectedToday => _collectedTodayByGroup.length;

  String _groupKey(AgentCustomerGroup group) =>
      '${group.customerId}|${group.loanId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final agentId = SessionService.instance.currentUser?.userId;
      final groupsFuture =
          AgentCollectionApiService.fetchAssignedCollectionGroups();
      final collectionsFuture = agentId == null || agentId.isEmpty
          ? Future.value(<Map<String, dynamic>>[])
          : CollectionApiService.fetchCollections(
              agentId: agentId,
              fromDate: DateTime(now.year, now.month, now.day),
            );
      final dueSheetFuture = _loadDueSheet(now);
      final groups = await groupsFuture;
      final collectionRows = await collectionsFuture;
      final dueSheet = await dueSheetFuture;
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _dueSheet = dueSheet;
        _todaysCollections = collectionRows
            .map(PaymentHistoryItem.fromJson)
            .where((item) {
              final date = item.collectedDate;
              return item.isPaidRecord &&
                  date != null &&
                  date.isBefore(tomorrow) &&
                  !date.isBefore(DateTime(now.year, now.month, now.day));
            })
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
      ToastService.show(
        title: 'Failed to load collections',
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  /// "To Collect Today" with the web dashboard's rule. The backend limits
  /// an agent to their own loans, schedules and receipts.
  Future<DueTodaySheet> _loadDueSheet(DateTime now) async {
    final today = DueTodaySheet.dayKey(now);
    final results = await Future.wait([
      ApiClient.instance.list('loans', query: {'status': 'in.(active,overdue)'}),
      ApiClient.instance.list('repayment_schedule',
          query: {'status': 'neq.paid', 'due_date': 'lte.$today'}),
      ApiClient.instance
          .list('collections', query: {'collection_date': 'eq.$today'}),
    ]);
    final collectedToday = <String, double>{};
    for (final row in results[2]) {
      final loanId = row['loan_id']?.toString() ?? '';
      if (loanId.isEmpty) continue;
      collectedToday[loanId] = (collectedToday[loanId] ?? 0) +
          (double.tryParse(row['collection_amount']?.toString() ?? '') ?? 0);
    }
    return DueTodaySheet.build(
      loans: results[0].map(LoanRecord.fromJson).toList(),
      schedules: results[1].map(RepaymentInstallment.fromJson),
      collectedTodayByLoan: collectedToday,
      now: now,
    );
  }

  AgentCustomerGroup? _groupForLoan(String loanId) {
    for (final g in _groups) {
      if (g.loanId == loanId) return g;
    }
    return null;
  }

  List<AgentCustomerGroup> get _filteredGroups =>
      _groups.where((g) => g.matchesQuery(_query)).toList();

  double get _totalDue =>
      _groups.fold(0.0, (sum, g) => sum + g.totalDueWithPenalty);

  double get _todaysCollectionsTotal =>
      _todaysCollections.fold(0.0, (sum, item) => sum + item.amount);

  void _openDetail(AgentCustomerGroup group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AgentCollectionDetailScreen(
          group: group,
          onReload: _load,
        ),
      ),
    );
    // The detail screen keeps its own local state but the underlying data
    // may have changed (payments recorded), so refresh the list on return.
    _load();
  }

  void _showCollectSheet(AgentCustomerGroup group) {
    final isMonthlyInterest = group.collectionType == LoanCollectionType.monthlyInterest;
    final overdueDueCount = group.overdueDueCount;
    final hasOverdueDues = overdueDueCount > 0;
    final dueAmount = hasOverdueDues ? group.overdueDueAmount : group.totalDue;
    final dueCount = hasOverdueDues ? overdueDueCount : group.items.length;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => CollectPaymentSheet(
        customerName: group.customerName,
        loanCollectionType: group.collectionType,
        // Monthly-interest loans don't have a single "due amount" — show
        // the loan number instead, matching the loan-type-specific info
        // box the sheet renders for that type.
        subtitleLabel: isMonthlyInterest ? 'Monthly Interest Loan' : 'Due Amount',
        subtitleValue: isMonthlyInterest
            ? (group.loanNumbers.isNotEmpty
                ? group.loanNumbers.first
                : group.loanId)
            : AgentCollectionItem.formatAmount(dueAmount),
          prefillAmount: dueAmount,
        installmentAmount: group.items.isNotEmpty
            ? group.items.first.installmentAmount
            : null,
        dueAmount: dueAmount,
        // Already gated by loan type inside the model (0 for daily /
        // monthly-interest loans), so no extra check needed here.
        penaltyAmount: group.totalPenalty,
        outstandingBalance: group.totalOutstanding,
        dueCount: dueCount,
        onSubmit: (amount, method, date, notes, paymentType, penalty) =>
            _collectForGroup(
                group, amount, method, date, notes, paymentType, penalty),
      ),
    );
  }

  Future<void> _collectForGroup(
    AgentCustomerGroup group,
    double amount,
    String method,
    DateTime date,
    String? notes,
    String paymentType,
    double penaltyAmount,
  ) async {
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
      final now = DateTime.now();
      final isToday = date.year == now.year &&
          date.month == now.month &&
          date.day == now.day;
      setState(() {
        if (isToday) {
          final key = _groupKey(group);
          _collectedTodayByGroup[key] =
              (_collectedTodayByGroup[key] ?? 0) + amount;
        }
      });
      final summary = createdCount == 1
          ? '1 installment recorded'
          : '$createdCount installments recorded';
      ToastService.show(
        title: 'Collection saved',
        message: '${group.uniqueName} • $summary',
        type: ToastType.success,
      );
      await _load();
    } catch (e) {
      ToastService.show(
        title: 'Collection failed',
        message: '${group.uniqueName}: $e',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppShell(
      currentRoute: AppRoutes.collections,
      title: 'Collections',
      // Center & ConstrainedBox make the UI fully responsive on Tablets/Web
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error_outline,
                              size: 48, color: scheme.error),
                          const SizedBox(height: 16),
                          Text('Failed to load collections',
                              style: TextStyle(
                                  color: scheme.error,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(_loadError!,
                                textAlign: TextAlign.center,
                                style:
                                    TextStyle(color: scheme.onSurfaceVariant)),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: _kGold,
                      child: _buildList(),
                    ),
        ),
      ),
    );
  }

  Widget _buildList() {
    final filtered = _filteredGroups;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: filtered.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildHeader();
        final group = filtered[index - 1];
        return _CustomerGroupCard(
          group: group,
          collectedTodayAmount: _collectedTodayByGroup[_groupKey(group)],
          onTap: () => _openDetail(group),
          onCollect: () => _showCollectSheet(group),
          onVisit: () => openCustomerLocation(context, group),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Collections',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: AppColors.kTextDark,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${_groups.length} customers assigned • $_collectedToday collected today',
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.kTextMuted),
          ),
          const SizedBox(height: 20),
          _buildTotalDueBanner(),
          const SizedBox(height: 20),
          _buildToCollectToday(),
          const SizedBox(height: 16),
          _buildTodaysCollections(),
          const SizedBox(height: 20),
          _buildSearchBar(),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: _query.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 12, left: 4),
                    child: Text(
                      '${_filteredGroups.length} result(s) for "$_query"',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.kTextMuted),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          if (_filteredGroups.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _query.isEmpty ? Icons.inbox_outlined : Icons.search_off,
                      size: 64,
                      color: AppColors.kTextMuted.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _query.isEmpty
                          ? 'No collections assigned'
                          : 'No customers match "$_query"',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.kTextMuted),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTotalDueBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFA9791F), Color(0xFFC48E28)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _kGold.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total Collection Due',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          Text(
            AgentCollectionItem.formatAmount(_totalDue),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToCollectToday() {
    final sheet = _dueSheet;
    return _SummarySection(
      title: 'To Collect Today',
      total: AgentCollectionItem.formatAmount(sheet.remaining),
      subtitle:
          '${sheet.customers} customer${sheet.customers == 1 ? '' : 's'} • '
          '${AgentCollectionItem.formatAmount(sheet.overdueTotal)} in arrears'
          '${sheet.settled > 0 ? ' • ${sheet.settled} settled' : ''}',
      child: sheet.lines.isEmpty
          ? const _SummaryEmptyState(label: 'No pending collections')
          : Column(
              children: sheet.lines.map((line) {
                final group = _groupForLoan(line.loanId);
                return _TodayDueRow(
                  line: line,
                  group: group,
                  onCollect: group == null || line.settled
                      ? null
                      : () => _showCollectSheet(group),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildTodaysCollections() {
    return _SummarySection(
      title: "Today's Collections",
      total: AgentCollectionItem.formatAmount(_todaysCollectionsTotal),
      subtitle:
          '${_todaysCollections.length} receipt${_todaysCollections.length == 1 ? '' : 's'}',
      child: _todaysCollections.isEmpty
          ? const _SummaryEmptyState(label: 'No collections recorded today')
          : Column(
              children: _todaysCollections
                  .map((item) => _TodayCollectionRow(item: item))
                  .toList(),
            ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: 'Search by name or Loan ID',
          hintStyle: TextStyle(color: AppColors.kTextMuted.withValues(alpha: 0.8)),
          prefixIcon: const Icon(Icons.search, color: AppColors.kTextMuted),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, color: AppColors.kTextMuted),
                  onPressed: () => setState(() => _query = ''),
                )
              : null,
          filled: true,
          fillColor: AppColors.kSurface,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _kGold, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  final String title;
  final String total;
  final String subtitle;
  final Widget child;

  const _SummarySection({
    required this.title,
    required this.total,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              Text(total,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle,
              style: const TextStyle(color: AppColors.kTextMuted)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SummaryEmptyState extends StatelessWidget {
  final String label;
  const _SummaryEmptyState({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(label,
              style: const TextStyle(color: AppColors.kTextMuted)),
        ),
      );
}

class _TodayDueRow extends StatelessWidget {
  final DueTodayLine line;
  final AgentCustomerGroup? group;
  final VoidCallback? onCollect;

  const _TodayDueRow({required this.line, this.group, this.onCollect});

  static String _dueInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final status = line.settled
        ? 'Paid today'
        : [
            if (line.overdueCount > 0) 'Overdue - ${line.overdueCount}',
            if (line.dueTodayCount > 0) 'Today - ${line.dueTodayCount}',
          ].join(' • ');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: _kGold,
            child: Text(group?.initials ?? _dueInitials(line.customerName),
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
                    if (group != null) group!.displayLoanType,
                  ].join(' • '),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.kTextMuted),
                ),
                const SizedBox(height: 5),
                Text(status,
                    style: TextStyle(
                        fontSize: 12,
                        color: line.settled
                            ? AppColors.kSuccess
                            : line.overdueCount > 0
                                ? AppColors.kDanger
                                : AppColors.kWarning)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(AgentCollectionItem.formatAmount(line.remaining),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 7),
              ElevatedButton(
                onPressed: onCollect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGold,
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
}

class _TodayCollectionRow extends StatelessWidget {
  final PaymentHistoryItem item;
  const _TodayCollectionRow({required this.item});

  @override
  Widget build(BuildContext context) {
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
            backgroundColor: _kGold,
            child: Text(_initials(item.customerName),
                style: const TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.customerName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text('${item.displayReceipt} • ${item.displayMode}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.kTextMuted)),
              ],
            ),
          ),
          Text(item.formattedAmount,
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

class _CustomerGroupCard extends StatefulWidget {
  final AgentCustomerGroup group;
  final double? collectedTodayAmount;
  final VoidCallback onTap;
  final VoidCallback onCollect;
  final VoidCallback onVisit;

  const _CustomerGroupCard({
    required this.group,
    this.collectedTodayAmount,
    required this.onTap,
    required this.onCollect,
    required this.onVisit,
  });

  @override
  State<_CustomerGroupCard> createState() => _CustomerGroupCardState();
}

class _CustomerGroupCardState extends State<_CustomerGroupCard> {
  bool _isHovered = false;

  bool get _isPaidToday => widget.collectedTodayAmount != null;
  String get _statusLabel => _isPaidToday ? 'Paid' : widget.group.statusLabel;

  Color get _statusColor {
    if (_isPaidToday) return AppColors.kSuccess;
    switch (widget.group.status) {
      case AgentCollectionStatus.overdue:
        return AppColors.kDanger;
      case AgentCollectionStatus.dueToday:
        return AppColors.kWarning;
      default:
        return AppColors.kSuccess;
    }
  }

  Color get _statusBg {
    if (_isPaidToday) return const Color(0xFFE7F7EE);
    switch (widget.group.status) {
      case AgentCollectionStatus.overdue:
        return const Color(0xFFFDEBEC);
      case AgentCollectionStatus.dueToday:
        return const Color(0xFFFFF3DC);
      default:
        return const Color(0xFFE7F7EE);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        decoration: BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered ? _kGold.withValues(alpha: 0.5) : AppColors.kBorder,
            width: _isHovered ? 1.5 : 1.0,
          ),
          boxShadow: [
            if (_isHovered)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, 6),
              )
            else
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 8,
                offset: const Offset(0, 2),
              )
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: widget.onTap,
                splashColor: _kGold.withValues(alpha: 0.1),
                highlightColor: _kGold.withValues(alpha: 0.05),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _kGoldTint,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              widget.group.initials,
                              style: const TextStyle(
                                  color: _kGold,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(widget.group.customerName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                        color: AppColors.kTextDark)),
                                const SizedBox(height: 4),
                                Text(
                                    widget.group.loanNumbers.isNotEmpty
                                        ? widget.group.loanNumbers.first
                                        : widget.group.loanId,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: AppColors.kTextMuted)),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: _statusBg,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _statusLabel,
                              style: TextStyle(
                                color: _statusColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _InfoBox(
                                label: 'EMI',
                                value: AgentCollectionItem.formatAmount(
                                    widget.group.items.first.installmentAmount)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _InfoBox(
                                label: 'Total Due',
                                value: AgentCollectionItem.formatAmount(
                                    widget.group.totalDueWithPenalty)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _InfoBox(
                                label: 'Next Due',
                                value: AgentCollectionItem.formatDate(
                                    widget.group.nearestDueDate)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Icon(Icons.phone_outlined,
                              size: 16, color: AppColors.kTextMuted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.group.contactPhone?.isNotEmpty == true
                                  ? widget.group.contactPhone!
                                  : 'Contact on file',
                              style: const TextStyle(
                                  fontSize: 13, color: AppColors.kTextMuted),
                            ),
                          ),
                        ],
                      ),
                      if (_isPaidToday) ...[
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE7F7EE),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: AppColors.kSuccess.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle,
                                  size: 18, color: AppColors.kSuccess),
                              const SizedBox(width: 10),
                              Text(
                                '${AgentCollectionItem.formatAmount(widget.collectedTodayAmount!)} collected today',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.kSuccess),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: widget.onCollect,
                        style: ButtonStyle(
                          backgroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.hovered)
                                ? const Color(0xFF90651A)
                                : _kGold,
                          ),
                          foregroundColor:
                              WidgetStateProperty.all(Colors.white),
                          elevation: WidgetStateProperty.resolveWith(
                              (states) => states.contains(WidgetState.hovered)
                                  ? 4
                                  : 0),
                          padding: WidgetStateProperty.all(
                              const EdgeInsets.symmetric(vertical: 14)),
                          shape: WidgetStateProperty.all(RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                        ),
                        icon: const Icon(Icons.currency_rupee, size: 18),
                        label: const Text('Collect',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onVisit,
                        style: ButtonStyle(
                          foregroundColor:
                              WidgetStateProperty.all(AppColors.kTextDark),
                          backgroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.hovered)
                                ? AppColors.kBorder.withValues(alpha: 0.3)
                                : Colors.transparent,
                          ),
                          side: WidgetStateProperty.all(
                              const BorderSide(color: AppColors.kBorder)),
                          padding: WidgetStateProperty.all(
                              const EdgeInsets.symmetric(vertical: 14)),
                          shape: WidgetStateProperty.all(RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                        ),
                        icon: const Icon(Icons.location_on_outlined, size: 18),
                        label: const Text('Visit',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final String label;
  final String value;
  const _InfoBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.kBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.kBorder.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.kTextDark,
                  letterSpacing: -0.3)),
        ],
      ),
    );
  }
}