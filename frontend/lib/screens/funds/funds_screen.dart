// screens/funds/funds_screen.dart

import 'package:flutter/material.dart';
import '../../theme/confirm_dialog.dart';
import '../../theme/glass_toast.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../models/fund.dart';
import '../../models/user_role.dart';
import '../../services/customer_api_service.dart';
import '../../services/fund_api_service.dart';
import '../../services/session_service.dart';
import '../../services/agent_api_service.dart';
import '../../l10n/generated/app_localizations.dart';
import 'package:intl/intl.dart';
import '../../widgets/responsive_stat_grid.dart';

String formatIndianCurrency(double? amount) {
  if (amount == null) return '₹0';
  final format =
      NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
  return format.format(amount);
}

String formatDate(DateTime? date) {
  if (date == null) return '';
  return DateFormat('dd MMM yyyy').format(date);
}

class FundsScreen extends StatefulWidget {
  const FundsScreen({super.key});

  @override
  State<FundsScreen> createState() => _FundsScreenState();
}

class _FundsScreenState extends State<FundsScreen> {
  bool _isLoading = true;
  String? _loadError;

  List<Fund> _funds = [];
  FundsSummary? _summary;
  List<Map<String, String>> _customers = [];
  List<Map<String, String>> _agents = [];

  // Role gates:
  // - customer: read-only, sees only their own fund(s). No create/edit/delete/settle/collect.
  // - agent: field collector. Sees Collect + Settle in full only. No create/edit/delete, no stat cards.
  // - admin: full control. Create/edit/delete/settle. No Collect button (that's the agent's job).
  bool get _isCustomerView => SessionService.instance.role == UserRole.customer;
  bool get _isAgentView => SessionService.instance.role == UserRole.agent;
  bool get _isAdminView => SessionService.instance.role == UserRole.admin;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final customerId = SessionService.instance.currentUser?.customerId;
      final funds = _isCustomerView
          ? await FundApiService.fetchForCustomer(customerId ?? '')
          : await FundApiService.fetchAll();

      // Customer accounts do not need the customer or agent directories. Apart
      // from avoiding unnecessary requests, this keeps other account details
      // out of the customer portal entirely.
      final customerRows = _isCustomerView
          ? const <Map<String, String>>[]
          : await CustomerApiService().fetchAllLite();
      final agentRows = _isCustomerView
          ? const <Map<String, dynamic>>[]
          : await AgentApiService.instance.getAgents();
      final agents = agentRows
          .where(
              (row) => (row['role']?.toString().toLowerCase() ?? '') == 'agent')
          .map((row) => <String, String>{
                'id': row['id'].toString(),
                'name': (row['name'] ?? row['full_name'] ?? '').toString(),
              })
          .where((row) => row['name']!.isNotEmpty)
          .toList();

      List<Fund> visibleFunds = funds;
      FundsSummary? summary;

      if (_isCustomerView) {
        summary = null;
      } else {
        summary = await FundApiService.fetchSummary();
      }

      if (!mounted) return;
      setState(() {
        _funds = visibleFunds;
        _customers = customerRows;
        _agents = agents;
        _summary = summary;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
      ToastService.show(
        title: AppLocalizations.of(context).fundToastLoadFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Widget _sheetFrame({required Widget child}) {
    final double keyboardPadding = MediaQuery.of(context).viewInsets.bottom;
    final double maxSheetHeight = MediaQuery.of(context).size.height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardPadding),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        decoration: const BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
                color: Colors.black12, blurRadius: 20, offset: Offset(0, -4)),
          ],
        ),
        child: SafeArea(top: false, child: SingleChildScrollView(child: child)),
      ),
    );
  }

  Future<void> _openCreateDialog() async {
    final result = await showModalBottomSheet<Fund>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _sheetFrame(
          child: _FundFormDialog(customers: _customers, agents: _agents)),
    );
    if (result == null) return;
    final l10n = AppLocalizations.of(context);

    try {
      final created = await FundApiService.create(result);
      setState(() => _funds.insert(0, created));
      ToastService.show(
        title: l10n.fundToastCreatedTitle,
        message: created.customerName,
        type: ToastType.success,
      );
      _loadData();
    } catch (e) {
      ToastService.show(
          title: l10n.fundToastCreateFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  Future<void> _openEditDialog(Fund fund) async {
    final result = await showModalBottomSheet<Fund>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _sheetFrame(
          child: _FundFormDialog(
              existing: fund, customers: _customers, agents: _agents)),
    );
    if (result == null) return;
    final l10n = AppLocalizations.of(context);

    try {
      final updated = await FundApiService.update(fund.id, result);
      if (!mounted) return;
      setState(() {
        final idx = _funds.indexWhere((f) => f.id == fund.id);
        if (idx != -1) _funds[idx] = updated;
      });
      ToastService.show(
        title: l10n.fundToastUpdatedTitle,
        message: updated.customerName,
        type: ToastType.success,
      );
      _loadData();
    } catch (e) {
      ToastService.show(
          title: l10n.fundToastUpdateFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  Future<void> _openSettleDialog(Fund fund) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _sheetFrame(child: _SettleFundDialog(fund: fund)),
    );
    if (result != true) return;
    _loadData();
    ToastService.show(
      title: AppLocalizations.of(context).fundToastSettledTitle,
      message: fund.customerName,
      type: ToastType.success,
    );
  }

  Future<void> _openPayoutDialog(Fund fund) async {
    final paid = await showModalBottomSheet<FundPayoutRecord>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _sheetFrame(child: _FundPayoutDialog(fund: fund)),
    );
    if (paid == null || !mounted) return;
    _loadData();
    ToastService.show(
      title: AppLocalizations.of(context).fundToastSettledTitle,
      message:
          '${formatIndianCurrency(paid.payoutAmount)} · ${fund.customerName}',
      type: ToastType.success,
    );
  }

  Future<void> _openCollectDialog(Fund fund) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _sheetFrame(child: _CollectDialog(fund: fund)),
    );
    if (result != true) return;
    _loadData();
    ToastService.show(
      title: AppLocalizations.of(context).fundToastCollectionRecordedTitle,
      message: fund.customerName,
      type: ToastType.success,
    );
  }

  /// Agent version of "settle in full": collect the full remaining balance
  /// through the same collect action as a normal Collect. The server stamps
  /// the receipt with this agent (so it shows in their Cash Handover) and
  /// marks the fund matured once its deposit target is reached.
  Future<void> _openAgentSettleDialog(Fund fund) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: l10n.fundAgentSettleDialogTitle,
      message: l10n.fundAgentSettleDialogMessage(
          formatIndianCurrency(fund.remainingToSettle),
          fund.code,
          fund.customerName),
      confirmLabel: l10n.fundAgentSettleDialogConfirm,
      confirmButtonColor: AppColors.kSuccess,
    );
    if (confirmed != true || !mounted) return;

    try {
      final remaining = fund.remainingToSettle;
      await FundApiService.recordCollection(
        fund.id,
        collectedAmount: fund.totalDeposit,
        status: FundStatus.matured.label,
        paymentAmount: remaining > 0 ? remaining : 0,
        paymentMethod: 'Cash',
        paymentDate: DateTime.now(),
        fundCode: fund.code,
        customerId: fund.customerId,
        customerName: fund.customerName,
        notes: 'Settled in full',
      );
      if (!mounted) return;
      _loadData();
      ToastService.show(
        title: l10n.fundToastSettledTitle,
        message: fund.customerName,
        type: ToastType.success,
      );
    } catch (e) {
      ToastService.show(
          title: l10n.fundToastSettlementFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  Future<void> _openPassbook(Fund fund) async {
    final profileName = SessionService.instance.currentUser?.name;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _sheetFrame(
        child: _PassbookDialog(
          fund: fund,
          customerDisplayName: _isCustomerView ? profileName : null,
          hideAgentDetails: _isCustomerView,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Fund fund) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: l10n.fundDeleteDialogTitle,
      message: l10n.fundDeleteDialogMessage(fund.code, fund.customerName),
      confirmLabel: l10n.fundDeleteDialogConfirm,
      confirmButtonColor: AppColors.kDanger,
    );
    if (confirmed != true || !mounted) return;

    try {
      await FundApiService.delete(fund.id);
      setState(() => _funds.removeWhere((f) => f.id == fund.id));
      ToastService.show(
          title: l10n.fundToastDeletedTitle,
          message: fund.customerName,
          type: ToastType.warning);
    } catch (e) {
      ToastService.show(
          title: l10n.fundToastDeleteFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  final TextEditingController _searchCtrl = TextEditingController();

  /// Client-side status filter; null shows every fund.
  FundStatus? _statusFilter;

  List<Fund> get _filteredFunds {
    final query = _searchCtrl.text.trim().toLowerCase();
    return _funds.where((fund) {
      if (_statusFilter != null && fund.effectiveStatus != _statusFilter) {
        return false;
      }
      if (query.isEmpty) return true;
      return fund.customerName.toLowerCase().contains(query) ||
          fund.code.toLowerCase().contains(query) ||
          fund.customerId.toLowerCase().contains(query);
    }).toList();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visibleFunds = _filteredFunds;
    final hasSearchQuery = _searchCtrl.text.trim().isNotEmpty;
    final isFiltered = hasSearchQuery || _statusFilter != null;
    final customerDisplayName =
        _isCustomerView ? SessionService.instance.currentUser?.name : null;

    return AppShell(
      currentRoute: AppRoutes.funds,
      title: l10n.fundsScreenTitle,
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError!,
                            style: const TextStyle(color: AppColors.kDanger)),
                        const SizedBox(height: 12),
                        ElevatedButton(
                            onPressed: _loadData,
                            child: Text(l10n.fundRetryButton)),
                      ],
                    ),
                  )
                : LayoutBuilder(builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final isNarrow = width < 700;
                    final gutter = width < 600 ? 16.0 : 24.0;

                    return ListView(
                      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 32),
                      children: [
                        _buildHeader(isNarrow, l10n),
                        const SizedBox(height: 16),
                        _buildSearchAndFilters(isNarrow, hasSearchQuery, l10n),
                        const SizedBox(height: 20),
                        // Customers get no server summary (`_summary` is
                        // null), so every card falls back to totals worked
                        // out from their own funds in `_funds`.
                        ...[
                          ResponsiveStatGrid(
                            children: [
                              _StatCard(
                                icon: Icons.savings_outlined,
                                iconBg: const Color(0xFFFEF3C7),
                                iconColor: AppColors.kWarning,
                                label: l10n.fundStatTotalFunds,
                                value:
                                    '${_summary?.totalFunds ?? _funds.length}',
                              ),
                              _StatCard(
                                icon: Icons.trending_up_rounded,
                                iconBg: const Color(0xFFDCFCE7),
                                iconColor: AppColors.kSuccess,
                                label: l10n.fundStatActive,
                                value:
                                    '${_summary?.activeFunds ?? _funds.where((f) => f.effectiveStatus == FundStatus.active).length}',
                              ),
                              _StatCard(
                                icon: Icons.card_giftcard_rounded,
                                iconBg: const Color(0xFFEDE9FE),
                                iconColor: const Color(0xFF7C3AED),
                                label: l10n.fundStatMaturityPayout,
                                value: formatIndianCurrency(
                                    _summary?.maturityPayoutTotal ??
                                        _funds.fold<double>(
                                            0.0,
                                            (double s, f) =>
                                                s + f.maturityPayout)),
                              ),
                              _StatCard(
                                icon: Icons.account_balance_wallet_outlined,
                                iconBg: const Color(0xFFFEF3C7),
                                iconColor: AppColors.kGold,
                                label: l10n.fundStatCollected,
                                value: formatIndianCurrency(
                                    _summary?.collectedTotal ??
                                        _funds.fold<double>(
                                            0.0,
                                            (double s, f) =>
                                                s + f.depositedAmount)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                        ],
                        if (visibleFunds.isEmpty)
                          _buildEmptyState(isFiltered
                              ? l10n.fundEmptySearch
                              : _isCustomerView
                                  ? l10n.fundEmptyCustomer
                                  : l10n.fundEmptyDefault)
                        // Phone: single card column. Tablet: two card
                        // columns. Wide: full table.
                        else if (width >= 1000)
                          _FundsTable(
                            funds: visibleFunds,
                            isAdmin: _isAdminView,
                            isAgent: _isAgentView,
                            isCustomer: _isCustomerView,
                            customerDisplayName: customerDisplayName,
                            onPassbook: _openPassbook,
                            onDelete: _confirmDelete,
                            onSettle: _openSettleOrPayout,
                            onAgentSettle: _openAgentSettleDialog,
                            onEdit: _openEditDialog,
                            onCollect: _openCollectDialog,
                          )
                        else
                          ..._buildCardRows(visibleFunds,
                              columns: width < 600 ? 1 : 2,
                              customerDisplayName: customerDisplayName),
                      ],
                    );
                  }),
      ),
    );
  }

  /// Settle while a fund is still collecting; pay out once it has stopped.
  void _openSettleOrPayout(Fund f) => f.effectiveStatus == FundStatus.active
      ? _openSettleDialog(f)
      : _openPayoutDialog(f);

  Widget _buildHeader(bool isNarrow, AppLocalizations l10n) {
    final subtitle = Text(
      l10n.fundsScreenSubtitle,
      style: const TextStyle(color: AppColors.kTextMuted, fontSize: 14),
    );
    // Creating funds is an admin-only action.
    final createButton = ElevatedButton.icon(
      onPressed: _openCreateDialog,
      icon: const Icon(Icons.add),
      label: Text(l10n.fundCreateButton,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      ),
    );

    if (isNarrow || !_isAdminView) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          subtitle,
          if (_isAdminView) ...[
            const SizedBox(height: 16),
            createButton,
          ],
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: subtitle),
        const SizedBox(width: 16),
        createButton,
      ],
    );
  }

  Widget _buildSearchAndFilters(
      bool isNarrow, bool hasSearchQuery, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final searchField = TextField(
      controller: _searchCtrl,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: l10n.fundSearchHint,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: hasSearchQuery
            ? IconButton(
                tooltip: l10n.fundSearchClearTooltip,
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.clear, size: 20),
              )
            : null,
      ),
    );

    final filters = <FundStatus?>[null, ...FundStatus.values];
    final filterRow = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((status) {
          final isSelected = _statusFilter == status;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(status == null
                  ? l10n.loansFilterAll
                  : _fundStatusLabel(status, l10n)),
              selected: isSelected,
              showCheckmark: false,
              selectedColor: scheme.primary,
              backgroundColor: AppColors.kSurface,
              shape: StadiumBorder(
                side: BorderSide(
                  color: isSelected ? scheme.primary : AppColors.kBorder,
                ),
              ),
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : scheme.onSurface,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
              onSelected: (_) => setState(() => _statusFilter = status),
            ),
          );
        }).toList(),
      ),
    );

    if (isNarrow) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.kBorder),
          boxShadow: [
            BoxShadow(
              color: AppColors.ink900.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            searchField,
            const SizedBox(height: 12),
            filterRow,
          ],
        ),
      );
    }

    return Row(
      children: [
        Expanded(flex: 2, child: searchField),
        const SizedBox(width: 16),
        Expanded(flex: 3, child: filterRow),
      ],
    );
  }

  Widget _buildEmptyState(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AppColors.gold50,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.savings_outlined,
                size: 30, color: AppColors.kGold),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.kTextMuted, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCardRows(List<Fund> funds,
      {required int columns, String? customerDisplayName}) {
    Widget card(Fund f, {bool fillHeight = false}) => _FundCard(
          fund: f,
          isAdmin: _isAdminView,
          isAgent: _isAgentView,
          isCustomer: _isCustomerView,
          customerDisplayName: customerDisplayName,
          fillHeight: fillHeight,
          onPassbook: () => _openPassbook(f),
          onDelete: () => _confirmDelete(f),
          onSettle: () => _openSettleOrPayout(f),
          onAgentSettle: () => _openAgentSettleDialog(f),
          onEdit: () => _openEditDialog(f),
          onCollect: () => _openCollectDialog(f),
        );

    if (columns == 1) {
      return [
        for (final f in funds)
          Padding(padding: const EdgeInsets.only(bottom: 14), child: card(f)),
      ];
    }

    final rows = <Widget>[];
    for (var start = 0; start < funds.length; start += columns) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 14),
        // Cards in a row share a height, with actions pinned to the bottom.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < columns; i++) ...[
                if (i > 0) const SizedBox(width: 14),
                Expanded(
                  child: start + i < funds.length
                      ? card(funds[start + i], fillHeight: true)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      ));
    }
    return rows;
  }
}

/// -----------------------------------------------------------------------
/// SHARED FUND PRESENTATION HELPERS
/// -----------------------------------------------------------------------

/// Same gold strip as the loan cards and table header.
const List<Color> _kGoldGradient = [Color(0xFFA9791F), Color(0xFFC48E28)];

String _fundStatusLabel(FundStatus status, AppLocalizations l10n) {
  switch (status) {
    case FundStatus.active:
      return l10n.fundStatusActive;
    case FundStatus.matured:
      return l10n.fundStatusMatured;
    case FundStatus.closed:
      return l10n.fundStatusClosed;
  }
}

Widget _fundStatusPill(FundStatus status, AppLocalizations l10n) {
  final Color dot;
  switch (status) {
    case FundStatus.active:
      dot = AppColors.kSuccess;
      break;
    case FundStatus.matured:
      dot = AppColors.kGold;
      break;
    case FundStatus.closed:
      dot = AppColors.kTextMuted;
      break;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: AppColors.gold100,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.gold300),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          _fundStatusLabel(status, l10n),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.gold800,
          ),
        ),
      ],
    ),
  );
}

/// What the headline figure is called.
///
/// Three different amounts wear this banner and only the fund's state says
/// which one it is — all three settled by the server rather than worked out
/// here from the columns the card happens to hold:
///
///   paid out    what actually left the safe, read back from `fund_payouts`
///   collecting  what the scheme pays at term, once every week is in
///   matured     deposits + the bonus, which running to term earned
///   closed      the deposits actually received; closing early earns no bonus
String _fundHeadlineLabel(Fund fund, AppLocalizations l10n) {
  final paid = fund.paidOut;
  if (paid != null) {
    return l10n.fundCardPaidOut(formatDate(paid.payoutDate));
  }
  switch (fund.effectiveStatus) {
    case FundStatus.active:
      return l10n.fundCardMaturityPayoutPending;
    case FundStatus.matured:
      return l10n.fundCardMaturityPayout;
    case FundStatus.closed:
      return l10n.fundCardClosurePayout;
  }
}

/// A fund still collecting has nothing payable yet, so it shows what it will
/// be worth at term. Every other state shows what is payable now.
double _fundHeadlineAmount(Fund fund) =>
    fund.effectiveStatus == FundStatus.active
        ? fund.maturityPayout
        : fund.payoutAmount;

/// Customer rows can contain an outdated display name (or a legacy agent
/// label). In the customer portal, the authenticated profile is the
/// authoritative identity.
String _fundCustomerName(Fund fund, String? customerDisplayName) =>
    (customerDisplayName?.trim().isNotEmpty ?? false)
        ? customerDisplayName!.trim()
        : fund.customerName;

/// -----------------------------------------------------------------------
/// STAT CARD
/// -----------------------------------------------------------------------
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: const TextStyle(
                      color: AppColors.kTextDark,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
            ],
          ),
          const Spacer(),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.kTextMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// -----------------------------------------------------------------------
/// FUND CARD (phone / tablet)
/// -----------------------------------------------------------------------
class _FundCard extends StatelessWidget {
  const _FundCard({
    required this.fund,
    required this.onPassbook,
    required this.onDelete,
    required this.onSettle,
    required this.onAgentSettle,
    required this.onEdit,
    required this.onCollect,
    this.isAdmin = false,
    this.isAgent = false,
    this.isCustomer = false,
    this.customerDisplayName,
    this.fillHeight = false,
  });

  final Fund fund;
  final VoidCallback onPassbook;
  final VoidCallback onDelete;
  final VoidCallback onSettle;
  final VoidCallback onAgentSettle;
  final VoidCallback onEdit;
  final VoidCallback onCollect;
  final bool isAdmin;
  final bool isAgent;
  final bool isCustomer;
  final String? customerDisplayName;

  /// True when laid out in a grid row of equal-height cards: the action row
  /// is then pushed to the bottom of the card.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = fund.effectiveStatus;
    final percent = (fund.depositedPercent / 100).clamp(0, 1).toDouble();
    final agent = fund.agentName?.trim() ?? '';

    Widget metric(String label, String value, {bool highlight = false}) =>
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.kTextMuted)),
              const SizedBox(height: 3),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: highlight
                          ? AppColors.kGoldDark
                          : AppColors.kTextDark)),
            ],
          ),
        );

    final stateActions = _buildStateActions(l10n);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kBorder),
        boxShadow: [
          BoxShadow(
            color: AppColors.ink900.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Gold header strip — fund no., customer, plan and status.
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _kGoldGradient,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.kGold.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.kGoldLight.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    fund.code,
                    style: const TextStyle(
                      color: AppColors.gold200,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fundCustomerName(fund, customerDisplayName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.kTextOnDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${formatIndianCurrency(fund.weeklyAmount)} × '
                        '${fund.numberOfWeeks} ${l10n.fundColWeeks}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.kTextOnDarkMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _fundStatusPill(status, l10n),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_fundHeadlineLabel(fund, l10n),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.kTextMuted)),
                const SizedBox(height: 2),
                Text(
                  formatIndianCurrency(_fundHeadlineAmount(fund)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.kGoldDark,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.kBackground,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      metric(l10n.fundColBonus,
                          formatIndianCurrency(fund.maturityBonus),
                          highlight: true),
                      metric(l10n.loansColStart, formatDate(fund.startDate)),
                      metric(
                          l10n.fundColMaturity, formatDate(fund.maturityDate)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.fundCardDepositedProgress(
                            formatIndianCurrency(fund.depositedAmount),
                            formatIndianCurrency(fund.totalDeposit)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.kTextMuted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${fund.depositedPercent.round()}%',
                        style: const TextStyle(
                            color: AppColors.kGoldDark,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: percent,
                    minHeight: 6,
                    backgroundColor: AppColors.gold50,
                    valueColor: const AlwaysStoppedAnimation(AppColors.kGold),
                  ),
                ),
                if (!isCustomer && agent.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.person_outline,
                          size: 16, color: AppColors.kGold),
                      const SizedBox(width: 6),
                      Text('${l10n.loansColAgent}: ',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.kTextMuted)),
                      Expanded(
                        child: Text(
                          agent,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.kTextDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (stateActions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  ...stateActions,
                ],
              ],
            ),
          ),
          if (fillHeight) const Spacer(),
          const Divider(height: 1),
          _buildActionRow(l10n),
        ],
      ),
    );
  }

  /// Bottom action strip, role-specific:
  /// - customer: Passbook only (read-only).
  /// - agent: Passbook, plus Collect while active. No edit/delete.
  /// - admin: Passbook + Edit + Delete.
  Widget _buildActionRow(AppLocalizations l10n) {
    Widget action(
            IconData icon, String label, Color color, VoidCallback onTap) =>
        Expanded(
          child: TextButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(vertical: 12),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              shape: const RoundedRectangleBorder(),
            ),
          ),
        );

    return Row(
      children: [
        action(Icons.menu_book_outlined, l10n.fundCardPassbookButton,
            AppColors.kGoldDark, onPassbook),
        if (isAgent && fund.effectiveStatus == FundStatus.active)
          action(Icons.payments_outlined, l10n.fundCardCollectButton,
              AppColors.kGold, onCollect),
        if (isAdmin) ...[
          action(Icons.edit_outlined, l10n.loansActionEdit, AppColors.ink700,
              onEdit),
          action(Icons.delete_outline_rounded, l10n.loansActionDelete,
              AppColors.kDanger, onDelete),
        ],
      ],
    );
  }

  /// Actions that only apply in the fund's current state:
  /// - agent: Settle in full while active.
  /// - admin: Collect + Settle in full while active, Pay Out once payable.
  List<Widget> _buildStateActions(AppLocalizations l10n) {
    final active = fund.effectiveStatus == FundStatus.active;
    if (isAgent && active) {
      // Agents can settle in full — but via the same allow-listed
      // (collected_amount + status) shape as Collect, not the admin dialog's
      // action/payment_method/settlement_date payload, which 403s for this role.
      return [_settleBanner(onAgentSettle, l10n)];
    }
    if (!isAdmin) return const [];
    return [
      if (active) ...[
        ElevatedButton.icon(
          onPressed: onCollect,
          icon: const Icon(Icons.payments_outlined, size: 18),
          label: Text(l10n.fundCardCollectButton),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.kGold,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 10),
        _settleBanner(onSettle, l10n),
      ],
      // Offered only where the server says a payout can actually be made.
      // `canPayOut` already covers a fund still collecting, one paid out
      // already, and one that never took a deposit.
      if (fund.canPayOut) ...[
        if (active) const SizedBox(height: 10),
        _payoutBanner(onSettle, l10n),
      ],
    ];
  }

  Widget _payoutBanner(VoidCallback onTap, AppLocalizations l10n) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: _kGoldGradient),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.payments_outlined, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                // fund.payoutAmount is the server's figure for this fund today,
                // so the button never offers more than the books would release.
                l10n.fundCardPayOutButton(
                    formatIndianCurrency(fund.payoutAmount)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settleBanner(VoidCallback onTap, AppLocalizations l10n) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFDCFCE7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 18, color: AppColors.kSuccess),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.fundCardSettleBanner(
                    formatIndianCurrency(fund.remainingToSettle)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.kSuccess,
                    fontWeight: FontWeight.w600,
                    fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// -----------------------------------------------------------------------
/// FUNDS TABLE (wide screens)
/// -----------------------------------------------------------------------
class _FundsTable extends StatelessWidget {
  const _FundsTable({
    required this.funds,
    required this.onPassbook,
    required this.onDelete,
    required this.onSettle,
    required this.onAgentSettle,
    required this.onEdit,
    required this.onCollect,
    this.isAdmin = false,
    this.isAgent = false,
    this.isCustomer = false,
    this.customerDisplayName,
  });

  final List<Fund> funds;
  final ValueChanged<Fund> onPassbook;
  final ValueChanged<Fund> onDelete;
  final ValueChanged<Fund> onSettle;
  final ValueChanged<Fund> onAgentSettle;
  final ValueChanged<Fund> onEdit;
  final ValueChanged<Fund> onCollect;
  final bool isAdmin;
  final bool isAgent;
  final bool isCustomer;
  final String? customerDisplayName;

  static const double _headingHeight = 50;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kBorder),
        boxShadow: [
          BoxShadow(
            color: AppColors.ink900.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LayoutBuilder(builder: (context, constraints) {
          final table = DataTable(
            // Transparent so the gold gradient strip painted behind it shows
            // through.
            headingRowColor: WidgetStateProperty.all(Colors.transparent),
            headingRowHeight: _headingHeight,
            dataRowMinHeight: 58,
            dataRowMaxHeight: 64,
            columnSpacing: 24,
            dividerThickness: 0.6,
            headingTextStyle: const TextStyle(
              color: AppColors.kTextOnDark,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
            dataTextStyle:
                const TextStyle(color: AppColors.kTextDark, fontSize: 13),
            columns: [
              DataColumn(label: Text(l10n.fundColFundNo)),
              // The customer column soaks up spare width so the table always
              // spans the card.
              DataColumn(
                label: Text(l10n.loansColCustomer),
                columnWidth: const MaxColumnWidth(
                    IntrinsicColumnWidth(), FlexColumnWidth()),
              ),
              DataColumn(label: Text(l10n.fundColWeekly)),
              DataColumn(label: Text(l10n.fundColWeeks)),
              DataColumn(label: Text(l10n.fundColBonus)),
              DataColumn(label: Text(l10n.fundColDeposited)),
              DataColumn(label: Text(l10n.fundColPayout)),
              if (!isCustomer) DataColumn(label: Text(l10n.loansColAgent)),
              DataColumn(label: Text(l10n.loansColStatus)),
              DataColumn(label: Text(l10n.loansColStart)),
              DataColumn(label: Text(l10n.fundColMaturity)),
              DataColumn(label: Text(l10n.loansColActions)),
            ],
            rows: [
              for (var i = 0; i < funds.length; i++)
                _buildRow(funds[i], i, l10n),
            ],
          );

          return Scrollbar(
            thumbVisibility: true,
            trackVisibility: true,
            notificationPredicate: (notification) => notification.depth == 0,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    // DataTable can't take a gradient, so paint the header
                    // strip (same gold as the fund cards) behind the table.
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: _headingHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: _kGoldGradient,
                          ),
                        ),
                      ),
                    ),
                    table,
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  DataRow _buildRow(Fund fund, int index, AppLocalizations l10n) {
    final status = fund.effectiveStatus;
    final active = status == FundStatus.active;
    final percent = (fund.depositedPercent / 100).clamp(0, 1).toDouble();
    final agent = fund.agentName?.trim() ?? '';

    Widget iconAction(IconData icon, Color color, String tooltip,
            ValueChanged<Fund> onTap) =>
        IconButton(
          icon: Icon(icon, size: 20),
          color: color,
          tooltip: tooltip,
          onPressed: () => onTap(fund),
        );

    return DataRow(
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) return AppColors.gold50;
        return index.isOdd ? AppColors.kBackground : AppColors.kSurface;
      }),
      cells: [
        DataCell(Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.gold50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.gold200),
          ),
          child: Text(fund.code,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.kGoldDark)),
        )),
        DataCell(Text(_fundCustomerName(fund, customerDisplayName),
            style: const TextStyle(fontWeight: FontWeight.w600))),
        DataCell(Text(formatIndianCurrency(fund.weeklyAmount))),
        DataCell(Text('${fund.numberOfWeeks}')),
        DataCell(Text(formatIndianCurrency(fund.maturityBonus))),
        DataCell(Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '${formatIndianCurrency(fund.depositedAmount)} · '
                '${fund.depositedPercent.round()}%'),
            const SizedBox(height: 5),
            SizedBox(
              width: 96,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: percent,
                  minHeight: 5,
                  backgroundColor: AppColors.gold50,
                  valueColor: const AlwaysStoppedAnimation(AppColors.kGold),
                ),
              ),
            ),
          ],
        )),
        DataCell(Tooltip(
          message: _fundHeadlineLabel(fund, l10n),
          child: Text(formatIndianCurrency(_fundHeadlineAmount(fund)),
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.kGoldDark)),
        )),
        if (!isCustomer) DataCell(Text(agent.isEmpty ? '-' : agent)),
        DataCell(_fundStatusPill(status, l10n)),
        DataCell(Text(formatDate(fund.startDate))),
        DataCell(Text(formatDate(fund.maturityDate))),
        DataCell(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconAction(Icons.menu_book_outlined, AppColors.kGoldDark,
                l10n.fundCardPassbookButton, onPassbook),
            if (!isCustomer && active)
              iconAction(Icons.payments_outlined, AppColors.kGold,
                  l10n.fundCardCollectButton, onCollect),
            if (isAgent && active)
              iconAction(
                  Icons.check_circle_outline,
                  AppColors.kSuccess,
                  l10n.fundCardSettleBanner(
                      formatIndianCurrency(fund.remainingToSettle)),
                  onAgentSettle),
            if (isAdmin) ...[
              if (active)
                iconAction(
                    Icons.check_circle_outline,
                    AppColors.kSuccess,
                    l10n.fundCardSettleBanner(
                        formatIndianCurrency(fund.remainingToSettle)),
                    onSettle),
              // Offered only where the server says a payout can be made.
              if (fund.canPayOut)
                iconAction(
                    Icons.account_balance_wallet_outlined,
                    AppColors.kGold,
                    l10n.fundCardPayOutButton(
                        formatIndianCurrency(fund.payoutAmount)),
                    onSettle),
              iconAction(Icons.edit_outlined, AppColors.ink600,
                  l10n.loansActionEdit, onEdit),
              iconAction(Icons.delete_outline_rounded, AppColors.kDanger,
                  l10n.loansActionDelete, onDelete),
            ],
          ],
        )),
      ],
    );
  }
}

/// -----------------------------------------------------------------------
/// CREATE / EDIT FUND FORM
/// -----------------------------------------------------------------------
class _FundFormDialog extends StatefulWidget {
  const _FundFormDialog(
      {this.existing, this.customers = const [], this.agents = const []});

  /// When non-null, the dialog opens in edit mode, prefilled from this fund.
  final Fund? existing;
  final List<Map<String, String>> customers;
  final List<Map<String, String>> agents;

  @override
  State<_FundFormDialog> createState() => _FundFormDialogState();
}

class _FundFormDialogState extends State<_FundFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _weeklyCtrl;
  late final TextEditingController _unitsCtrl;
  late final TextEditingController _weeksCtrl;
  late final TextEditingController _bonusCtrl;
  late DateTime _startDate;
  String? _selectedCustomerId;
  String? _selectedCustomerName;
  String? _selectedAgentId;
  String? _selectedAgentName;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _weeklyCtrl = TextEditingController(
        text: existing != null
            ? existing.weeklyAmount.round().toString()
            : '100');
    _unitsCtrl = TextEditingController(
        text: existing != null ? existing.units.toStringAsFixed(0) : '10');
    _weeksCtrl = TextEditingController(
        text: existing != null ? existing.numberOfWeeks.toString() : '50');
    _bonusCtrl = TextEditingController(
        text: existing != null
            ? existing.maturityBonus.round().toString()
            : '1000');
    _startDate = existing?.startDate ?? DateTime.now();
    _selectedCustomerId = existing?.customerId;
    _selectedCustomerName = existing?.customerName;
    _selectedAgentId = existing?.assignedAgentId;
    _selectedAgentName = existing?.agentName;
  }

  @override
  void dispose() {
    _weeklyCtrl.dispose();
    _unitsCtrl.dispose();
    _weeksCtrl.dispose();
    _bonusCtrl.dispose();
    super.dispose();
  }

  double get _weekly => double.tryParse(_weeklyCtrl.text) ?? 0;
  double get _units => double.tryParse(_unitsCtrl.text) ?? 0;
  int get _weeks => int.tryParse(_weeksCtrl.text) ?? 0;
  double get _bonus => double.tryParse(_bonusCtrl.text) ?? 0;
  double get _totalDeposit => _weekly * _weeks;
  double get _totalPayout => _totalDeposit + _bonus;
  DateTime get _maturityDate => DateTime(
      _startDate.year, _startDate.month, _startDate.day + (_weeks * 7));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context)
                .colorScheme
                .copyWith(primary: AppColors.kGold)),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _startDate = picked);
  }

  void _handleSubmit() {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCustomerId == null) {
      final l10n = AppLocalizations.of(context);
      ToastService.show(
          title: l10n.fundToastSelectCustomerTitle,
          message: l10n.fundToastSelectCustomerMessage,
          type: ToastType.error);
      return;
    }

    final existing = widget.existing;
    final fund = Fund(
      id: existing?.id ?? '',
      code: existing?.code ?? 'FND-${DateTime.now().millisecondsSinceEpoch}',
      customerId: _selectedCustomerId!,
      customerName: _selectedCustomerName ?? '',
      assignedAgentId: _selectedAgentId,
      agentName: _selectedAgentName,
      units: _units,
      status: existing?.status ?? FundStatus.active,
      weeklyAmount: _weekly,
      numberOfWeeks: _weeks,
      maturityBonus: _bonus,
      startDate: _startDate,
      maturityDate: _maturityDate,
      depositedAmount: existing?.depositedAmount ?? 0,
      entriesPaid: existing?.entriesPaid ?? 0,
    );

    Navigator.of(context).pop(fund);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dd = _startDate.day.toString().padLeft(2, '0');
    final mm = _startDate.month.toString().padLeft(2, '0');
    final yyyy = _startDate.year.toString();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                      _isEditing
                          ? l10n.fundFormTitleEdit
                          : l10n.fundFormTitleAdd,
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextDark)),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.close, color: AppColors.kTextMuted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(l10n.fundFormFieldCustomer,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.kTextMuted)),
            const SizedBox(height: 8),
            _SearchPickerField(
              options: [
                for (final c in widget.customers)
                  _PickOption(
                    id: c['id'] ?? '',
                    title: (c['name'] ?? '').isEmpty
                        ? l10n.fundFormFieldCustomerFallback
                        : c['name']!,
                    subtitle: [c['code'], c['mobile']]
                        .where((v) => v != null && v.isNotEmpty)
                        .join(' • '),
                  ),
              ],
              selectedId: _selectedCustomerId,
              selectedLabel: _selectedCustomerName,
              hintText: 'Search customer by name, ID or mobile',
              emptyText: 'No matching customers',
              icon: Icons.person_search_outlined,
              onChanged: (o) => setState(() {
                _selectedCustomerId = o?.id;
                _selectedCustomerName = o?.title;
              }),
            ),
            const SizedBox(height: 16),
            Text(l10n.fundFormFieldAgent,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.kTextMuted)),
            const SizedBox(height: 8),
            _SearchPickerField(
              options: [
                for (final a in widget.agents)
                  _PickOption(
                    id: a['id'] ?? '',
                    title: (a['name'] ?? '').isEmpty
                        ? l10n.fundFormFieldAgentFallback
                        : a['name']!,
                  ),
              ],
              selectedId: _selectedAgentId,
              selectedLabel: _selectedAgentName,
              hintText: 'Search agent by name',
              emptyText: 'No matching agents',
              icon: Icons.manage_search_outlined,
              onChanged: (o) => setState(() {
                _selectedAgentId = o?.id;
                _selectedAgentName = o?.title;
              }),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 500;
              return Column(
                children: [
                  _responsiveRow(
                    isNarrow,
                    _buildTextField(l10n.fundFormFieldUnits,
                        controller: _unitsCtrl, icon: Icons.savings_outlined),
                    _buildTextField(l10n.fundFormFieldWeeklyAmount,
                        controller: _weeklyCtrl, icon: Icons.currency_rupee),
                  ),
                  const SizedBox(height: 16),
                  _responsiveRow(
                    isNarrow,
                    _buildTextField(l10n.fundFormFieldWeeks,
                        controller: _weeksCtrl, icon: Icons.event_repeat),
                    _buildTextField(l10n.fundFormFieldBonus,
                        controller: _bonusCtrl, icon: Icons.card_giftcard),
                  ),
                  const SizedBox(height: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.fundFormFieldStartDate,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.kTextMuted)),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: _pickDate,
                        borderRadius: BorderRadius.circular(12),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                              isDense: true,
                              suffixIcon: Icon(Icons.calendar_today_outlined)),
                          child: Text('$dd/$mm/$yyyy'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _SummaryRow(
                      label: l10n.fundFormSummaryDeposited(
                          '${_weekly.round()}', '$_weeks'),
                      value: formatIndianCurrency(_totalDeposit)),
                  const SizedBox(height: 8),
                  _SummaryRow(
                    label: l10n.fundFormSummaryBonus,
                    value: l10n.fundFormSummaryBonusValue(
                        formatIndianCurrency(_bonus)),
                    valueColor: AppColors.kGold,
                  ),
                  const Divider(height: 20, color: AppColors.kBorder),
                  _SummaryRow(
                    label: l10n.fundFormSummaryTotalPayout,
                    value: formatIndianCurrency(_totalPayout),
                    labelColor: AppColors.kSuccess,
                    valueColor: AppColors.kSuccess,
                    bold: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(l10n.fundFormMaturesOn(formatDate(_maturityDate)),
                  style: const TextStyle(
                      color: AppColors.kTextMuted, fontSize: 13)),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.fundFormCancelButton)),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _handleSubmit,
                  icon: Icon(_isEditing
                      ? Icons.save_outlined
                      : Icons.add_circle_outline),
                  label: Text(_isEditing
                      ? l10n.fundFormSaveButton
                      : l10n.fundFormCreateButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _responsiveRow(bool isNarrow, Widget a, Widget b) {
    if (isNarrow) return Column(children: [a, const SizedBox(height: 16), b]);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        const SizedBox(width: 16),
        Expanded(child: b)
      ],
    );
  }

  Widget _buildTextField(String label,
      {required TextEditingController controller, IconData? icon}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.kTextMuted)),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: icon != null
                ? Icon(icon, size: 18, color: AppColors.kTextMuted)
                : null,
          ),
          validator: (v) => (v == null || v.trim().isEmpty)
              ? AppLocalizations.of(context).fundFormValidatorRequired
              : null,
        ),
      ],
    );
  }
}

/// One choice in a [_SearchPickerField].
class _PickOption {
  const _PickOption({required this.id, required this.title, this.subtitle});
  final String id;
  final String title;
  final String? subtitle;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return title.toLowerCase().contains(q) ||
        (subtitle?.toLowerCase().contains(q) ?? false);
  }
}

/// A search box in place of a dropdown, in the style of the Repayment
/// Schedule loan search: typing lists the matching options under the field,
/// tapping one selects it and the field then shows the selected name. The
/// selection only changes by picking a result or clearing it — leaving the
/// field mid-search puts the selected name back.
class _SearchPickerField extends StatefulWidget {
  const _SearchPickerField({
    required this.options,
    required this.selectedId,
    required this.selectedLabel,
    required this.hintText,
    required this.emptyText,
    required this.onChanged,
    this.icon = Icons.search,
  });

  final List<_PickOption> options;
  final String? selectedId;

  /// Shown when [selectedId] isn't among [options] (e.g. an edited fund's
  /// customer who is no longer listed).
  final String? selectedLabel;
  final String hintText;
  final String emptyText;
  final IconData icon;

  /// The picked option, or null when the selection is cleared.
  final ValueChanged<_PickOption?> onChanged;

  @override
  State<_SearchPickerField> createState() => _SearchPickerFieldState();
}

class _SearchPickerFieldState extends State<_SearchPickerField> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  String _query = '';

  String get _selectedText {
    final id = widget.selectedId;
    if (id == null) return '';
    for (final o in widget.options) {
      if (o.id == id) return o.title;
    }
    return widget.selectedLabel ?? '';
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _selectedText);
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _SearchPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _controller.text != _selectedText) {
      _controller.text = _selectedText;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      // Select the current name so typing replaces it straight away.
      _controller.selection =
          TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    } else {
      setState(() {
        _query = '';
        _controller.text = _selectedText;
      });
    }
  }

  void _pick(_PickOption option) {
    widget.onChanged(option);
    setState(() {
      _query = '';
      _controller.text = option.title;
    });
    _focus.unfocus();
  }

  void _clear() {
    widget.onChanged(null);
    setState(() {
      _query = '';
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.trim().isNotEmpty;
    final matches = searching
        ? widget.options.where((o) => o.matches(_query)).toList()
        : const <_PickOption>[];
    final showClear = searching || widget.selectedId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          enabled: widget.options.isNotEmpty || widget.selectedId != null,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hintText,
            prefixIcon: Icon(widget.icon, size: 20),
            suffixIcon: showClear
                ? IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _clear,
                  )
                : null,
          ),
        ),
        if (searching)
          // Part of the field's tap region, so tapping a result on web or
          // desktop doesn't first unfocus the field and close the list.
          TextFieldTapRegion(
            child: Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                color: AppColors.kSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.kBorder),
              ),
              child: matches.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        widget.emptyText,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.kTextMuted),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: matches.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppColors.kBorder),
                      itemBuilder: (context, i) {
                        final option = matches[i];
                        final isSelected = option.id == widget.selectedId;
                        final subtitle = option.subtitle;
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          selectedTileColor:
                              AppColors.kGold.withValues(alpha: 0.08),
                          title: Text(
                            option.title,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.kTextDark),
                          ),
                          subtitle: subtitle == null || subtitle.isEmpty
                              ? null
                              : Text(
                                  subtitle,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.kTextMuted),
                                ),
                          trailing: isSelected
                              ? const Icon(Icons.check,
                                  size: 18, color: AppColors.kGold)
                              : null,
                          onTap: () => _pick(option),
                        );
                      },
                    ),
            ),
          ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.labelColor,
    this.valueColor,
    this.bold = false,
  });
  final String label;
  final String value;
  final Color? labelColor;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    // Both sides are flexible and the value wraps: a sentence-length value
    // ("not earned — ₹9,000 short of the full term") would otherwise run off
    // the edge of a phone-width dialog.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(label,
              style: TextStyle(
                  color: labelColor ?? AppColors.kTextMuted,
                  fontSize: 14,
                  fontWeight: bold ? FontWeight.w600 : FontWeight.normal)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.end,
              style: TextStyle(
                  color: valueColor ?? AppColors.kTextDark,
                  fontSize: bold ? 18 : 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
        ),
      ],
    );
  }
}

/// -----------------------------------------------------------------------
/// RECORD COLLECTION (agent — partial/weekly payment)
/// -----------------------------------------------------------------------
class _CollectDialog extends StatefulWidget {
  const _CollectDialog({required this.fund});
  final Fund fund;

  @override
  State<_CollectDialog> createState() => _CollectDialogState();
}

class _CollectDialogState extends State<_CollectDialog> {
  late final TextEditingController _amountCtrl;
  String _paymentMethod = 'Cash';
  DateTime _paymentDate = DateTime.now();
  bool _isSubmitting = false;

  static const _paymentMethods = [
    'Cash',
    'UPI',
    'Card',
    'Bank Transfer',
    'Cheque'
  ];

  Future<void> _pickPaymentDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _paymentDate,
      firstDate: widget.fund.startDate,
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context)
                .colorScheme
                .copyWith(primary: AppColors.kGold)),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _paymentDate = picked);
  }

  @override
  void initState() {
    super.initState();
    final fund = widget.fund;
    final suggested = fund.weeklyAmount > 0
        ? fund.weeklyAmount.clamp(
            0,
            fund.remainingToSettle == 0
                ? fund.weeklyAmount
                : fund.remainingToSettle)
        : fund.remainingToSettle;
    _amountCtrl = TextEditingController(text: suggested.round().toString());
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleRecord() async {
    final l10n = AppLocalizations.of(context);
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '').trim()) ?? 0;
    if (amount <= 0) {
      ToastService.show(
        title: l10n.fundCollectDialogInvalidAmountTitle,
        message: l10n.fundCollectDialogInvalidAmountMessage,
        type: ToastType.error,
      );
      return;
    }

    final fund = widget.fund;
    final remaining =
        fund.remainingToSettle.clamp(0, double.infinity).toDouble();
    if (amount > remaining + 0.01) {
      ToastService.show(
        title: l10n.fundCollectDialogNotSavedTitle,
        message: l10n
            .fundCollectDialogNotSavedMessage(formatIndianCurrency(remaining)),
        type: ToastType.warning,
      );
      return;
    }
    // The server derives the running total and status from the receipt
    // (and stamps the collecting agent on it); these two are only sent by
    // the legacy fallback for servers without funds.php?action=collect.
    final newCollected = fund.depositedAmount + amount;
    final newStatus = newCollected >= fund.totalDeposit
        ? FundStatus.matured.label
        : fund.status.label;

    setState(() => _isSubmitting = true);
    try {
      await FundApiService.recordCollection(
        widget.fund.id,
        collectedAmount: newCollected,
        status: newStatus,
        paymentAmount: amount,
        paymentMethod: _paymentMethod,
        paymentDate: _paymentDate,
        fundCode: widget.fund.code,
        customerId: widget.fund.customerId,
        customerName: widget.fund.customerName,
        notes: 'Collection',
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ToastService.show(
          title: AppLocalizations.of(context).fundCollectDialogFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fund = widget.fund;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.savings_outlined,
                    color: AppColors.kGold, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.fundCollectDialogTitle,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.kTextDark)),
                    const SizedBox(height: 2),
                    Text(
                        l10n.fundCollectDialogSubtitle(
                            fund.code, fund.customerName),
                        style: const TextStyle(
                            color: AppColors.kTextMuted, fontSize: 13)),
                  ],
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.close, color: AppColors.kTextMuted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.fundCollectDialogCollectedLabel,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.kTextMuted)),
                      const SizedBox(height: 4),
                      Text(formatIndianCurrency(fund.depositedAmount),
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppColors.kTextDark)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.fundCollectDialogRemainingLabel,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.kSuccess)),
                      const SizedBox(height: 4),
                      Text(formatIndianCurrency(fund.remainingToSettle),
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppColors.kSuccess)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(l10n.fundCollectDialogAmountLabel,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 500;
            final methodField = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.fundCollectDialogPaymentMethodLabel,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.kTextMuted)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _paymentMethod,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: _paymentMethods
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _paymentMethod = v ?? 'Cash'),
                ),
              ],
            );
            final dateField = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.fundCollectDialogPaymentDateLabel,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.kTextMuted)),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickPaymentDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      isDense: true,
                      suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                    ),
                    child: Text(formatDate(_paymentDate)),
                  ),
                ),
              ],
            );
            if (isNarrow) {
              return Column(children: [
                methodField,
                const SizedBox(height: 16),
                dateField
              ]);
            }
            return Row(children: [
              Expanded(child: methodField),
              const SizedBox(width: 16),
              Expanded(child: dateField)
            ]);
          }),
          const SizedBox(height: 8),
          TextField(
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.currency_rupee,
                  size: 18, color: AppColors.kTextMuted),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.fundCollectDialogHelperText,
            style: const TextStyle(color: AppColors.kTextMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                onPressed:
                    _isSubmitting ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.fundFormCancelButton),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _handleRecord,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.payments_outlined),
                label: Text(l10n.fundCollectDialogRecordButton),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// -----------------------------------------------------------------------
/// SETTLE FUND IN FULL
/// -----------------------------------------------------------------------
enum _ClosureMode { partial, full }

class _SettleFundDialog extends StatefulWidget {
  const _SettleFundDialog({required this.fund});
  final Fund fund;

  @override
  State<_SettleFundDialog> createState() => _SettleFundDialogState();
}

class _SettleFundDialogState extends State<_SettleFundDialog> {
  _ClosureMode _mode = _ClosureMode.partial;
  String _paymentMethod = 'Cash';
  DateTime _settlementDate = DateTime.now();
  bool _isSubmitting = false;

  // Sourced straight from the fund's own `units` column (funds.units), so a
  // partial closure always works against however many units are still
  // active right now — including ones already shrunk by an earlier closure.
  double get _maxUnits => widget.fund.units > 0 ? widget.fund.units : 1;

  // Quick-select presets shown as chips above the manual input.
  static const List<double> _quickUnitOptions = [0.5, 1, 2, 5];

  late final TextEditingController _unitsCtrl = TextEditingController(
    text: _formatUnits(_quickUnitOptions.first < _maxUnits
        ? _quickUnitOptions.first
        : _maxUnits),
  );

  static String _formatUnits(double units) =>
      units % 1 == 0 ? units.toStringAsFixed(0) : units.toString();

  double get _unitsToClose =>
      (double.tryParse(_unitsCtrl.text) ?? 0).clamp(0, _maxUnits);
  double get _remainingUnits => _maxUnits - _unitsToClose;

  // Everything on the fund — the deposits taken so far, the weekly instalment,
  // the deposit target — is the figure for *all* its active units, so each
  // amount below is divided down to one unit before being scaled back up by
  // the units actually being closed.
  double get _depositsPerUnit =>
      _maxUnits == 0 ? 0 : widget.fund.depositedAmount / _maxUnits;
  double get _weeklyPerUnit =>
      _maxUnits == 0 ? 0 : widget.fund.weeklyAmount / _maxUnits;

  /// Deposits received against the units being closed — what goes back to the
  /// customer. Matches FundService::close, which returns `collected_amount`
  /// times the closed share of the units.
  double get _closedUnitsDeposit =>
      (_depositsPerUnit * _unitsToClose).clamp(0, widget.fund.depositedAmount);

  /// True when this closure takes the last active units — either because the
  /// operator is on the "settle in full" tab, or because the units typed in
  /// are all that is left. The dialog then runs the full settle path
  /// (close + payout) rather than a partial closure.
  bool get _closesEverything =>
      _mode == _ClosureMode.full || _remainingUnits <= 0.0001;

  /// A bonus is only ever paid on a fund that reached its deposit target, and
  /// only on a full settlement: a partial closure hands the deposits back on
  /// their own (FundService::close writes `bonus_amount` = 0). Closing early
  /// therefore earns nothing, however many units go.
  bool get _bonusEarned =>
      _closesEverything &&
      (widget.fund.preview?.bonusEarned ??
          widget.fund.effectiveStatus == FundStatus.matured);
  double get _closureBonus => _bonusEarned ? widget.fund.maturityBonus : 0;

  /// How much more has to be deposited before the bonus is earned at all.
  double get _shortOfFullTerm =>
      widget.fund.remainingToSettle < 0 ? 0 : widget.fund.remainingToSettle;

  /// Paid out now — deposits for the closed units, plus the bonus if earned.
  double get _closedUnitsPayout => _closedUnitsDeposit + _closureBonus;

  /// What the units left behind keep collecting each week.
  double get _newWeeklyAmount => _weeklyPerUnit * _remainingUnits;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _settlementDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context)
                .colorScheme
                .copyWith(primary: AppColors.kGold)),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _settlementDate = picked);
  }

  Future<void> _handleFullSettle() async {
    setState(() => _isSubmitting = true);
    try {
      if (widget.fund.effectiveStatus != FundStatus.matured) {
        await FundApiService.closeFund(
          widget.fund.id,
          paymentMethod: _paymentMethod,
          payoutDate: _settlementDate,
        );
      }
      await FundApiService.payout(
        widget.fund.id,
        paymentMethod: _paymentMethod,
        payoutDate: _settlementDate,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ToastService.show(
          title: AppLocalizations.of(context).fundSettleFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  Future<void> _handlePartialClosure() async {
    if (_unitsToClose <= 0) {
      ToastService.show(
          title: 'Enter units to close',
          message: 'Units must be greater than 0',
          type: ToastType.error);
      return;
    }
    setState(() => _isSubmitting = true);
    final fund = widget.fund;
    try {
      // Preserve the original maturity terms when the last active unit is
      // closed. This keeps the completed passbook faithful to the backend
      // fund agreement instead of shrinking it to zero first.
      if (_closesEverything) {
        await FundApiService.closeFund(
          fund.id,
          paymentMethod: _paymentMethod,
          payoutDate: _settlementDate,
        );
        await FundApiService.payout(
          fund.id,
          paymentMethod: _paymentMethod,
          payoutDate: _settlementDate,
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }

      await FundApiService.closeFund(
        fund.id,
        units: _unitsToClose,
        paymentMethod: _paymentMethod,
        payoutDate: _settlementDate,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ToastService.show(
          title: AppLocalizations.of(context).fundSettleFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  /// Stylish, tappable "N Units" preset chip. Selected state fills gold;
  /// a preset beyond what's still active on the fund is greyed out and
  /// disabled rather than hidden, so the row stays visually stable.
  Widget _unitOptionChip(double value, String label) {
    final selected = (_unitsToClose - value).abs() < 0.001;
    final disabled = value > _maxUnits + 0.0001;
    return InkWell(
      onTap: disabled
          ? null
          : () => setState(() => _unitsCtrl.text = _formatUnits(value)),
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: disabled
              ? const Color(0xFFF3F4F6)
              : selected
                  ? AppColors.kGold
                  : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected && !disabled ? AppColors.kGold : AppColors.kBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: disabled
                ? AppColors.kTextMuted
                : selected
                    ? Colors.white
                    : AppColors.kTextDark,
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String label, IconData icon, _ClosureMode mode) {
    final selected = _mode == mode;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mode = mode),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: selected
                ? [
                    const BoxShadow(
                        color: Colors.black12,
                        blurRadius: 6,
                        offset: Offset(0, 1))
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected ? AppColors.kGold : AppColors.kTextMuted),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.kTextDark
                          : AppColors.kTextMuted)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fund = widget.fund;
    final dd = _settlementDate.day.toString().padLeft(2, '0');
    final mm = _settlementDate.month.toString().padLeft(2, '0');
    final yyyy = _settlementDate.year.toString();
    final screenWidth = MediaQuery.of(context).size.width;
    final hPad = screenWidth < 380 ? 16.0 : 24.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.fundSettleDialogTitle,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.kTextDark)),
                    const SizedBox(height: 2),
                    Text(
                        l10n.fundSettleDialogSubtitle(fund.code,
                            fund.customerName, _formatUnits(_maxUnits)),
                        style: const TextStyle(
                            color: AppColors.kTextMuted, fontSize: 13)),
                  ],
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.close, color: AppColors.kTextMuted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                _tabButton(l10n.fundSettleTabPartial, Icons.bolt,
                    _ClosureMode.partial),
                _tabButton(l10n.fundSettleTabFull, Icons.lock_outline,
                    _ClosureMode.full),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_mode == _ClosureMode.partial) ...[
            Text(l10n.fundSettleUnitsToCloseLabel,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.kTextMuted)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _unitOptionChip(0.1, '0.1 Units'),
                _unitOptionChip(0.5, l10n.fundSettleHalfUnitButton),
                _unitOptionChip(1, l10n.fundSettleOneUnitButton),
                _unitOptionChip(2, l10n.fundSettleTwoUnitButton),
                _unitOptionChip(5, l10n.fundSettleFiveUnitButton),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _unitsCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.savings_outlined,
                    size: 18, color: AppColors.kTextMuted),
                hintText: l10n.fundSettleUnitsToCloseLabel,
                suffixText:
                    l10n.fundSettleUnitsInputMaxHint(_formatUnits(_maxUnits)),
                suffixStyle:
                    const TextStyle(fontSize: 12, color: AppColors.kTextMuted),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: const Color(0xFFEDE9FE),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.fundSettleClosedPayoutLabel,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF7C3AED))),
                        const SizedBox(height: 4),
                        Text(formatIndianCurrency(_closedUnitsPayout),
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF7C3AED))),
                        Text(
                            _bonusEarned
                                ? l10n.fundSettleClosedPayoutSubtitle
                                : l10n.fundSettleClosedPayoutSubtitleNoBonus,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF7C3AED))),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.fundSettleRemainingBalanceLabel,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.kSuccess)),
                        const SizedBox(height: 4),
                        Text(
                            l10n.fundSettleRemainingUnitsValue(
                                _remainingUnits.toStringAsFixed(
                                    _remainingUnits % 1 == 0 ? 0 : 1)),
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: AppColors.kSuccess)),
                        Text(
                            l10n.fundSettleNewWeeklyValue(
                                formatIndianCurrency(_newWeeklyAmount)),
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.kSuccess)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.fundSettleTotalDepositedLabel,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.kTextMuted)),
                        const SizedBox(height: 4),
                        Text(formatIndianCurrency(fund.depositedAmount),
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: AppColors.kTextDark)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.fundSettleRemainingTargetLabel,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.kWarning)),
                        const SizedBox(height: 4),
                        Text(formatIndianCurrency(fund.remainingToSettle),
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: AppColors.kWarning)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 500;
            final methodField = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.fundSettlePaymentMethodLabel,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.kTextMuted)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _paymentMethod,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: const [
                    'Cash',
                    'UPI',
                    'Card',
                    'Bank Transfer',
                    'Cheque'
                  ]
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _paymentMethod = v ?? 'Cash'),
                ),
              ],
            );
            final dateField = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.fundSettleSettlementDateLabel,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.kTextMuted)),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: const InputDecoration(isDense: true),
                    child: Text('$dd/$mm/$yyyy'),
                  ),
                ),
              ],
            );
            if (isNarrow) {
              return Column(children: [
                methodField,
                const SizedBox(height: 16),
                dateField
              ]);
            }
            return Row(children: [
              Expanded(child: methodField),
              const SizedBox(width: 16),
              Expanded(child: dateField)
            ]);
          }),
          const SizedBox(height: 20),
          Container(
            width: double
                .infinity, // Ensures the container adapts to the full mobile screen width
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12)),
            child: Column(
              mainAxisSize: MainAxisSize
                  .min, // Prevents the column from taking unnecessary vertical space
              children: [
                _SummaryRow(
                  label: l10n.fundSettleSummaryDepositsReceived,
                  value: _mode == _ClosureMode.partial
                      ? l10n.fundSettleSummaryClosingTargetValue(
                          formatIndianCurrency(_closedUnitsDeposit),
                          _formatUnits(_unitsToClose),
                          _formatUnits(_maxUnits))
                      : formatIndianCurrency(fund.depositedAmount),
                ),
                const SizedBox(height: 8),
                // Closing before the deposits are complete earns no bonus, so
                // say what is missing rather than printing a "+ ₹0" line.
                _SummaryRow(
                  // Not "proportional" any more: the bonus is all-or-nothing
                  // on the full term, so the passbook's plain label is the
                  // honest one here too.
                  label: l10n.fundPassbookSummaryBonus,
                  value: _bonusEarned
                      ? l10n.fundFormSummaryBonusValue(formatIndianCurrency(
                          _mode == _ClosureMode.partial
                              ? _closureBonus
                              : fund.maturityBonus))
                      : l10n.fundSettleSummaryBonusNotEarned(
                          formatIndianCurrency(_shortOfFullTerm)),
                  valueColor:
                      _bonusEarned ? AppColors.kGold : AppColors.kTextMuted,
                ),
                const Divider(height: 20, color: AppColors.kBorder),
                _SummaryRow(
                  label: _mode == _ClosureMode.partial
                      ? l10n.fundSettleSummaryNetClosurePayout
                      : l10n.fundSettleSummaryPayoutToCustomer,
                  value: formatIndianCurrency(_mode == _ClosureMode.partial
                      ? _closedUnitsPayout
                      : fund.payoutAmount),
                  labelColor: AppColors.kSuccess,
                  valueColor: AppColors.kSuccess,
                  bold: true,
                ),
              ],
            ),
          ),
          // Spelling out where the money comes from, because the payout leaves
          // the safe the moment this is confirmed.
          if (_mode == _ClosureMode.partial) ...[
            const SizedBox(height: 12),
            Text(
              l10n.fundSettleClosureHelper(
                _formatUnits(_unitsToClose),
                _formatUnits(_maxUnits),
                formatIndianCurrency(_closedUnitsPayout),
                _formatUnits(_remainingUnits),
                formatIndianCurrency(_newWeeklyAmount),
              ),
              style: const TextStyle(fontSize: 12, color: AppColors.kTextMuted),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                onPressed:
                    _isSubmitting ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.fundFormCancelButton),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _isSubmitting
                    ? null
                    : (_mode == _ClosureMode.partial
                        ? _handlePartialClosure
                        : _handleFullSettle),
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_circle_outline),
                label: Text(_mode == _ClosureMode.partial
                    ? l10n.fundSettleConfirmPartialButton
                    : l10n.fundSettleConfirmFullButton),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// -----------------------------------------------------------------------
/// PASSBOOK
/// -----------------------------------------------------------------------
class _FundPayoutDialog extends StatefulWidget {
  const _FundPayoutDialog({required this.fund});

  final Fund fund;

  @override
  State<_FundPayoutDialog> createState() => _FundPayoutDialogState();
}

class _FundPayoutDialogState extends State<_FundPayoutDialog> {
  String _paymentMethod = 'Cash';
  DateTime _payoutDate = DateTime.now();
  bool _isSubmitting = false;
  final _notesController = TextEditingController();

  /// What the server says this fund is worth, asked for as the dialog opens.
  ///
  /// The card that opened it may have been drawn some time ago, and this is the
  /// screen that actually moves money: a collection recorded elsewhere in the
  /// meantime changes the figure, and a payout somebody else has already made
  /// means there is no figure at all. The amount is never sent — `FundService`
  /// recomputes it — so this is purely so the operator sees beforehand what the
  /// server is about to write.
  FundSheet? _sheet;
  bool _isLoading = true;
  String? _loadError;

  FundPayoutPreview? get _preview => _sheet?.preview;
  Fund get _fund => _sheet?.fund ?? widget.fund;

  double get _deposits => _preview?.depositAmount ?? _fund.depositedAmount;
  double get _bonus => _preview?.bonusAmount ?? 0;
  double get _total => _preview?.payoutAmount ?? _fund.payoutAmount;
  bool get _bonusEarned =>
      _preview?.bonusEarned ?? _fund.effectiveStatus == FundStatus.matured;
  bool get _canPay => _preview?.canPay ?? true;

  @override
  void initState() {
    super.initState();
    _loadSheet();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadSheet() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final sheet = await FundApiService.fetchSheet(widget.fund.id);
      if (!mounted) return;
      setState(() {
        _sheet = sheet;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _payoutDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _payoutDate = picked);
  }

  Future<void> _confirmPayout() async {
    setState(() => _isSubmitting = true);
    try {
      final sheet = await FundApiService.payout(
        widget.fund.id,
        paymentMethod: _paymentMethod,
        payoutDate: _payoutDate,
        notes: _notesController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(sheet.finalPayout);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ToastService.show(
        title: AppLocalizations.of(context).fundToastSettlementFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('dd/MM/yyyy').format(_payoutDate);
    final fund = _fund;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Fund Payout',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppColors.kTextDark)),
                    Text('${fund.code} · ${fund.customerName}',
                        style: const TextStyle(color: AppColors.kTextMuted)),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_loadError != null) ...[
            Text(_loadError!, style: const TextStyle(color: AppColors.kDanger)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton(
                  onPressed: _loadSheet,
                  child: Text(AppLocalizations.of(context).fundRetryButton)),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  const Text('PAYING TO',
                      style: TextStyle(
                          color: AppColors.kSuccess,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(fund.customerName,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(formatIndianCurrency(_total),
                      style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          color: AppColors.kSuccess)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _SummaryRow(
              label: 'Deposits received',
              value: formatIndianCurrency(_deposits),
            ),
            _SummaryRow(
              label: 'Maturity bonus',
              value: _bonusEarned
                  ? '+ ${formatIndianCurrency(_bonus)}'
                  : 'Not earned — closed early',
              valueColor: _bonusEarned ? AppColors.kGold : AppColors.kTextMuted,
            ),
            const Divider(color: AppColors.kBorder),
            _SummaryRow(
              label: 'Total payout',
              value: formatIndianCurrency(_total),
              valueColor: AppColors.kSuccess,
              labelColor: AppColors.kSuccess,
              bold: true,
            ),
            // The server has already decided this cannot be paid — say why here
            // rather than letting the request come back as an error.
            if (!_canPay) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _preview?.blockedReason ?? 'This fund cannot be paid out.',
                  style:
                      const TextStyle(color: AppColors.kWarning, fontSize: 13),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _paymentMethod,
                    decoration: const InputDecoration(labelText: 'METHOD'),
                    items: const [
                      'Cash',
                      'UPI',
                      'Card',
                      'Bank Transfer',
                      'Cheque'
                    ]
                        .map((method) => DropdownMenuItem(
                            value: method, child: Text(method)))
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _paymentMethod = value ?? 'Cash'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration:
                          const InputDecoration(labelText: 'PAYOUT DATE'),
                      child: Text(date),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'NOTES',
                hintText: 'Optional',
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed:
                      _isSubmitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _isSubmitting || !_canPay ? null : _confirmPayout,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.payments_outlined),
                  label: const Text('Confirm Payout'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PassbookDialog extends StatefulWidget {
  const _PassbookDialog({
    required this.fund,
    this.customerDisplayName,
    this.hideAgentDetails = false,
  });
  final Fund fund;
  final String? customerDisplayName;
  final bool hideAgentDetails;

  @override
  State<_PassbookDialog> createState() => _PassbookDialogState();
}

class _PassbookDialogState extends State<_PassbookDialog> {
  bool _isLoading = true;
  String? _error;

  final ScrollController _scheduleScrollController = ScrollController();
  final ScrollController _scheduleHorizontalScrollController =
      ScrollController();

  List<FundEntry> _schedule = [];

  /// The fund as the server has it: the row, the payouts recorded against it,
  /// and what a payout would hand over today. Opened from a list that may have
  /// been loaded minutes ago, so the passbook asks again rather than printing
  /// figures the card was carrying.
  FundSheet? _sheet;

  Fund get _fund => _sheet?.fund ?? widget.fund;
  String get _customerName =>
      (widget.customerDisplayName?.trim().isNotEmpty ?? false)
          ? widget.customerDisplayName!.trim()
          : _fund.customerName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scheduleScrollController.dispose();
    _scheduleHorizontalScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // `funds.php?action=sheet` is gated server-side to admins/agents only
      // ("Only admins or agents can act on a fund") — it's also the entry
      // point payout/settle actions build on. Customers are read-only
      // viewers here, so their passbook must not call it: every figure it
      // needs is already available on the `Fund` the Funds list fetched for
      // them (`_sheet == null` falls back to `widget.fund` throughout this
      // class), so only the paid-entries list is fetched for a customer.
      if (widget.hideAgentDetails) {
        final entries = await FundApiService.fetchPassbook(widget.fund.id);
        if (!mounted) return;
        setState(() {
          _schedule = _buildSchedule(widget.fund, entries);
          _isLoading = false;
        });
        return;
      }

      final results = await Future.wait([
        FundApiService.fetchPassbook(widget.fund.id),
        FundApiService.fetchSheet(widget.fund.id),
      ]);
      final entries = results[0] as List<FundEntry>;
      final sheet = results[1] as FundSheet;
      if (!mounted) return;
      setState(() {
        _sheet = sheet;
        _schedule = _buildSchedule(sheet.fund, entries);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  static List<FundEntry> _buildSchedule(
      Fund fund, List<FundEntry> paidEntries) {
    final totalWeeks =
        fund.numberOfWeeks > 0 ? fund.numberOfWeeks : paidEntries.length;
    final paymentRows = paidEntries.where((entry) => !entry.isBonus).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final originalPayments = <FundEntry>[];
    var nextFallbackWeek = 1;
    for (final entry in paymentRows) {
      final week = entry.week > 0
          ? entry.week
          : entry.isClosure
              ? totalWeeks
              : nextFallbackWeek++;
      originalPayments.add(entry.week > 0
          ? entry
          : FundEntry(
              week: week,
              date: entry.date,
              amount: entry.amount,
              balanceAfter: entry.balanceAfter,
              method: entry.method,
              notes: entry.notes,
              isClosure: entry.isClosure,
              paid: entry.paid,
            ));
    }
    final schedule = <FundEntry>[...originalPayments]
      ..sort((a, b) => a.week.compareTo(b.week));

    // The database payment rows are the only source for paid history. Add
    // pending rows only to complete the fund's configured number of weeks.
    final paidWeeks = originalPayments.map((entry) => entry.week).toSet();
    for (int week = 1; week <= totalWeeks; week++) {
      if (paidWeeks.contains(week)) continue;
      schedule.add(FundEntry(
        week: week,
        date: fund.startDate.add(Duration(days: 7 * (week - 1))),
        amount: fund.weeklyAmount,
        method: null,
        paid: false,
      ));
    }
    schedule.sort((a, b) => a.week.compareTo(b.week));

    // The bonus is an entry only where it was actually earned. Any fund that
    // was no longer active counted as complete, so one closed early printed a
    // bonus it never received — and the summary above says in as many words
    // that it did not. Once paid, the payout record settles the question.
    final paid = fund.paidOut;
    final bonusEarned = paid != null
        ? paid.bonusPaid
        : (fund.preview?.bonusEarned ??
            (fund.status == FundStatus.matured ||
                (fund.totalDeposit > 0 &&
                    fund.depositedAmount >= fund.totalDeposit - 0.01)));
    final bonus = paid?.bonusAmount ?? fund.maturityBonus;
    if (bonusEarned && bonus > 0) {
      schedule.add(FundEntry(
        week: 0,
        date: paid?.payoutDate ?? fund.maturityDate,
        amount: bonus,
        balanceAfter: fund.depositedAmount + bonus,
        method: 'credited',
        isBonus: true,
        paid: true,
      ));
    }
    return schedule;
  }

  static const _weekdayAbbr = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  int get _paidCount => _schedule.where((e) => e.paid && !e.isBonus).length;

  // DEPOSITED reads straight off fund.depositedAmount — the real
  // funds.collected_amount — rather than summing fund_payments rows, so it
  // can never drift from the number shown on the fund card / stat cards.
  double get _paidSum => _fund.depositedAmount;

  FundEntry? get _nextDue {
    for (final e in _schedule) {
      if (!e.paid && !e.isBonus) return e;
    }
    return null;
  }

  /// What the customer signed up to deposit, whether the bonus was earned, and
  /// the one line that matters — what they are handed.
  ///
  /// Every figure is the server's. Before a payout it is the preview
  /// `FundService` computes from the deposits actually received; after one it
  /// is read back off the `fund_payouts` row that payout wrote, so the
  /// passbook reports what left the safe rather than what this screen would
  /// have worked out. The bonus is the difference between the two states worth
  /// naming: a scheme run to term earns it, one closed early does not.
  Widget _payoutSummary(AppLocalizations l10n, Fund fund) {
    final preview = _sheet?.preview;
    final paid = _sheet?.finalPayout ?? fund.paidOut;

    final weekly = preview?.weeklyAmount ?? fund.weeklyAmount;
    final weeks = preview?.weeks ?? fund.numberOfWeeks;
    final target = preview?.depositTarget ?? fund.totalDeposit;

    final bonusEarned = paid != null
        ? paid.bonusPaid
        : (preview?.bonusEarned ?? fund.effectiveStatus == FundStatus.matured);
    final bonus =
        paid?.bonusAmount ?? preview?.bonusAmount ?? fund.maturityBonus;
    final payable =
        paid?.payoutAmount ?? preview?.payoutAmount ?? fund.payoutAmount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryRow(
              label: l10n.fundPassbookSummaryTotalDeposit(
                  '${weekly.round()}', '$weeks'),
              value: formatIndianCurrency(target)),
          const SizedBox(height: 8),
          _SummaryRow(
            label: l10n.fundPassbookSummaryBonus,
            value: bonusEarned
                ? l10n.fundFormSummaryBonusValue(formatIndianCurrency(bonus))
                : l10n.fundPassbookBonusNotEarned,
            valueColor: bonusEarned ? AppColors.kGold : AppColors.kTextMuted,
          ),
          const Divider(height: 20, color: AppColors.kBorder),
          _SummaryRow(
            label: paid != null
                ? l10n.fundPassbookSummaryPaidOut(formatDate(paid.payoutDate))
                : l10n.fundPassbookSummaryPayableNow,
            value: formatIndianCurrency(payable),
            labelColor: AppColors.kSuccess,
            valueColor: AppColors.kSuccess,
            bold: true,
          ),
          // How the money actually went out, straight off the payout record.
          if (paid != null) ...[
            const SizedBox(height: 6),
            Text(
              [
                paid.paymentMethod.toUpperCase(),
                if (!widget.hideAgentDetails &&
                    paid.agentName != null &&
                    paid.agentName!.isNotEmpty)
                  paid.agentName!,
                if (paid.notes != null && paid.notes!.isNotEmpty) paid.notes!,
              ].join(' · '),
              style: const TextStyle(color: AppColors.kTextMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fund = _fund;
    final next = _nextDue;
    final screenWidth = MediaQuery.of(context).size.width;
    final hPad = screenWidth < 380 ? 14.0 : 24.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.savings_outlined,
                    color: AppColors.kGold, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.fundPassbookTitle,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.kTextDark)),
                    const SizedBox(height: 2),
                    Text(l10n.fundPassbookSubtitle(fund.code, _customerName),
                        style: const TextStyle(
                            color: AppColors.kTextMuted, fontSize: 13)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: fund.status == FundStatus.active
                      ? const Color(0xFFFEF3C7)
                      : const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  fund.status.label,
                  style: TextStyle(
                    color: fund.status == FundStatus.active
                        ? AppColors.kWarning
                        : AppColors.kSuccess,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.close, color: AppColors.kTextMuted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  Text(_error!,
                      style: const TextStyle(color: AppColors.kDanger)),
                  const SizedBox(height: 12),
                  ElevatedButton(
                      onPressed: _load, child: Text(l10n.fundRetryButton)),
                ],
              ),
            )
          else ...[
            LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxWidth < 520;
              final stats = [
                _PassbookStat(
                    label: l10n.fundPassbookDepositedLabel,
                    value: formatIndianCurrency(_paidSum),
                    bg: const Color(0xFFDCFCE7),
                    fg: AppColors.kSuccess),
                _PassbookStat(
                    label: l10n.fundPassbookToDepositLabel,
                    value: formatIndianCurrency((fund.totalDeposit - _paidSum)
                        .clamp(0, double.infinity)
                        .toDouble()),
                    bg: const Color(0xFFF3F4F6),
                    fg: AppColors.kTextDark),
                _PassbookStat(
                    label: l10n.fundPassbookEntriesLabel,
                    value: l10n.fundPassbookEntriesValue(
                        '$_paidCount', '${fund.numberOfWeeks}'),
                    bg: const Color(0xFFFEF3C7),
                    fg: AppColors.kWarning),
              ];
              if (compact) {
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: stats
                      .map((stat) => SizedBox(
                          width: (constraints.maxWidth - 10) / 2, child: stat))
                      .toList(),
                );
              }
              return Row(
                  children: stats
                      .map((stat) => Expanded(
                              child: Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: stat,
                          )))
                      .toList());
            }),
            const SizedBox(height: 16),
            _payoutSummary(l10n, fund),
            if (next != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                    color: const Color(0xFFDBEAFE),
                    borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined,
                        size: 18, color: Color(0xFF2563EB)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF2563EB)),
                          children: [
                            TextSpan(text: l10n.fundPassbookNextDuePrefix),
                            TextSpan(
                              text: l10n.fundPassbookNextDueValue(
                                  formatDate(next.date),
                                  '${next.week}',
                                  formatIndianCurrency(next.amount)),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            // Keep the header and every row on one responsive column grid.
            // The date column takes the spare width; horizontal scrolling is
            // used only when a very narrow screen cannot safely fit the
            // week and amount/balance columns.
            SizedBox(
              height: (MediaQuery.of(context).size.height * 0.38)
                  .clamp(220.0, 420.0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const weekColumnWidth = 35.0;
                  const amountColumnWidth = 112.0;
                  const minimumDateColumnWidth = 150.0;
                  const columnGap = 20.0;
                  const tableHorizontalPadding = 8.0;

                  const tableMinWidth = weekColumnWidth +
                      minimumDateColumnWidth +
                      amountColumnWidth +
                      columnGap +
                      tableHorizontalPadding;

                  final tableWidth = constraints.maxWidth > tableMinWidth
                      ? constraints.maxWidth
                      : tableMinWidth;

                  final dateColumnWidth = tableWidth -
                      weekColumnWidth -
                      amountColumnWidth -
                      columnGap -
                      tableHorizontalPadding;

                  return Scrollbar(
                    controller: _scheduleHorizontalScrollController,
                    thumbVisibility: constraints.maxWidth < tableMinWidth,
                    notificationPredicate: (notification) =>
                        notification.metrics.axis == Axis.horizontal,
                    child: SingleChildScrollView(
                      controller: _scheduleHorizontalScrollController,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: tableWidth,
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 8),
                              color: const Color(0xFFF8FAFC),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: weekColumnWidth,
                                    child: Text('WK',
                                        style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.kTextMuted)),
                                  ),
                                  const SizedBox(width: columnGap),
                                  SizedBox(
                                    width: dateColumnWidth,
                                    child: Text(l10n.fundPassbookColDateMethod,
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.kTextMuted)),
                                  ),
                                  SizedBox(
                                    width: amountColumnWidth,
                                    child: Text(
                                        l10n.fundPassbookColAmountBalance,
                                        textAlign: TextAlign.end,
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.kTextMuted)),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1, color: AppColors.kBorder),
                            Expanded(
                              child: Scrollbar(
                                thumbVisibility: true,
                                controller: _scheduleScrollController,
                                child: ListView.separated(
                                  controller: _scheduleScrollController,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 4),
                                  itemCount: _schedule.length,
                                  separatorBuilder: (_, __) => const Divider(
                                      height: 1, color: AppColors.kBorder),
                                  itemBuilder: (context, i) {
                                    final e = _schedule[i];
                                    if (e.isBonus) {
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: weekColumnWidth,
                                              child: Container(
                                                width: 28,
                                                height: 28,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFFFEF3C7),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                child: const Icon(
                                                    Icons
                                                        .card_giftcard_outlined,
                                                    size: 16,
                                                    color: AppColors.kWarning),
                                              ),
                                            ),
                                            const SizedBox(width: columnGap),
                                            SizedBox(
                                              width: dateColumnWidth,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    l10n.fundPassbookSummaryBonus,
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: AppColors.kWarning,
                                                    ),
                                                  ),
                                                  Text(
                                                    '${formatDate(e.date)} · ${e.method ?? l10n.fundPassbookPaidFallback}',
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        color:
                                                            AppColors.kWarning),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            SizedBox(
                                              width: amountColumnWidth,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    '+ ${formatIndianCurrency(e.amount)}',
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: AppColors.kWarning,
                                                    ),
                                                  ),
                                                  Text(
                                                    l10n.fundPassbookBalanceValue(
                                                        formatIndianCurrency(
                                                            e.balanceAfter ??
                                                                0)),
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        color: AppColors
                                                            .kTextMuted),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }
                                    final isNext =
                                        next != null && e.week == next.week;

                                    final balance = e.balanceAfter ??
                                        _schedule
                                            .take(i + 1)
                                            .where((row) => row.paid)
                                            .fold<double>(0,
                                                (sum, row) => sum + row.amount);

                                    final weekdayLabel = _weekdayAbbr[
                                        (e.date.weekday - 1).clamp(0, 6)];
                                    final dateLabel = e.paid
                                        ? formatDate(e.date)
                                        : '${formatDate(e.date)} ($weekdayLabel)';

                                    return SizedBox(
                                      height: 52,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 6),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: weekColumnWidth,
                                              child: Container(
                                                width: 24,
                                                height: 24,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  color: e.paid
                                                      ? const Color(0xFFFEF3C7)
                                                      : null,
                                                  border: Border.all(
                                                    color: isNext
                                                        ? const Color(
                                                            0xFF2563EB)
                                                        : e.paid
                                                            ? Colors.transparent
                                                            : AppColors.kBorder,
                                                    width: isNext ? 1.5 : 1,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(7),
                                                ),
                                                child: Text('${e.week}',
                                                    style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: isNext
                                                            ? const Color(
                                                                0xFF2563EB)
                                                            : e.paid
                                                                ? AppColors
                                                                    .kGold
                                                                : AppColors
                                                                    .kTextMuted)),
                                              ),
                                            ),
                                            const SizedBox(width: columnGap),
                                            SizedBox(
                                              width: dateColumnWidth,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(dateLabel,
                                                      style: TextStyle(
                                                          fontSize: 12.5,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: isNext
                                                              ? const Color(
                                                                  0xFF2563EB)
                                                              : AppColors
                                                                  .kTextDark)),
                                                  if (isNext ||
                                                      (e.paid &&
                                                          (e.method ?? '')
                                                              .isNotEmpty))
                                                    Text(
                                                      isNext
                                                          ? l10n
                                                              .fundPassbookNextDueRowLabel
                                                          : (e.method ??
                                                              l10n.fundPassbookPaidFallback),
                                                      style: TextStyle(
                                                          fontSize: 11,
                                                          color: isNext
                                                              ? const Color(
                                                                  0xFF2563EB)
                                                              : AppColors
                                                                  .kTextMuted),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            SizedBox(
                                              width: amountColumnWidth,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    e.paid
                                                        ? '+ ${formatIndianCurrency(e.amount)}'
                                                        : formatIndianCurrency(
                                                            e.amount),
                                                    style: TextStyle(
                                                        fontSize: 13.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: e.paid
                                                            ? AppColors.kSuccess
                                                            : AppColors
                                                                .kTextDark),
                                                  ),
                                                  Text(
                                                    e.paid
                                                        ? l10n.fundPassbookBalanceValue(
                                                            formatIndianCurrency(
                                                                balance))
                                                        : l10n
                                                            .fundPassbookPendingLabel,
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color: AppColors
                                                            .kTextMuted),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.fundPassbookCloseButton),
            ),
          ),
        ],
      ),
    );
  }
}

class _PassbookStat extends StatelessWidget {
  const _PassbookStat(
      {required this.label,
      required this.value,
      required this.bg,
      required this.fg});
  final String label;
  final String value;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(value,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
          ),
        ],
      ),
    );
  }
}
