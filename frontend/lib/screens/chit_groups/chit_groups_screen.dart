import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_toast.dart';
import '../../theme/confirm_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../models/chit_group.dart';
import '../../models/chit_member.dart';
import '../../models/chit_passbook.dart';
import '../../models/user_role.dart';
import '../../services/chit_group_api_service.dart';
import '../../services/session_service.dart';
import 'chit_passbook_screen.dart';
import 'package:intl/intl.dart';
import '../../models/chit_schedule.dart';
import '../../models/chit_auction.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/responsive_stat_grid.dart';

// Shared paid/partial/overdue/pending pill styling — used by the Member
// Collections table row and the Installment Schedule's payment status
// column alike, so both pills agree on label and color.
String _paymentStatusLabel(ChitPaymentStatus status, AppLocalizations l10n) {
  switch (status) {
    case ChitPaymentStatus.paid:
      return l10n.paidStatus;
    case ChitPaymentStatus.partial:
      return l10n.partialStatus;
    case ChitPaymentStatus.overdue:
      return l10n.overdueStatus;
    case ChitPaymentStatus.pending:
      return l10n.pendingStatus;
  }
}

Color _paymentStatusBackground(ChitPaymentStatus status) {
  switch (status) {
    case ChitPaymentStatus.paid:
      return const Color(0xFFD1FAE5);
    case ChitPaymentStatus.partial:
      return const Color(0xFFDBEAFE);
    case ChitPaymentStatus.overdue:
      return const Color(0xFFFEE2E2);
    case ChitPaymentStatus.pending:
      return const Color(0xFFFEF3C7);
  }
}

Color _paymentStatusForeground(ChitPaymentStatus status) {
  switch (status) {
    case ChitPaymentStatus.paid:
      return const Color(0xFF059669);
    case ChitPaymentStatus.partial:
      return const Color(0xFF2563EB);
    case ChitPaymentStatus.overdue:
      return AppColors.kDanger;
    case ChitPaymentStatus.pending:
      return const Color(0xFFD97706);
  }
}

class _OverrideScheduleSheet extends StatefulWidget {
  const _OverrideScheduleSheet({required this.schedule});

  final ChitSchedule schedule;

  @override
  State<_OverrideScheduleSheet> createState() => _OverrideScheduleSheetState();
}

class _OverrideScheduleSheetState extends State<_OverrideScheduleSheet> {
  late DateTime _dueDate;
  late final TextEditingController _payableController;
  late final TextEditingController _poolController;
  late final TextEditingController _notesController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _dueDate = widget.schedule.dueDate;
    _payableController = TextEditingController(
        text: widget.schedule.payableAmount.toStringAsFixed(0));
    _poolController = TextEditingController(
        text: widget.schedule.poolAmount.toStringAsFixed(0));
    _notesController =
        TextEditingController(text: widget.schedule.overrideNotes ?? '');
  }

  @override
  void dispose() {
    _payableController.dispose();
    _poolController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _dueDate = picked);
  }

  Future<void> _save() async {
    final payable = double.tryParse(_payableController.text.trim());
    final pool = double.tryParse(_poolController.text.trim());
    if (payable == null || payable < 0 || pool == null || pool < 0) {
      final l10n = AppLocalizations.of(context);
      ToastService.show(
        title: l10n.invalidScheduleValuesTitle,
        message: l10n.invalidScheduleValuesMessage,
        type: ToastType.error,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final updated = await ChitGroupApiService.overrideSchedule(
        scheduleId: widget.schedule.id,
        dueDate: _dueDate,
        payableAmount: payable,
        poolAmount: pool,
        notes: _notesController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ToastService.show(
          title: AppLocalizations.of(context).scheduleUpdateFailedTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // This padding ensures the bottom sheet moves up with the keyboard
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      // FIX: Added a solid white background so the content underneath doesn't show through
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(24)), // Rounds the top corners
      ),
      child: Padding(
        // Apply the keyboard inset dynamically
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          // Makes the content scrollable
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        l10n.overrideDrawTitle(widget.schedule.installmentNo),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: AppColors.kTextDark,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFFF1F5F9),
                      ),
                      icon: const Icon(Icons.close,
                          size: 20, color: AppColors.kTextDark),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _overrideField(l10n.payableAmountLabel, _payableController),
                const SizedBox(height: 16),
                _overrideField(l10n.poolDividendValueLabel, _poolController),
                const SizedBox(height: 16),
                Text(l10n.dueDateLabel,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        color: AppColors.kTextMuted)),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      suffixIcon: const Icon(Icons.calendar_today_outlined,
                          color: AppColors.kTextMuted, size: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                    ),
                    child: Text(
                      formatDate(_dueDate),
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.kTextDark),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _overrideField(l10n.notesLabel, _notesController, maxLines: 2),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            _saving ? null : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          side: const BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                        child: Text(l10n.cancelButton,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.kGold,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.save_outlined, size: 20),
                        label: Text(
                          _saving ? l10n.savingButton : l10n.saveOverrideButton,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Upgraded custom field method with modern styling
  Widget _overrideField(String label, TextEditingController controller,
      {int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: AppColors.kTextMuted)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: maxLines == 1
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.kTextDark),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.kGold, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _SchemePreset {
  const _SchemePreset({
    required this.chipLabel,
    required this.groupName,
    required this.totalMembers,
    required this.durationMonths,
    required this.groupValue,
    required this.monthlyContribution,
    required this.drawFrequencyLabel,
    required this.drawInterval,
    required this.color,
  });

  final String chipLabel;
  final String groupName;
  final int totalMembers;
  final int durationMonths;
  final double groupValue;
  final double monthlyContribution;
  final String drawFrequencyLabel;
  final int drawInterval;
  final Color color;
}

const _schemePresets = <_SchemePreset>[
  _SchemePreset(
    chipLabel: 'Load ₹750 5-Day Scheme',
    groupName: '₹750 5-Day Chit Scheme',
    totalMembers: 30,
    durationMonths: 30,
    groupValue: 28500,
    monthlyContribution: 750,
    drawFrequencyLabel: 'Custom Day Interval',
    drawInterval: 5,
    color: Color(0xFF7C3AED),
  ),
  _SchemePreset(
    chipLabel: 'Load ₹1,420 10-Day Scheme',
    groupName: '₹1,420 10-Day Chit Scheme',
    totalMembers: 30,
    durationMonths: 30,
    groupValue: 57000,
    monthlyContribution: 1420,
    drawFrequencyLabel: 'Every 10 Days',
    drawInterval: 10,
    color: Color(0xFF16A34A),
  ),
  _SchemePreset(
    chipLabel: 'Load ₹5,000 21-Month Scheme',
    groupName: '₹5,000 21-Month Fixed/Variable Scheme',
    totalMembers: 20,
    durationMonths: 21,
    groupValue: 125000,
    monthlyContribution: 5000,
    drawFrequencyLabel: '1 Draw / Month (Monthly)',
    drawInterval: 1,
    color: Color(0xFFCA8A04),
  ),
];

// Draw frequency options for the create/edit group form. Each maps to a
// day-gap between consecutive draw dates (null = calendar-month stepping,
// or "N/A" = dates are picked individually, no auto interval).
const _drawFrequencyOptions = <String>[
  '1 Draw / Month (Monthly)',
  '2 Draws / Month (Bi-Monthly)',
  '3 Draws / Month (Tri-Monthly)',
  'Every 10 Days',
  'Custom Day Interval',
  'Custom Calendar Days',
];

/// Fixed day-gap implied by a draw frequency, or null when the gap is either
/// calendar-month based (Monthly) or user-defined (Custom Day Interval /
/// Custom Calendar Days).
int? _fixedIntervalDaysFor(String frequency) {
  switch (frequency) {
    case '2 Draws / Month (Bi-Monthly)':
      return 15;
    case '3 Draws / Month (Tri-Monthly)':
      return 10;
    case 'Every 10 Days':
      return 10;
    default:
      return null;
  }
}

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

class ChitGroupsScreen extends StatefulWidget {
  const ChitGroupsScreen({super.key});

  @override
  State<ChitGroupsScreen> createState() => _ChitGroupsScreenState();
}

class _ChitGroupsScreenState extends State<ChitGroupsScreen> {
  bool _isLoading = true;
  String? _loadError;
  List<ChitGroup> _groups = [];
  final TextEditingController _searchCtrl = TextEditingController();

  UserRole? get _role => SessionService.instance.role;
  bool get _isAdmin => _role == UserRole.admin || _role == UserRole.owner;
  bool get _isAgent => _role == UserRole.agent;
  bool get _isCustomer => _role == UserRole.customer;

  /// Client-side status filter; null shows every group.
  ChitGroupStatus? _statusFilter;

  List<ChitGroup> get _filteredGroups {
    final query = _searchCtrl.text.trim().toLowerCase();
    return _groups.where((group) {
      if (_statusFilter != null && group.status != _statusFilter) {
        return false;
      }
      if (query.isEmpty) return true;
      return group.name.toLowerCase().contains(query) ||
          group.code.toLowerCase().contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openGroupDetails(ChitGroup group) async {
    if (_isCustomer) {
      await _openCustomerPassbook(group);
      return;
    }
    final updated = await showChitGroupDetailsSheet(context, group);
    if (updated != null && mounted) {
      await _loadGroups();
    }
  }

  /// Customers only ever see their own passbook — never the admin/agent
  /// member-management sheet.
  Future<void> _openCustomerPassbook(ChitGroup group) async {
    try {
      final member = await ChitGroupApiService.fetchMyMembership(group.id);
      if (!mounted) return;
      if (member == null) {
        final l10n = AppLocalizations.of(context);
        ToastService.show(
          title: l10n.notAMemberTitle,
          message: l10n.notAMemberMessage,
          type: ToastType.error,
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChitPassbookScreen(group: group, member: member),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        title: AppLocalizations.of(context).failedOpenPassbookTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Future<void> _loadGroups() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final groups = _isCustomer
          ? await ChitGroupApiService.fetchMyGroups()
          : await ChitGroupApiService.fetchAll();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
      ToastService.show(
        title: AppLocalizations.of(context).failedLoadGroupsTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Future<void> _showCreateGroupModal() async {
    final created = await showModalBottomSheet<ChitGroup>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => const _GroupFormSheet(),
    );
    if (created == null || !mounted) return;
    await _loadGroups();
  }

  Future<void> _showEditGroupModal(ChitGroup group) async {
    final updated = await showModalBottomSheet<ChitGroup>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _GroupFormSheet(group: group),
    );
    if (updated == null || !mounted) return;
    await _loadGroups();
  }

  Future<void> _confirmDeleteGroup(ChitGroup group) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: l10n.deleteGroupTitle,
      message: l10n.deleteGroupMessage(group.name),
      confirmLabel: l10n.deleteButton,
      confirmButtonColor: AppColors.kDanger,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ChitGroupApiService.delete(group.id);
      if (!mounted) return;
      await _loadGroups();
      ToastService.show(
        title: l10n.groupDeletedTitle,
        message: l10n.groupRemovedMessage(group.name),
        type: ToastType.warning,
      );
    } catch (e) {
      ToastService.show(
        title: l10n.deleteFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visibleGroups = _filteredGroups;
    final hasSearchQuery = _searchCtrl.text.trim().isNotEmpty;
    final isFiltered = hasSearchQuery || _statusFilter != null;

    return AppShell(
      currentRoute: AppRoutes.chitGroups,
      title: l10n.chitGroupsTitle,
      body: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: RefreshIndicator(
          onRefresh: _loadGroups,
          child: LayoutBuilder(builder: (context, constraints) {
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
                if (!_isLoading && _loadError == null) _buildStatGrid(),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator())
                else if (_loadError != null)
                  Column(
                    children: [
                      Text(_loadError!,
                          style: const TextStyle(color: AppColors.kDanger)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _loadGroups,
                        child: Text(l10n.retryButton),
                      ),
                    ],
                  )
                else if (visibleGroups.isEmpty)
                  _buildEmptyState(isFiltered
                      ? l10n.noSearchResultsMessage
                      : _isCustomer
                          ? l10n.customerNoGroupMessage
                          : l10n.noGroupsFoundMessage)
                // Phone: single card column. Tablet: two card columns.
                // Wide: full table.
                else if (width >= 1000)
                  _buildGroupTable(visibleGroups, l10n)
                else
                  ..._buildCardRows(visibleGroups,
                      columns: width < 600 ? 1 : 2),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isNarrow, AppLocalizations l10n) {
    final subtitle = Text(
      l10n.chitGroupsSubtitle,
      style: const TextStyle(fontSize: 14, color: AppColors.kTextMuted),
    );
    final createButton = ElevatedButton.icon(
      onPressed: _showCreateGroupModal,
      icon: const Icon(Icons.add),
      label: Text(
        l10n.createGroupButton,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      ),
    );

    if (isNarrow || !_isAdmin) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          subtitle,
          if (_isAdmin) ...[
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
        hintText: l10n.searchHint,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: hasSearchQuery
            ? IconButton(
                tooltip: l10n.clearSearchTooltip,
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.clear, size: 20),
              )
            : null,
      ),
    );

    final filters = <ChitGroupStatus?>[null, ...ChitGroupStatus.values];
    final filterRow = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((status) {
          final isSelected = _statusFilter == status;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(status == null
                  ? l10n.filterAll
                  : _chitStatusLabel(status, l10n)),
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
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AppColors.gold50,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.groups_outlined,
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

  // For a customer `_groups` holds only the groups they are a member of, so
  // every card below is worked out from their own groups.
  Widget _buildStatGrid() {
    final totalGroups = _groups.length;
    final activeGroups =
        _groups.where((g) => g.status == ChitGroupStatus.active).length;
    final totalValue = _groups.fold<double>(0, (sum, g) => sum + g.groupValue);
    final totalCollected =
        _groups.fold<double>(0, (sum, g) => sum + g.collectedAmount);
    // A group's collected total is everyone's money, not the customer's, so
    // customers see what they pay each month across their running groups.
    final monthlyContribution = _groups
        .where((g) => g.status == ChitGroupStatus.active)
        .fold<double>(0, (sum, g) => sum + g.monthlyContribution);

    return Column(
      children: [
        ResponsiveStatGrid(
          children: [
            _StatCard(
              icon: Icons.groups_outlined,
              iconBg: const Color(0xFFFEF3C7),
              iconColor: AppColors.kWarning,
              label: _isCustomer ? 'MY GROUPS' : 'TOTAL GROUPS',
              value: '$totalGroups',
            ),
            _StatCard(
              icon: Icons.trending_up_rounded,
              iconBg: const Color(0xFFDCFCE7),
              iconColor: AppColors.kSuccess,
              label: 'ACTIVE GROUPS',
              value: '$activeGroups',
            ),
            _StatCard(
              icon: Icons.account_balance_wallet_outlined,
              iconBg: const Color(0xFFEDE9FE),
              iconColor: const Color(0xFF7C3AED),
              label: _isCustomer ? 'TOTAL CHIT VALUE' : 'TOTAL VALUE',
              value: formatIndianCurrency(totalValue),
            ),
            _StatCard(
              icon: Icons.monetization_on_outlined,
              iconBg: const Color(0xFFFEF3C7),
              iconColor: AppColors.kGold,
              label: _isCustomer ? 'MONTHLY CONTRIBUTION' : 'TOTAL COLLECTED',
              value: formatIndianCurrency(
                  _isCustomer ? monthlyContribution : totalCollected),
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  List<Widget> _buildCardRows(List<ChitGroup> groups, {required int columns}) {
    if (columns == 1) {
      return [
        for (final g in groups)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _buildGroupCard(g),
          ),
      ];
    }

    final rows = <Widget>[];
    for (var start = 0; start < groups.length; start += columns) {
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
                  child: start + i < groups.length
                      ? _buildGroupCard(groups[start + i], fillHeight: true)
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

  Widget _buildGroupCard(ChitGroup group, {bool fillHeight = false}) {
    final l10n = AppLocalizations.of(context);
    final percent = (group.collectedPercent / 100).clamp(0, 1).toDouble();

    Widget metric(String label, String value) => Expanded(
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
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.kTextDark)),
            ],
          ),
        );

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

    return GestureDetector(
      onTap: () => _openGroupDetails(group),
      child: Container(
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
            // Gold header strip — group no., name, plan and status.
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
                      group.code,
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
                          group.name,
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
                          '${formatIndianCurrency(group.monthlyContribution)}'
                          ' × ${l10n.durationMonthsShort(group.durationMonths)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.kTextOnDarkMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _chitStatusPill(group.status, l10n),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.chitColGroupValue,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.kTextMuted)),
                  const SizedBox(height: 2),
                  Text(
                    formatIndianCurrency(group.groupValue),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.kBackground,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        metric(l10n.membersLabel, '${group.totalMembers}'),
                        metric(l10n.durationLabel,
                            l10n.durationMonthsShort(group.durationMonths)),
                        metric(l10n.chitColStartDate,
                            _formatChitDate(group.startDate)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.collectionProgressLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.kTextMuted),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${formatIndianCurrency(group.collectedAmount)} · '
                        '${group.collectedPercent.toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.kGoldDark,
                        ),
                      ),
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
                ],
              ),
            ),
            if (fillHeight) const Spacer(),
            const Divider(height: 1),
            // Role-specific action strip:
            // - admin: View Details + Edit + Delete
            // - agent: Collect
            // - customer: View Passbook
            Row(
              children: [
                if (_isAdmin)
                  action(Icons.visibility_outlined, l10n.viewDetailsButton,
                      AppColors.kGoldDark, () => _openGroupDetails(group)),
                if (_isAgent)
                  action(Icons.currency_rupee, l10n.collectButton,
                      AppColors.kGoldDark, () => _openGroupDetails(group)),
                if (_isCustomer)
                  action(Icons.menu_book_rounded, l10n.viewPassbookButton,
                      AppColors.kGoldDark, () => _openGroupDetails(group)),
                if (_isAdmin) ...[
                  action(Icons.edit_outlined, l10n.chitActionEdit,
                      AppColors.ink700, () => _showEditGroupModal(group)),
                  action(Icons.delete_outline, l10n.deleteButton,
                      AppColors.kDanger, () => _confirmDeleteGroup(group)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const double _tableHeadingHeight = 50;

  Widget _buildGroupTable(List<ChitGroup> groups, AppLocalizations l10n) {
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
            headingRowHeight: _tableHeadingHeight,
            dataRowMinHeight: 58,
            dataRowMaxHeight: 64,
            columnSpacing: 24,
            dividerThickness: 0.6,
            showCheckboxColumn: false,
            headingTextStyle: const TextStyle(
              color: AppColors.kTextOnDark,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
            dataTextStyle:
                const TextStyle(color: AppColors.kTextDark, fontSize: 13),
            columns: [
              DataColumn(label: Text(l10n.chitColGroupNo)),
              // The name column soaks up spare width so the table always
              // spans the card.
              DataColumn(
                label: Text(l10n.chitColGroupName),
                columnWidth: const MaxColumnWidth(
                    IntrinsicColumnWidth(), FlexColumnWidth()),
              ),
              DataColumn(label: Text(l10n.membersLabel)),
              DataColumn(label: Text(l10n.durationLabel)),
              DataColumn(label: Text(l10n.chitColMonthly)),
              DataColumn(label: Text(l10n.valueLabel)),
              DataColumn(label: Text(l10n.chitColCollected)),
              DataColumn(label: Text(l10n.chitColStartDate)),
              DataColumn(label: Text(l10n.chitColStatus)),
              DataColumn(label: Text(l10n.chitColActions)),
            ],
            rows: [
              for (var i = 0; i < groups.length; i++)
                _buildGroupRow(groups[i], i, l10n),
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
                    // strip (same gold as the group cards) behind the table.
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: _tableHeadingHeight,
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

  DataRow _buildGroupRow(ChitGroup group, int index, AppLocalizations l10n) {
    final percent = (group.collectedPercent / 100).clamp(0, 1).toDouble();

    Widget iconAction(
            IconData icon, Color color, String tooltip, VoidCallback onTap) =>
        IconButton(
          icon: Icon(icon, size: 20),
          color: color,
          tooltip: tooltip,
          onPressed: onTap,
        );

    return DataRow(
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) return AppColors.gold50;
        return index.isOdd ? AppColors.kBackground : AppColors.kSurface;
      }),
      onSelectChanged: (_) => _openGroupDetails(group),
      cells: [
        DataCell(Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.gold50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.gold200),
          ),
          child: Text(group.code,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.kGoldDark)),
        )),
        DataCell(Text(group.name,
            style: const TextStyle(fontWeight: FontWeight.w600))),
        DataCell(Text('${group.totalMembers}')),
        DataCell(Text(l10n.durationMonthsShort(group.durationMonths))),
        DataCell(Text(formatIndianCurrency(group.monthlyContribution))),
        DataCell(Text(formatIndianCurrency(group.groupValue),
            style: const TextStyle(
                fontWeight: FontWeight.w700, color: AppColors.kGoldDark))),
        DataCell(Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${formatIndianCurrency(group.collectedAmount)} · '
                '${group.collectedPercent.toStringAsFixed(1)}%'),
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
        DataCell(Text(_formatChitDate(group.startDate))),
        DataCell(_chitStatusPill(group.status, l10n)),
        DataCell(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAdmin)
              iconAction(Icons.visibility_outlined, AppColors.kGoldDark,
                  l10n.viewDetailsButton, () => _openGroupDetails(group)),
            if (_isAgent)
              iconAction(Icons.currency_rupee, AppColors.kGoldDark,
                  l10n.collectButton, () => _openGroupDetails(group)),
            if (_isCustomer)
              iconAction(Icons.menu_book_rounded, AppColors.kGoldDark,
                  l10n.viewPassbookButton, () => _openGroupDetails(group)),
            if (_isAdmin) ...[
              iconAction(Icons.edit_outlined, AppColors.ink600,
                  l10n.chitActionEdit, () => _showEditGroupModal(group)),
              iconAction(Icons.delete_outline, AppColors.kDanger,
                  l10n.deleteButton, () => _confirmDeleteGroup(group)),
            ],
          ],
        )),
      ],
    );
  }
}

/// Same gold strip as the loan/fund cards and table headers.
const List<Color> _kGoldGradient = [Color(0xFFA9791F), Color(0xFFC48E28)];

String _formatChitDate(DateTime date) =>
    DateFormat('dd MMM yyyy').format(date);

String _chitStatusLabel(ChitGroupStatus status, AppLocalizations l10n) {
  switch (status) {
    case ChitGroupStatus.active:
      return l10n.chitStatusActive;
    case ChitGroupStatus.completed:
      return l10n.chitStatusCompleted;
    case ChitGroupStatus.upcoming:
      return l10n.chitStatusUpcoming;
  }
}

Widget _chitStatusPill(ChitGroupStatus status, AppLocalizations l10n) {
  final Color dot;
  switch (status) {
    case ChitGroupStatus.active:
      dot = AppColors.kSuccess;
      break;
    case ChitGroupStatus.completed:
      dot = AppColors.kTextMuted;
      break;
    case ChitGroupStatus.upcoming:
      dot = AppColors.kWarning;
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
          _chitStatusLabel(status, l10n),
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

class _ScheduleItemConfig {
  _ScheduleItemConfig({
    required this.installmentNo,
    required this.dueDate,
    required this.payableAmount,
    required this.poolAmount,
    this.isCustomDate = false,
  });

  final int installmentNo;
  DateTime dueDate;
  double payableAmount;
  double poolAmount;
  bool isCustomDate;
}

class _GroupFormSheet extends StatefulWidget {
  const _GroupFormSheet({this.group});

  final ChitGroup? group;

  @override
  State<_GroupFormSheet> createState() => _GroupFormSheetState();
}

class _GroupFormSheetState extends State<_GroupFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _codeCtrl;
  late final TextEditingController _membersCtrl;
  late final TextEditingController _durationCtrl;
  late final TextEditingController _valueCtrl;
  late final TextEditingController _contributionCtrl;
  late final TextEditingController _startDateCtrl;
  ChitGroupStatus _status = ChitGroupStatus.active;
  DateTime? _startDate;
  bool _saving = false;
  String _drawFrequency = _drawFrequencyOptions.first;
  late final TextEditingController _drawIntervalCtrl;

  List<_ScheduleItemConfig> _scheduleConfigs = [];
  bool _loadingSchedule = false;
  String _schemeKey = '';

  @override
  void initState() {
    super.initState();
    final group = widget.group;
    final generatedCode = group?.code ??
        'CG-${(DateTime.now().millisecondsSinceEpoch % 1000000).toString().padLeft(6, '0')}';
    _nameCtrl = TextEditingController(text: group?.name ?? '');
    _codeCtrl = TextEditingController(text: generatedCode);
    _membersCtrl =
        TextEditingController(text: group?.totalMembers.toString() ?? '');
    _durationCtrl =
        TextEditingController(text: group?.durationMonths.toString() ?? '');
    _valueCtrl =
        TextEditingController(text: group?.groupValue.toStringAsFixed(0) ?? '');
    _contributionCtrl = TextEditingController(
        text: group?.monthlyContribution.toStringAsFixed(0) ?? '');
    _startDate = group?.startDate ?? DateTime.now();
    _startDateCtrl = TextEditingController(text: formatDate(_startDate));
    // '1 Draw / Month (Monthly)' is the default frequency — it steps by
    // calendar month, not a fixed day gap, so the interval field starts blank.
    _drawIntervalCtrl = TextEditingController();
    if (group != null) _status = group.status;
    if (group != null) {
      _drawFrequency = _frequencyLabelFromBackend(group.drawFrequency);
      _drawIntervalCtrl.text = group.drawDays ?? '';
    }

    _durationCtrl.addListener(_recalculateSchedule);
    _valueCtrl.addListener(_recalculateSchedule);
    _contributionCtrl.addListener(_recalculateSchedule);
    _drawIntervalCtrl.addListener(_recalculateSchedule);

    if (group != null) {
      _loadExistingSchedules(group.id);
    } else {
      _recalculateSchedule();
    }
  }

  @override
  void dispose() {
    _durationCtrl.removeListener(_recalculateSchedule);
    _valueCtrl.removeListener(_recalculateSchedule);
    _contributionCtrl.removeListener(_recalculateSchedule);
    _drawIntervalCtrl.removeListener(_recalculateSchedule);

    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _membersCtrl.dispose();
    _durationCtrl.dispose();
    _valueCtrl.dispose();
    _contributionCtrl.dispose();
    _startDateCtrl.dispose();
    _drawIntervalCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadExistingSchedules(String groupId) async {
    setState(() => _loadingSchedule = true);
    try {
      final schedules = await ChitGroupApiService.fetchSchedules(groupId);
      if (!mounted) return;
      if (schedules.isNotEmpty) {
        setState(() {
          _scheduleConfigs = schedules
              .map((s) => _ScheduleItemConfig(
                    installmentNo: s.installmentNo,
                    dueDate: s.dueDate,
                    payableAmount: s.payableAmount,
                    poolAmount: s.poolAmount,
                    isCustomDate:
                        s.dateType == ChitScheduleDateType.customOverridden,
                  ))
              .toList();
          _loadingSchedule = false;
        });
      } else {
        _loadingSchedule = false;
        _recalculateSchedule();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingSchedule = false);
        _recalculateSchedule();
      }
    }
  }

  // The interval field is only user-editable for 'Custom Day Interval' — the
  // other frequencies imply a fixed gap (or, for 'Custom Calendar Days', no
  // gap at all since every draw date is hand-picked below).
  bool get _isCustomDayInterval => _drawFrequency == 'Custom Day Interval';
  bool get _isCustomCalendarDays => _drawFrequency == 'Custom Calendar Days';
  bool get _isMonthly => _drawFrequency == '1 Draw / Month (Monthly)';
  bool get _showIntervalField => !_isCustomCalendarDays;

  void _onDrawFrequencyChanged(String frequency) {
    setState(() {
      _drawFrequency = frequency;
      final fixed = _fixedIntervalDaysFor(frequency);
      if (fixed != null) {
        _drawIntervalCtrl.text = '$fixed';
      } else if (_isMonthly) {
        _drawIntervalCtrl.clear();
      }
      // Custom Day Interval / Custom Calendar Days: leave whatever the user
      // already typed (or the default '1') in place.
    });
    _recalculateSchedule();
  }

  void _recalculateSchedule() {
    if (_loadingSchedule) return;
    final duration = int.tryParse(_durationCtrl.text.trim()) ?? 0;
    final startDate = _startDate ?? DateTime.now();
    final groupVal = double.tryParse(_valueCtrl.text.trim()) ?? 0;
    final contribution = double.tryParse(_contributionCtrl.text.trim()) ?? 0;

    if (duration <= 0) {
      if (_scheduleConfigs.isNotEmpty) {
        setState(() => _scheduleConfigs = []);
      }
      return;
    }

    // Days between consecutive draws for non-monthly, non-manual frequencies.
    // Falls back to the fixed gap for Bi-Monthly/Tri-Monthly/Every 10 Days,
    // or whatever the admin typed for Custom Day Interval.
    final intervalDays = _isMonthly || _isCustomCalendarDays
        ? null
        : (int.tryParse(_drawIntervalCtrl.text.trim()) ??
            _fixedIntervalDaysFor(_drawFrequency) ??
            30);

    final newConfigs = <_ScheduleItemConfig>[];
    final startsAtZero = _schemeKey == '5000';
    final firstDraw = startsAtZero ? 0 : 1;
    for (int index = 0; index < duration; index++) {
      final i = firstDraw + index;
      DateTime date;
      bool isCustom = false;
      if (index < _scheduleConfigs.length &&
          _scheduleConfigs[index].isCustomDate) {
        // A date the admin hand-picked in the schedule list below always
        // wins, regardless of frequency.
        date = _scheduleConfigs[index].dueDate;
        isCustom = true;
      } else if (_isCustomCalendarDays) {
        // No auto-computed gap — keep the previous value as a starting
        // point (monthly-spaced) so there's something to edit per row.
        date = index < _scheduleConfigs.length
            ? _scheduleConfigs[index].dueDate
            : DateTime(startDate.year, startDate.month + index, startDate.day);
      } else if (_isMonthly) {
        date = DateTime(
          startDate.year,
          startDate.month + index,
          startDate.day,
        );
      } else {
        date = startDate.add(Duration(days: intervalDays! * index));
      }
      final payableAmount = _schemePayableAmount(i, contribution);
      newConfigs.add(_ScheduleItemConfig(
        installmentNo: i,
        dueDate: date,
        payableAmount: payableAmount,
        poolAmount: _schemePoolAmount(i, groupVal),
        isCustomDate: isCustom,
      ));
    }

    setState(() {
      _scheduleConfigs = newConfigs;
    });
  }

  void _applyPreset(_SchemePreset preset) {
    setState(() {
      _schemeKey = preset.monthlyContribution == 750
          ? '750'
          : preset.monthlyContribution == 1420
              ? '1420'
              : '5000';
      _nameCtrl.text = preset.groupName;
      _membersCtrl.text = preset.totalMembers.toString();
      _durationCtrl.text = preset.durationMonths.toString();
      _valueCtrl.text = preset.groupValue.toStringAsFixed(0);
      _contributionCtrl.text = preset.monthlyContribution.toStringAsFixed(0);
      _drawFrequency = preset.drawFrequencyLabel;
      _drawIntervalCtrl.text = preset.drawInterval.toString();
    });
    _recalculateSchedule();
  }

  double _schemePayableAmount(int drawNo, double base) {
    if (_schemeKey == '1420' ||
        (base == 1420 && _drawIntervalCtrl.text == '10')) {
      return 1420 + (drawNo - 1) * 20;
    }
    if (_schemeKey == '750' || (base == 750 && _drawIntervalCtrl.text == '5')) {
      return drawNo <= 5 ? 750 : 750 + (drawNo - 5) * 10;
    }
    if (_schemeKey == '5000' || base == 5000) return 5000;
    return base > 0 ? base : 0;
  }

  double _schemePoolAmount(int drawNo, double groupValue) {
    if (_schemeKey == '1420' ||
        (groupValue == 57000 && _drawIntervalCtrl.text == '10')) {
      return 39600 + (drawNo - 1) * 600;
    }
    if (_schemeKey == '750' ||
        (groupValue == 28500 && _drawIntervalCtrl.text == '5')) {
      return drawNo <= 5 ? 21000 : 21000 + (drawNo - 5) * 300;
    }
    if (_schemeKey == '5000' || groupValue == 125000) {
      if (drawNo == 0) return 0;
      if (drawNo <= 9) return 79000 + drawNo * 1000;
      if (drawNo <= 15) return 80000 + drawNo * 1000;
      return 25000 + drawNo * 5000;
    }
    return groupValue;
  }

  String _backendFrequency() {
    if (_schemeKey == '750') return 'every_5_days';
    if (_schemeKey == '1420') return 'every_10_days';
    if (_schemeKey == '5000') return 'monthly_1';
    if (_drawFrequency == 'Every 10 Days') return 'every_10_days';
    if (_drawFrequency == 'Custom Day Interval') return 'interval_days';
    if (_drawFrequency == '2 Draws / Month (Bi-Monthly)') return 'monthly_2';
    if (_drawFrequency == '3 Draws / Month (Tri-Monthly)') return 'monthly_3';
    return 'monthly_1';
  }

  String _frequencyLabelFromBackend(String value) {
    switch (value) {
      case 'every_5_days':
        return 'Custom Day Interval';
      case 'every_10_days':
        return 'Every 10 Days';
      case 'monthly_2':
        return '2 Draws / Month (Bi-Monthly)';
      case 'monthly_3':
        return '3 Draws / Month (Tri-Monthly)';
      case 'interval_days':
        return 'Custom Day Interval';
      default:
        return '1 Draw / Month (Monthly)';
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _startDate = picked;
      _startDateCtrl.text = formatDate(_startDate);
    });
    _recalculateSchedule();
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    if (_startDate == null) return;

    if (_codeCtrl.text.trim().isEmpty) {
      _codeCtrl.text =
          'CG-${(DateTime.now().millisecondsSinceEpoch % 1000000).toString().padLeft(6, '0')}';
    }

    setState(() => _saving = true);
    final group = ChitGroup(
      id: widget.group?.id ?? '',
      code: _codeCtrl.text.trim(),
      name: _nameCtrl.text.trim(),
      status: _status,
      totalMembers: int.tryParse(_membersCtrl.text.trim()) ?? 0,
      durationMonths: int.tryParse(_durationCtrl.text.trim()) ?? 0,
      groupValue: double.tryParse(_valueCtrl.text.trim()) ?? 0,
      monthlyContribution: double.tryParse(_contributionCtrl.text.trim()) ?? 0,
      startDate: _startDate!,
      collectedAmount: widget.group?.collectedAmount ?? 0,
      drawFrequency: _backendFrequency(),
      drawDays: _drawIntervalCtrl.text.trim().isEmpty
          ? null
          : _drawIntervalCtrl.text.trim(),
    );

    try {
      final result = widget.group == null
          ? await ChitGroupApiService.create(group)
          : await ChitGroupApiService.update(group);

      // The draw sheet — and every member's chit_passbook derived from it —
      // is rebuilt on the server from the group's own stored fields (scheme,
      // duration, contribution, start date), the same rules that auto-build
      // the sheet when a group is first created. The app used to compute the
      // schedule itself and insert it directly into chit_schedules, which
      // collided with the sheet the server had already auto-generated for a
      // brand-new group and left member passbooks out of step with it.
      try {
        await ChitGroupApiService.regenerateSchedule(result.id);
      } catch (_) {}

      // A due date the admin hand-picked in the preview above still wins —
      // reapply it as an override on top of the regenerated sheet.
      final customConfigs =
          _scheduleConfigs.where((cfg) => cfg.isCustomDate).toList();
      if (customConfigs.isNotEmpty) {
        try {
          final rebuilt = await ChitGroupApiService.fetchSchedules(result.id);
          for (final cfg in customConfigs) {
            ChitSchedule? match;
            for (final s in rebuilt) {
              if (s.installmentNo == cfg.installmentNo) {
                match = s;
                break;
              }
            }
            if (match == null) continue;
            await ChitGroupApiService.overrideSchedule(
              scheduleId: match.id,
              dueDate: cfg.dueDate,
              payableAmount: cfg.payableAmount,
              poolAmount: cfg.poolAmount,
            );
          }
        } catch (_) {}
      }

      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      Navigator.of(context).pop(result);
      ToastService.show(
        title: widget.group == null
            ? l10n.groupCreatedTitle
            : l10n.groupUpdatedTitle,
        message: group.name,
        type: ToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ToastService.show(
        title: AppLocalizations.of(context).saveFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Widget _buildScheduleConfigSection() {
    if (_scheduleConfigs.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                l10n.installmentScheduleHeader(_scheduleConfigs.length),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.kTextMuted,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                l10n.autoGeneratedBadge(_scheduleConfigs.length),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.kSuccess,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F8F4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.kBorder),
          ),
          child: Column(
            children: _scheduleConfigs
                .map((cfg) => _ScheduleConfigItemCard(
                      config: cfg,
                      onDateChanged: (newDate) {
                        setState(() {
                          cfg.dueDate = newDate;
                          cfg.isCustomDate = true;
                        });
                      },
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isEditing = widget.group != null;
    final keyboardPadding = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardPadding),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
                color: Colors.black12, blurRadius: 20, offset: Offset(0, -4)),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                      Text(
                        isEditing
                            ? l10n.editGroupTitle
                            : l10n.createGroupSheetTitle,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextDark,
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.close,
                            color: AppColors.kTextMuted),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1EEFC),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.auto_awesome,
                                size: 16, color: Color(0xFF7C3AED)),
                            const SizedBox(width: 6),
                            Text(l10n.quickSchemePresetsLabel,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF4C1D95),
                                    fontSize: 13)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _schemePresets
                              .map((p) => _PresetChip(
                                    preset: p,
                                    onTap: () => _applyPreset(p),
                                  ))
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(l10n.groupNameLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(isDense: true),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? l10n.requiredValidation
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.membersFieldLabel,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.kTextMuted)),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _membersCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(isDense: true),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return l10n.requiredValidation;
                                }
                                if (int.tryParse(v.trim()) == null) {
                                  return l10n.enterNumberValidation;
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.durationFieldLabel,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.kTextMuted)),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _durationCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(isDense: true),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return l10n.requiredValidation;
                                }
                                if (int.tryParse(v.trim()) == null) {
                                  return l10n.enterNumberValidation;
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.groupValueLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _valueCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return l10n.requiredValidation;
                      }
                      if (double.tryParse(v.trim()) == null) {
                        return l10n.enterNumberValidation;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.monthlyContributionLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _contributionCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return l10n.requiredValidation;
                      }
                      if (double.tryParse(v.trim()) == null) {
                        return l10n.enterNumberValidation;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.startDateLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _startDateCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(isDense: true),
                    onTap: _pickStartDate,
                    validator: (v) => v == null || v.trim().isEmpty
                        ? l10n.requiredValidation
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.drawFrequencyLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _drawFrequency,
                    isExpanded: true,
                    items: _drawFrequencyOptions
                        .map((f) => DropdownMenuItem(
                              value: f,
                              child: Text(f, overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) _onDrawFrequencyChanged(v);
                    },
                    decoration: const InputDecoration(isDense: true),
                  ),
                  if (_showIntervalField) ...[
                    const SizedBox(height: 16),
                    Text(l10n.drawIntervalLabel,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.kTextMuted)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _drawIntervalCtrl,
                      keyboardType: TextInputType.number,
                      readOnly: !_isCustomDayInterval,
                      style: TextStyle(
                          color: _isCustomDayInterval
                              ? AppColors.kTextDark
                              : AppColors.kTextMuted),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: l10n.drawIntervalHint,
                        filled: !_isCustomDayInterval,
                        fillColor: const Color(0xFFF3F4F6),
                      ),
                      validator: (v) {
                        if (!_isCustomDayInterval) return null;
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n <= 0) {
                          return l10n.enterDaysValidation;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isMonthly
                          ? l10n.monthlyIntervalHelp
                          : _isCustomDayInterval
                              ? l10n.customIntervalHelp
                              : l10n.fixedIntervalHelp,
                      style: const TextStyle(
                          color: AppColors.kTextMuted, fontSize: 12),
                    ),
                  ] else ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.manualDatesHelp,
                      style: const TextStyle(
                          color: AppColors.kTextMuted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(l10n.statusLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<ChitGroupStatus>(
                    initialValue: _status,
                    items: ChitGroupStatus.values
                        .map((status) => DropdownMenuItem(
                              value: status,
                              child: Text(status.name.toUpperCase()),
                            ))
                        .toList(),
                    onChanged: (value) => setState(() {
                      if (value != null) _status = value;
                    }),
                    decoration: const InputDecoration(isDense: true),
                  ),
                  _buildScheduleConfigSection(),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.cancelButton),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: _saving ? null : _handleSave,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(isEditing
                                ? l10n.saveChangesButton
                                : l10n.createGroupSheetTitle),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScheduleConfigItemCard extends StatelessWidget {
  const _ScheduleConfigItemCard({
    required this.config,
    required this.onDateChanged,
  });

  final _ScheduleItemConfig config;
  final ValueChanged<DateTime> onDateChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.installmentNumberLabel(config.installmentNo),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: AppColors.kTextDark,
                  ),
                ),
              ),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: config.dueDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) onDateChanged(picked);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: config.isCustomDate
                        ? const Color(0xFFEDE9FE)
                        : const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: config.isCustomDate
                          ? const Color(0xFFC4B5FD)
                          : const Color(0xFFD1D5DB),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 13,
                        color: config.isCustomDate
                            ? const Color(0xFF7C3AED)
                            : AppColors.kTextMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        formatDate(config.dueDate),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: config.isCustomDate
                              ? const Color(0xFF7C3AED)
                              : AppColors.kTextDark,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.payableLabel,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.kTextMuted)),
                    Text(
                      formatIndianCurrency(config.payableAmount),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.kSuccess,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.poolDividendValueShortLabel,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.kTextMuted)),
                    Text(
                      formatIndianCurrency(config.poolAmount),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF4C1D95),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.preset, required this.onTap});
  final _SchemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: preset.color.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, size: 14, color: preset.color),
            const SizedBox(width: 6),
            Text(preset.chipLabel,
                style: TextStyle(
                    color: preset.color,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

Future<ChitGroup?> showChitGroupDetailsSheet(
  BuildContext context,
  ChitGroup group,
) {
  return showModalBottomSheet<ChitGroup>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.4),
    builder: (context) => _GroupDetailsFrame(group: group),
  );
}

class _GroupDetailsFrame extends StatefulWidget {
  const _GroupDetailsFrame({required this.group});

  final ChitGroup group;

  @override
  State<_GroupDetailsFrame> createState() => _GroupDetailsFrameState();
}

class _GroupDetailsFrameState extends State<_GroupDetailsFrame> {
  late ChitGroup _group;
  List<ChitMember> _members = [];
  final Map<String, double> _memberCollected = <String, double>{};
  bool _isLoading = true;
  String? _loadError;
  bool _changed = false;

  int _activeTab =
      0; // 0 = Member Collections, 1 = Installment Schedule, 2 = Auctions & Settlement
  List<ChitSchedule> _schedules = [];
  Map<int, ChitScheduleStatusSummary> _scheduleStatus = {};
  final Map<String, int> _memberNextDraw = <String, int>{};
  final Map<String, double> _memberPayableAmount = <String, double>{};
  bool _loadingSchedules = false;
  String? _scheduleLoadError;

  ChitAuctionData? _auctionData;
  bool _loadingAuctions = false;
  String? _auctionLoadError;

  UserRole? get _role => SessionService.instance.role;

  bool get _canAddOrDeleteMembers =>
      _role == UserRole.admin || _role == UserRole.owner;

  /// Only admin/owner can edit or delete installment schedule rows.
  /// Agents get a read-only view — the "Override Date & Amount" action
  /// is not rendered as tappable for them.
  bool get _canManageSchedule =>
      _role == UserRole.admin || _role == UserRole.owner;

  /// Recording who won a draw is open to admins and agents alike — the
  /// same split the backend enforces (ChitActionController only reserves
  /// settle/reverse/delete for admins).
  bool get _canRecordWinner =>
      _role == UserRole.admin ||
      _role == UserRole.owner ||
      _role == UserRole.agent;

  /// Handing over the prize — and undoing that — moves cash, so only an
  /// admin can do it, matching the 403 the backend would otherwise return.
  bool get _canSettlePayout =>
      _role == UserRole.admin || _role == UserRole.owner;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _loadMembers();
    _loadSchedules();
    _loadAuctions();
  }

  Future<void> _loadSchedules() async {
    setState(() {
      _loadingSchedules = true;
      _scheduleLoadError = null;
    });
    try {
      // Kicked off together: the draw sheet itself, and the per-draw
      // payment status folded from every member's chit_passbook row. The
      // status summary is supplementary — if it fails, the schedule still
      // renders, just without the payment status column filled in.
      final schedulesFuture = ChitGroupApiService.fetchSchedules(_group.id);
      final statusFuture =
          ChitGroupApiService.fetchScheduleStatusSummary(_group.id)
              .catchError((_) => <int, ChitScheduleStatusSummary>{});
      final schedules = await schedulesFuture;
      final status = await statusFuture;
      if (!mounted) return;
      setState(() {
        _schedules = schedules;
        _scheduleStatus = status;
        _refreshMemberPayableAmounts();
        _loadingSchedules = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scheduleLoadError = e.toString();
        _loadingSchedules = false;
      });
    }
  }

  Future<void> _openOverrideDialog(ChitSchedule schedule) async {
    if (!_canManageSchedule) return; // hard guard, agents never reach here
    final updated = await showModalBottomSheet<ChitSchedule>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _OverrideScheduleSheet(schedule: schedule),
    );
    if (updated == null || !mounted) return;
    setState(() {
      final idx = _schedules.indexWhere((s) => s.id == updated.id);
      if (idx != -1) _schedules[idx] = updated;
      _refreshMemberPayableAmounts();
      _changed = true;
    });
    final l10n = AppLocalizations.of(context);
    ToastService.show(
      title: l10n.installmentUpdatedTitle,
      message: l10n.drawOverriddenMessage(updated.installmentNo),
      type: ToastType.success,
    );
  }

  Future<void> _loadAuctions() async {
    setState(() {
      _loadingAuctions = true;
      _auctionLoadError = null;
    });
    try {
      final data = await ChitGroupApiService.fetchAuctions(_group.id);
      if (!mounted) return;
      setState(() {
        _auctionData = data;
        _loadingAuctions = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _auctionLoadError = e.toString();
        _loadingAuctions = false;
      });
    }
  }

  Future<void> _openRecordWinnerSheet(ChitAuctionDraw draw) async {
    if (!_canRecordWinner) return; // hard guard, customers never reach here
    final result = await showModalBottomSheet<ChitAuctionData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _RecordAuctionSheet(
        group: _group,
        draw: draw,
        members: _members,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _auctionData = result;
      _changed = true;
    });
    ToastService.show(
      title: 'Winner recorded',
      message: 'Draw #${draw.installmentNo} settlement updated',
      type: ToastType.success,
    );
  }

  Future<void> _openPayOutSheet(ChitAuctionDraw draw) async {
    final auction = draw.auction;
    if (!_canSettlePayout || auction == null) return;
    final result = await showModalBottomSheet<ChitAuctionData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _PayOutAuctionSheet(draw: draw, auction: auction),
    );
    if (result == null || !mounted) return;
    setState(() {
      _auctionData = result;
      _changed = true;
    });
    ToastService.show(
      title: 'Payout recorded',
      message:
          'Draw #${draw.installmentNo} prize handed over to ${auction.memberName ?? 'the winner'}',
      type: ToastType.success,
    );
  }

  Future<void> _confirmReversePayout(ChitAuctionDraw draw) async {
    final auction = draw.auction;
    if (!_canSettlePayout || auction == null) return;
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: 'Reverse this payout?',
      message:
          'This removes the ${formatIndianCurrency(auction.payoutAmount)} cash-out entry for Draw #${draw.installmentNo} and marks the prize unpaid again.',
      confirmLabel: 'Reverse',
      confirmButtonColor: AppColors.kDanger,
    );
    if (confirmed != true || !mounted) return;
    try {
      final result =
          await ChitGroupApiService.reverseAuctionPayout(auctionId: auction.id);
      if (!mounted) return;
      setState(() {
        _auctionData = result;
        _changed = true;
      });
      ToastService.show(
        title: 'Payout reversed',
        message: 'Draw #${draw.installmentNo} is awaiting payout again',
        type: ToastType.warning,
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        title: 'Could not reverse payout',
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Future<void> _confirmDeleteAuction(ChitAuctionDraw draw) async {
    final auction = draw.auction;
    if (!_canRecordWinner || auction == null) return;
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: 'Remove this winner record?',
      message:
          'This clears the recorded winner for Draw #${draw.installmentNo}. It only works before the prize is paid out.',
      confirmLabel: 'Remove',
      confirmButtonColor: AppColors.kDanger,
    );
    if (confirmed != true || !mounted) return;
    try {
      final result =
          await ChitGroupApiService.deleteAuction(auctionId: auction.id);
      if (!mounted) return;
      setState(() {
        _auctionData = result;
        _changed = true;
      });
      ToastService.show(
        title: 'Winner record removed',
        message: 'Draw #${draw.installmentNo} is open again',
        type: ToastType.warning,
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        title: 'Could not remove that record',
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Future<void> _loadMembers() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final members = await ChitGroupApiService.fetchMembers(_group.id);
      final passbooks = await Future.wait(members.map((member) async {
        try {
          return (
            member.id,
            await ChitGroupApiService.fetchPassbook(member.id)
          );
        } catch (_) {
          return (member.id, null);
        }
      }));
      final collected = <String, double>{};
      final nextDraws = <String, int>{};
      for (final entry in passbooks) {
        collected[entry.$1] =
            (entry.$2?.receipts ?? const <ChitPaymentReceipt>[])
                .fold<double>(0, (sum, receipt) => sum + receipt.amount);
        final nextDrawNumber = entry.$2?.nextDueDraw?.drawNumber;
        if (nextDrawNumber != null) nextDraws[entry.$1] = nextDrawNumber;
      }
      if (!mounted) return;
      setState(() {
        _members = members;
        _memberCollected
          ..clear()
          ..addAll(collected);
        _memberNextDraw
          ..clear()
          ..addAll(nextDraws);
        _refreshMemberPayableAmounts();
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

  void _refreshMemberPayableAmounts() {
    _memberPayableAmount
      ..clear()
      ..addEntries(
        _memberNextDraw.entries.map((entry) {
          final schedule = _schedules.cast<ChitSchedule?>().firstWhere(
                (item) => item?.installmentNo == entry.value,
                orElse: () => null,
              );
          return schedule == null
              ? null
              : MapEntry(entry.key, schedule.payableAmount);
        }).whereType<MapEntry<String, double>>(),
      );
  }

  Future<void> _openAddMember() async {
    final added = await showModalBottomSheet<ChitMember>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => _AddMemberFrame(group: _group),
    );
    if (added == null || !mounted) return;
    setState(() {
      _members = [..._members, added];
      _changed = true;
    });
    ToastService.show(
      title: AppLocalizations.of(context).memberAddedTitle,
      message: added.memberName,
      type: ToastType.success,
    );
  }

  Future<void> _confirmDeleteMember(ChitMember member) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: l10n.removeMemberTitle,
      message: l10n.removeMemberMessage(member.memberName),
      confirmLabel: l10n.removeButton,
      confirmButtonColor: AppColors.kDanger,
    );
    if (confirmed != true || !mounted) return;

    try {
      await ChitGroupApiService.deleteMember(member.id);
      if (!mounted) return;
      setState(() {
        _members.removeWhere((m) => m.id == member.id);
        _changed = true;
      });
      ToastService.show(
        title: l10n.memberRemovedTitle,
        message: member.memberName,
        type: ToastType.warning,
      );
    } catch (e) {
      ToastService.show(
        title: l10n.removeFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Future<void> _collect(ChitMember member) async {
    ChitSchedule? nextDraw;
    if (member.customerId != null) {
      final passbook = await ChitGroupApiService.fetchPassbook(member.id);
      final nextDrawNumber = passbook.nextDueDraw?.drawNumber;
      for (final schedule in _schedules) {
        if (schedule.installmentNo == nextDrawNumber) {
          nextDraw = schedule;
          break;
        }
      }
    }
    final draw = nextDraw ?? (_schedules.isEmpty ? null : _schedules.first);
    if (draw == null) {
      final l10n = AppLocalizations.of(context);
      ToastService.show(
        title: l10n.collectionUnavailableTitle,
        message: l10n.noScheduleMessage,
        type: ToastType.error,
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ChitCollectionSheet(
        member: member,
        group: _group,
        draw: draw,
        onSubmit: (amount, method, date, notes) =>
            _saveCollection(member, draw, amount, method, date, notes),
      ),
    );
  }

  Future<void> _saveCollection(ChitMember member, ChitSchedule draw,
      double amount, String method, DateTime date, String? notes) async {
    try {
      // One call to the server: it writes the cash-book receipt and the
      // chit_payments row in a transaction, then derives the member's
      // passbook status (paid/partial/overdue/pending) and the group's
      // running totals from what was actually stored, instead of this
      // screen guessing a flat paid/partial status and patching the group
      // totals by hand.
      final result = await ChitGroupApiService.collectContribution(
        groupId: _group.id,
        memberId: member.id,
        amount: amount,
        paymentMethod: method,
        paymentDate: date,
        notes: notes,
      );

      final wasFullyCollected = _group.isFullyCollected;
      if (!mounted) return;
      setState(() {
        _group = result.group;
        final memberIndex = _members.indexWhere((item) => item.id == member.id);
        if (memberIndex != -1) _members[memberIndex] = result.member;
        _memberCollected[member.id] = result.passbookRows.fold<double>(
            0,
            (sum, row) =>
                sum + (double.tryParse('${row['paid_amount'] ?? 0}') ?? 0));
        _changed = true;
      });
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      // Once this collection has brought the group's total up to (or past)
      // its required group value, the running-total toast is replaced with
      // a one-time "fully collected" toast — the Collect button for every
      // member is disabled from this point on (see _buildTableRow).
      if (!wasFullyCollected && _group.isFullyCollected) {
        ToastService.show(
          title: l10n.collectionCompleteTitle,
          message: l10n.collectionCompleteMessage,
          type: ToastType.success,
        );
      } else {
        ToastService.show(
          title: l10n.collectionRecordedTitle,
          message: l10n.collectionRecordedMessage(
              member.memberName, formatIndianCurrency(amount)),
          type: ToastType.success,
        );
      }

      // The draw just paid against changes that draw's payment status (and
      // possibly others, for a lump-sum payment) on the Installment Schedule
      // tab. Reload it now so it's showing current data the moment the user
      // switches tabs, rather than whatever was last fetched. The Auctions &
      // Settlement tab's "collected so far" figure is derived from the same
      // chit_passbook rows, so it needs the same refresh.
      unawaited(_loadMembers());
      unawaited(_loadSchedules());
      unawaited(_loadAuctions());
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        title: AppLocalizations.of(context).collectionFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final keyboardPadding = MediaQuery.of(context).viewInsets.bottom;
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.85;

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
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _group.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.kTextDark),
                      ),
                    ),
                    IconButton(
                      icon:
                          const Icon(Icons.close, color: AppColors.kTextMuted),
                      onPressed: () =>
                          Navigator.of(context).pop(_changed ? _group : null),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: _isLoading
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : _loadError != null
                          ? Column(
                              children: [
                                Text(_loadError!,
                                    style: const TextStyle(
                                        color: AppColors.kDanger)),
                                const SizedBox(height: 12),
                                ElevatedButton(
                                    onPressed: _loadMembers,
                                    child: Text(l10n.retryButton)),
                              ],
                            )
                          : _buildContent(l10n),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: _DetailStat(
                    label: l10n.groupNumberShortLabel, value: _group.code)),
            Expanded(
                child: _DetailStat(
                    label: l10n.membersLabel, value: '${_group.totalMembers}')),
            Expanded(
                child: _DetailStat(
                    label: l10n.valueLabel,
                    value: formatIndianCurrency(_group.groupValue))),
            Expanded(
                child: _DetailStat(
                    label: l10n.durationLabel,
                    value: l10n.durationMonthsShort(_group.durationMonths))),
          ],
        ),
        const SizedBox(height: 20),

        // Upgraded Progress Container with shadow and clean borders
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE2E8F0)), // Softer border
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.collectionProgressLabel,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  Text(
                    '${formatIndianCurrency(_group.collectedAmount)} / ${formatIndianCurrency(_group.groupValue)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.kTextMuted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: (_group.collectedPercent / 100).clamp(0, 1).toDouble(),
                  minHeight: 10,
                  backgroundColor: const Color(0xFFF1EFE8),
                  valueColor: const AlwaysStoppedAnimation(AppColors.kGold),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _Dot(color: AppColors.kSuccess),
                      const SizedBox(width: 8),
                      Text(
                          'Collected ${formatIndianCurrency(_group.collectedAmount)}',
                          style: const TextStyle(
                              color: AppColors.kSuccess,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _Dot(color: AppColors.kDanger),
                      const SizedBox(width: 8),
                      Text(
                          'Pending ${formatIndianCurrency(_group.pendingAmount)}',
                          style: const TextStyle(
                              color: AppColors.kDanger,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // FIX: Scrollable row prevents the "out of screen" overflow error
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _TabButton(
                icon: Icons.people_alt_outlined,
                label: l10n.memberCollectionsTab(_members.length),
                selected: _activeTab == 0,
                onTap: () => setState(() => _activeTab = 0),
              ),
              const SizedBox(width: 24),
              _TabButton(
                icon: Icons.calendar_month_outlined,
                label: l10n.installmentScheduleTab(_schedules.length),
                selected: _activeTab == 1,
                onTap: () => setState(() => _activeTab = 1),
              ),
              const SizedBox(width: 24),
              _TabButton(
                icon: Icons.emoji_events_outlined,
                label:
                    'Auctions & Settlement (${_auctionData?.summary.totalDraws ?? _schedules.length})',
                selected: _activeTab == 2,
                onTap: () => setState(() => _activeTab = 2),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        const SizedBox(height: 20),

        if (_activeTab == 0)
          _buildMemberSection(l10n)
        else if (_activeTab == 1)
          _buildScheduleSection(l10n)
        else
          _buildAuctionSection(l10n),
      ],
    );
  }

  Widget _buildMemberSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(l10n.memberCollectionTrackingTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: AppColors.kTextDark)),
            ),
            if (_canAddOrDeleteMembers)
              TextButton.icon(
                onPressed: _openAddMember,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(
                      0xFF6B46C1), // Matches the purple "Add Member" in the image
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: Text(l10n.addMemberButton,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (_members.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(l10n.noMembersMessage,
                  style: const TextStyle(
                      color: AppColors.kTextMuted, fontSize: 15)),
            ),
          )
        else
          // Wrapping the table in a horizontal scroll view makes it mobile responsive
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: ConstrainedBox(
              // Ensures the table expands to at least the full width of the screen
              constraints: BoxConstraints(
                  minWidth: MediaQuery.of(context).size.width - 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Table Header Row
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF8FAFC), // Light gray header background
                    ),
                    child: Row(
                      children: [
                        _buildTableHeader(l10n.memberColumnHeader, 180),
                        _buildTableHeader(l10n.contributionColumnHeader, 120),
                        _buildTableHeader(l10n.dueDateColumnHeader, 130),
                        _buildTableHeader(l10n.statusColumnHeader, 100),
                        _buildTableHeader(l10n.actionColumnHeader, 140,
                            alignRight: true),
                      ],
                    ),
                  ),
                  // Table Data Rows
                  ..._members.map((m) => _buildTableRow(m, l10n)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // Helper for consistent table headers
  Widget _buildTableHeader(String title, double width,
      {bool alignRight = false}) {
    return SizedBox(
      width: width,
      child: Text(
        title,
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
        style: const TextStyle(
          color: Color(0xFF64748B),
          fontWeight: FontWeight.w600,
          fontSize: 12,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // Helper replacing the old _MemberRow to match the table format.
  Widget _buildTableRow(ChitMember member, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
      ),
      child: Row(
        children: [
          // 1. MEMBER COLUMN
          SizedBox(
            width: 180,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.memberName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.kTextDark,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.phone_outlined,
                        size: 14, color: Color(0xFF94A3B8)),
                    const SizedBox(width: 4),
                    Text(member.phone ?? 'N/A',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF94A3B8))),
                  ],
                ),
              ],
            ),
          ),

          // 2. CONTRIBUTION COLUMN
          SizedBox(
            width: 120,
            child: Text(
                formatIndianCurrency(_memberPayableAmount[member.id] ??
                    member.contributionAmount),
                style: const TextStyle(
                    color: AppColors.kTextDark,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ),

          // 3. DUE DATE COLUMN
          SizedBox(
            width: 130,
            child: Row(
              children: [
                Text(formatDate(member.dueDate ?? DateTime.now()),
                    style: const TextStyle(
                        color: AppColors.kTextDark, fontSize: 14)),
                const SizedBox(width: 6),
                const Icon(Icons.calendar_today_outlined,
                    size: 14, color: Color(0xFF94A3B8)),
              ],
            ),
          ),

          // 4. STATUS COLUMN
          SizedBox(
            width: 100,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _paymentStatusBackground(member.status),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _paymentStatusLabel(member.status, l10n),
                  style: TextStyle(
                    color: _paymentStatusForeground(member.status),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),

          // 5. ACTION COLUMN
          SizedBox(
            width: 140,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  // Only the group's overall progress gates this button — a
                  // member being individually marked "paid" for their latest
                  // draw doesn't stop future collections against them, only
                  // the group hitting its full required amount does.
                  onPressed:
                      _group.isFullyCollected ? null : () => _collect(member),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        const Color(0xFF059669), // Green matching the image
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.currency_rupee, size: 18),
                  label: Text(l10n.collectButton,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (_canAddOrDeleteMembers) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.person_remove_outlined,
                        color: AppColors.kDanger, size: 20),
                    onPressed: () => _confirmDeleteMember(member),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Installment Schedule',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: AppColors.kTextDark)),
        const SizedBox(height: 4),
        Text(
          l10n.installmentScheduleSubtitle,
          style: const TextStyle(
              color: AppColors.kTextMuted, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (_loadingSchedules)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_scheduleLoadError != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(_scheduleLoadError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.kDanger)),
                const SizedBox(height: 12),
                ElevatedButton(
                    onPressed: _loadSchedules,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.kDanger,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l10n.retryButton)),
              ],
            ),
          )
        else if (_schedules.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(l10n.noScheduleFoundMessage,
                  style: const TextStyle(
                      color: AppColors.kTextMuted, fontSize: 15)),
            ),
          )
        else
          _ScheduleTable(
            schedules: _schedules,
            statusByDraw: _scheduleStatus,
            canOverride: _canManageSchedule,
            onOverride: _openOverrideDialog,
          ),
      ],
    );
  }

  Widget _buildAuctionSection(AppLocalizations l10n) {
    final data = _auctionData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Auctions & Settlement',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: AppColors.kTextDark)),
        const SizedBox(height: 4),
        const Text(
          'Record who won each draw and hand the prize over — the money '
          'moves through the group\'s cash book the moment you pay it out.',
          style:
              TextStyle(color: AppColors.kTextMuted, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (_loadingAuctions)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_auctionLoadError != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(_auctionLoadError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.kDanger)),
                const SizedBox(height: 12),
                ElevatedButton(
                    onPressed: _loadAuctions,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.kDanger,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l10n.retryButton)),
              ],
            ),
          )
        else if (data == null || data.draws.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text('No draw schedule available yet.',
                  style: TextStyle(color: AppColors.kTextMuted, fontSize: 15)),
            ),
          )
        else ...[
          _AuctionSummaryStrip(summary: data.summary),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, constraints) {
            final mobile = constraints.maxWidth < _kAuctionMobileBreakpoint;
            return mobile
                ? _AuctionCardList(
                    draws: data.draws,
                    canRecordWinner: _canRecordWinner,
                    canSettlePayout: _canSettlePayout,
                    onRecordWinner: _openRecordWinnerSheet,
                    onPayOut: _openPayOutSheet,
                    onReverse: _confirmReversePayout,
                    onDelete: _confirmDeleteAuction,
                  )
                : _AuctionTable(
                    draws: data.draws,
                    canRecordWinner: _canRecordWinner,
                    canSettlePayout: _canSettlePayout,
                    onRecordWinner: _openRecordWinnerSheet,
                    onPayOut: _openPayOutSheet,
                    onReverse: _confirmReversePayout,
                    onDelete: _confirmDeleteAuction,
                  );
          }),
        ],
      ],
    );
  }
}

class _DetailStat extends StatelessWidget {
  const _DetailStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: AppColors.kTextMuted, fontSize: 12)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: AppColors.kTextDark)),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class _ChitCollectionSheet extends StatefulWidget {
  const _ChitCollectionSheet({
    required this.member,
    required this.group,
    required this.draw,
    required this.onSubmit,
  });

  final ChitMember member;
  final ChitGroup group;
  final ChitSchedule draw;
  final void Function(double, String, DateTime, String?) onSubmit;

  @override
  State<_ChitCollectionSheet> createState() => _ChitCollectionSheetState();
}

class _ChitCollectionSheetState extends State<_ChitCollectionSheet> {
  late final TextEditingController _amountController;
  final _notesController = TextEditingController();
  String _method = 'Cash';
  DateTime _date = DateTime.now();

  static const _methods = ['Cash', 'UPI', 'Bank Transfer', 'Cheque', 'Card'];

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: widget.draw.payableAmount.round().toString(),
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) return;
    final method = {
      'Cash': 'cash',
      'UPI': 'upi',
      'Bank Transfer': 'bank',
      'Cheque': 'cheque',
      'Card': 'card',
    }[_method]!;
    widget.onSubmit(amount, method, _date, _notesController.text);
    Navigator.of(context).pop();
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.kGold, width: 1.5),
        ),
      );

  Widget _label(String text, {bool required = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: RichText(
          text: TextSpan(
            text: text,
            style: const TextStyle(
              color: AppColors.kTextMuted,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            children: required
                ? const [
                    TextSpan(
                      text: ' *',
                      style: TextStyle(color: AppColors.kDanger),
                    ),
                  ]
                : null,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        color: AppColors.kSurface,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 22, 14, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(l10n.recordChitCollectionTitle,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon:
                          const Icon(Icons.close, color: AppColors.kTextMuted),
                    ),
                  ],
                ),
                const Divider(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9F9FB),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.member.memberName,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(
                              '${formatIndianCurrency(widget.member.contributionAmount)} ${widget.group.name} (${widget.group.code})',
                              style: const TextStyle(
                                  color: AppColors.kTextMuted, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                      Text(formatIndianCurrency(widget.draw.payableAmount),
                          style: const TextStyle(
                              color: Color(0xFF7C3AED),
                              fontSize: 17,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _label(l10n.collectionAmountLabel, required: true),
                TextField(
                  controller: _amountController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _decoration('0'),
                ),
                const SizedBox(height: 26),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _label(l10n.paymentMethodLabel, required: true),
                          DropdownButtonFormField<String>(
                            initialValue: _method,
                            decoration: _decoration(l10n.selectMethodHint),
                            items: _methods
                                .map((method) => DropdownMenuItem(
                                    value: method, child: Text(method)))
                                .toList(),
                            onChanged: (value) =>
                                setState(() => _method = value ?? 'Cash'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _label(l10n.collectionDateLabel, required: true),
                          InkWell(
                            onTap: _pickDate,
                            child: InputDecorator(
                              decoration: _decoration(l10n.dateHint),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(DateFormat('dd/MM/yyyy').format(_date)),
                                  const Icon(Icons.calendar_today_outlined,
                                      size: 19),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                _label(l10n.notesOptionalLabel),
                TextField(
                  controller: _notesController,
                  decoration: _decoration(l10n.receiptNotesHint),
                ),
                const SizedBox(height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 17),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16))),
                      child: Text(l10n.cancelButton),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.currency_rupee),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFB47A05),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 17),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      label: Text(l10n.confirmCollectionButton),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.canDelete,
    required this.onCollect,
    required this.onDelete,
  });

  final ChitMember member;
  final bool canDelete;
  final VoidCallback? onCollect;
  final VoidCallback onDelete;

  Color get _statusBg {
    switch (member.status) {
      case ChitPaymentStatus.paid:
        return const Color(0xFFDCFCE7);
      case ChitPaymentStatus.partial:
        return const Color(0xFFDBEAFE);
      case ChitPaymentStatus.overdue:
        return const Color(0xFFFEE2E2);
      case ChitPaymentStatus.pending:
        return const Color(0xFFFEF3C7);
    }
  }

  Color get _statusFg {
    switch (member.status) {
      case ChitPaymentStatus.paid:
        return AppColors.kSuccess;
      case ChitPaymentStatus.partial:
        return const Color(0xFF2563EB);
      case ChitPaymentStatus.overdue:
        return AppColors.kDanger;
      case ChitPaymentStatus.pending:
        return AppColors.kWarning;
    }
  }

  String get _statusLabel {
    final s = member.status.name;
    return s[0].toUpperCase() + s.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.memberName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.kTextDark)),
                if (member.phone != null) ...[
                  const SizedBox(height: 2),
                  Text(member.phone!,
                      style: const TextStyle(
                          color: AppColors.kTextMuted, fontSize: 12)),
                ],
                const SizedBox(height: 4),
                Text(
                  member.dueDate != null
                      ? '${formatIndianCurrency(member.contributionAmount)} · Due ${formatDate(member.dueDate!)}'
                      : formatIndianCurrency(member.contributionAmount),
                  style: const TextStyle(
                      color: AppColors.kTextMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: _statusBg, borderRadius: BorderRadius.circular(999)),
            child: Text(
              _statusLabel,
              style: TextStyle(
                  color: _statusFg, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (onCollect != null) ...[
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: onCollect,
              icon: const Icon(Icons.currency_rupee_rounded, size: 16),
              label: const Text('Collect'),
            ),
          ],
          if (canDelete) ...[
            const SizedBox(width: 2),
            IconButton(
              icon: const Icon(Icons.person_remove_alt_1_outlined,
                  color: AppColors.kDanger, size: 20),
              onPressed: onDelete,
            ),
          ],
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.kGold : AppColors.kTextMuted;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 13)),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              height: 2,
              color: selected ? AppColors.kGold : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

const _scheduleHeaderStyle = TextStyle(
    fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.kTextMuted);

class _ScheduleTable extends StatelessWidget {
  const _ScheduleTable({
    required this.schedules,
    required this.statusByDraw,
    required this.canOverride,
    required this.onOverride,
  });

  final List<ChitSchedule> schedules;
  final Map<int, ChitScheduleStatusSummary> statusByDraw;
  final bool canOverride;
  final ValueChanged<ChitSchedule> onOverride;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Always a table — narrow screens scroll it horizontally instead of
    // falling back to stacked cards, matching the office's paper draw sheet.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            // tightFor, not minWidth alone: a minWidth-only BoxConstraints
            // leaves maxWidth at infinity, which the header/data Rows below
            // (Expanded cells) can't lay out against — "RenderFlex children
            // have non-zero flex but incoming width constraints are
            // unbounded", and the whole table silently fails to paint.
            constraints: BoxConstraints.tightFor(
                width: constraints.maxWidth > 820 ? constraints.maxWidth : 820),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.kBorder),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF6F5F1),
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(14)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                            flex: 1,
                            child: Text(l10n.instNumberColumnHeader,
                                style: _scheduleHeaderStyle)),
                        Expanded(
                            flex: 2,
                            child: Text(l10n.dueDateColumnHeader,
                                style: _scheduleHeaderStyle)),
                        Expanded(
                            flex: 2,
                            child: Text(l10n.payableAmountColumnHeader,
                                style: _scheduleHeaderStyle)),
                        Expanded(
                            flex: 2,
                            child: Text(l10n.poolDividendValueColumnHeader,
                                style: _scheduleHeaderStyle)),
                        Expanded(
                            flex: 2,
                            child: Text(l10n.paymentStatusColumnHeader,
                                style: _scheduleHeaderStyle)),
                        Expanded(
                            flex: 2,
                            child: Text(l10n.dateTypeColumnHeader,
                                style: _scheduleHeaderStyle)),
                        Expanded(
                            flex: 2,
                            child: Text(l10n.actionColumnHeader,
                                style: _scheduleHeaderStyle)),
                      ],
                    ),
                  ),
                  ...schedules.map((s) => _ScheduleRow(
                        schedule: s,
                        summary: statusByDraw[s.installmentNo],
                        canOverride: canOverride,
                        onOverride: () => onOverride(s),
                      )),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.schedule,
    required this.summary,
    required this.canOverride,
    required this.onOverride,
  });

  final ChitSchedule schedule;
  final ChitScheduleStatusSummary? summary;
  final bool canOverride;
  final VoidCallback onOverride;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isCustom = schedule.dateType == ChitScheduleDateType.customOverridden;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.kBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: Text('#${schedule.installmentNo}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          Expanded(
            flex: 2,
            child: Text(formatDate(schedule.dueDate),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 2,
            child: Text(formatIndianCurrency(schedule.payableAmount),
                style: const TextStyle(
                    color: AppColors.kSuccess, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 2,
            child: Text(formatIndianCurrency(schedule.poolAmount),
                style: const TextStyle(
                    color: Color(0xFF4C1D95), fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 2,
            child: summary == null
                ? Text(l10n.viewOnlyLabel,
                    style: const TextStyle(
                        color: AppColors.kTextMuted, fontSize: 12))
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _paymentStatusBackground(summary!.status),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _paymentStatusLabel(summary!.status, l10n),
                            style: TextStyle(
                              color: _paymentStatusForeground(summary!.status),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.scheduleMembersPaidLabel(
                            summary!.paidMembers,
                            summary!.totalMembers,
                            formatIndianCurrency(summary!.paidAmount),
                          ),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.kTextMuted),
                        ),
                      ],
                    ),
                  ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isCustom
                      ? const Color(0xFFEDE9FE)
                      : const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCustom)
                      const Icon(Icons.schedule,
                          size: 12, color: Color(0xFF7C3AED)),
                    if (isCustom) const SizedBox(width: 4),
                    Text(
                      isCustom
                          ? l10n.customOverriddenBadge
                          : l10n.autoScheduledBadge,
                      style: TextStyle(
                        color: isCustom
                            ? const Color(0xFF7C3AED)
                            : AppColors.kSuccess,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: canOverride
                ? TextButton.icon(
                    onPressed: onOverride,
                    icon: const Icon(Icons.edit_calendar_outlined, size: 15),
                    label: Text(l10n.overrideDateAmountButton,
                        style: const TextStyle(fontSize: 12)),
                  )
                : Text(l10n.viewOnlyLabel,
                    style: const TextStyle(
                        color: AppColors.kTextMuted, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// -----------------------------------------------------------------------
/// ADD MEMBER SHEET (image 1 mockup)
/// -----------------------------------------------------------------------
class _AddMemberFrame extends StatefulWidget {
  const _AddMemberFrame({required this.group});
  final ChitGroup group;

  @override
  State<_AddMemberFrame> createState() => _AddMemberFrameState();
}

class _AddMemberFrameState extends State<_AddMemberFrame> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountCtrl;
  List<ChitCustomerOption> _customers = [];
  ChitCustomerOption? _selectedCustomer;
  bool _loadingCustomers = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
        text: widget.group.monthlyContribution.round().toString());
    _loadCustomers();
  }

  Future<void> _loadCustomers() async {
    setState(() {
      _loadingCustomers = true;
      _loadError = null;
    });
    try {
      final customers = await ChitGroupApiService.fetchCustomers();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _loadingCustomers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loadingCustomers = false;
      });
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (_selectedCustomer == null) {
      final l10n = AppLocalizations.of(context);
      ToastService.show(
        title: l10n.selectCustomerTitle,
        message: l10n.selectCustomerMessage,
        type: ToastType.error,
      );
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final member = await ChitGroupApiService.addMember(
        groupId: widget.group.id,
        customerId: _selectedCustomer!.id,
        memberName: _selectedCustomer!.name,
        phone: _selectedCustomer!.phone,
        contributionAmount: double.parse(_amountCtrl.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(member);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ToastService.show(
        title: AppLocalizations.of(context).addMemberFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final keyboardPadding = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardPadding),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
                color: Colors.black12, blurRadius: 20, offset: Offset(0, -4)),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                      Text(l10n.addMemberTitle,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.kTextDark)),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.close,
                            color: AppColors.kTextMuted),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(l10n.customerLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  _loadingCustomers
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: LinearProgressIndicator(),
                        )
                      : _loadError != null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_loadError!,
                                    style: const TextStyle(
                                        color: AppColors.kDanger)),
                                TextButton(
                                    onPressed: _loadCustomers,
                                    child: Text(l10n.retryButton)),
                              ],
                            )
                          : DropdownButtonFormField<ChitCustomerOption>(
                              initialValue: _selectedCustomer,
                              isExpanded: true,
                              decoration: const InputDecoration(isDense: true),
                              hint: Text(l10n.selectCustomerHint),
                              items: _customers
                                  .map((c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(c.displayLabel,
                                            overflow: TextOverflow.ellipsis),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedCustomer = v),
                              validator: (v) =>
                                  v == null ? l10n.requiredValidation : null,
                            ),
                  if (_selectedCustomer != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.phone_outlined,
                            size: 16, color: AppColors.kTextMuted),
                        const SizedBox(width: 6),
                        Text(
                          _selectedCustomer!.phone?.trim().isNotEmpty == true
                              ? l10n.customerRolePhone(
                                  _selectedCustomer!.role.toUpperCase(),
                                  _selectedCustomer!.phone!)
                              : l10n.customerNumberNotAvailable(
                                  _selectedCustomer!.role.toUpperCase()),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.kTextMuted),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(l10n.contributionAmountLabel,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.kTextMuted)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _amountCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(isDense: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return l10n.requiredValidation;
                      }
                      if (num.tryParse(v) == null) {
                        return l10n.enterValidNumberValidation;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.defaultsToAmount(
                        formatIndianCurrency(widget.group.monthlyContribution)),
                    style: const TextStyle(
                        color: AppColors.kTextMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.cancelButton),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: _saving ? null : _handleSave,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.person_add_alt_1),
                        label: Text(l10n.addMemberButton),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================================
/// AUCTIONS & SETTLEMENT — draw sheet: who won, discount, payout, dividend.
/// ============================================================================

// Below this width the 9-column draw sheet stops fitting a table row
// legibly and switches to a stacked card per draw, same idea as the
// passbook screen's own mobile breakpoint.
const double _kAuctionMobileBreakpoint = 760;

String _auctionStatusLabel(ChitAuctionStatus status) {
  switch (status) {
    case ChitAuctionStatus.settled:
      return 'Paid Out';
    case ChitAuctionStatus.won:
      return 'Awaiting Payout';
    case ChitAuctionStatus.open:
      return 'Not Drawn';
  }
}

Color _auctionStatusForeground(ChitAuctionStatus status) {
  switch (status) {
    case ChitAuctionStatus.settled:
      return AppColors.kSuccess;
    case ChitAuctionStatus.won:
      return AppColors.kWarning;
    case ChitAuctionStatus.open:
      return AppColors.kTextMuted;
  }
}

Color _auctionStatusBackground(ChitAuctionStatus status) {
  switch (status) {
    case ChitAuctionStatus.settled:
      return const Color(0xFFD1FAE5);
    case ChitAuctionStatus.won:
      return const Color(0xFFFEF3C7);
    case ChitAuctionStatus.open:
      return const Color(0xFFF1F5F9);
  }
}

const _auctionLabelStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.bold,
    letterSpacing: 0.5,
    color: AppColors.kTextMuted);

InputDecoration _auctionFieldDecoration({String? hint, Widget? suffixIcon}) {
  return InputDecoration(
    hintText: hint,
    isDense: true,
    filled: true,
    fillColor: const Color(0xFFF8FAFC),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    suffixIcon: suffixIcon,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.kGold, width: 1.5),
    ),
  );
}

class _AuctionHCell extends StatelessWidget {
  const _AuctionHCell(this.label, {required this.flex});
  final String label;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(label,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: AppColors.kTextMuted)),
    );
  }
}

class _AuctionStatusPill extends StatelessWidget {
  const _AuctionStatusPill({required this.status});
  final ChitAuctionStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _auctionStatusBackground(status),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _auctionStatusLabel(status),
        style: TextStyle(
            color: _auctionStatusForeground(status),
            fontSize: 11,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// ---- summary strip ----
class _AuctionSummaryStrip extends StatelessWidget {
  const _AuctionSummaryStrip({required this.summary});
  final ChitAuctionGroupSummary summary;

  @override
  Widget build(BuildContext context) {
    final drawsHeld = summary.won + summary.settled;
    final stats = <Widget>[
      _AuctionStatCard(
          label: 'Draws Held', value: '$drawsHeld / ${summary.totalDraws}'),
      _AuctionStatCard(
          label: 'Paid Out',
          value: formatIndianCurrency(summary.paidOut),
          color: AppColors.kSuccess),
      _AuctionStatCard(
          label: 'Awaiting Payout',
          value: formatIndianCurrency(summary.pendingPayout),
          color: AppColors.kWarning),
      _AuctionStatCard(
          label: 'Dividend Shared',
          value: formatIndianCurrency(summary.dividendTotal),
          color: const Color(0xFF4C1D95)),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final perRow = constraints.maxWidth < 480 ? 2 : 4;
      final gap = 12.0 * (perRow - 1);
      final width = (constraints.maxWidth - gap) / perRow;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: stats.map((s) => SizedBox(width: width, child: s)).toList(),
      );
    });
  }
}

class _AuctionStatCard extends StatelessWidget {
  const _AuctionStatCard(
      {required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.kTextMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  color: color ?? AppColors.kTextDark,
                  fontWeight: FontWeight.w800,
                  fontSize: 17)),
        ],
      ),
    );
  }
}

/// Shared logic for what the ACTION column/card shows for one draw — record
/// a winner, edit/pay one out, or reverse a completed payout — gated the
/// same way the backend gates the underlying requests (ChitActionController:
/// record_auction is admin+agent, settle/reverse/delete are admin-only).
List<Widget> _auctionActions({
  required ChitAuctionDraw draw,
  required bool canRecordWinner,
  required bool canSettlePayout,
  required ValueChanged<ChitAuctionDraw> onRecordWinner,
  required ValueChanged<ChitAuctionDraw> onPayOut,
  required ValueChanged<ChitAuctionDraw> onReverse,
  required ValueChanged<ChitAuctionDraw> onDelete,
}) {
  if (draw.status == ChitAuctionStatus.open) {
    if (!canRecordWinner) {
      return [
        const Text('—', style: TextStyle(color: AppColors.kTextMuted)),
      ];
    }
    return [
      TextButton.icon(
        onPressed: () => onRecordWinner(draw),
        style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF7C3AED),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        icon: const Icon(Icons.auto_fix_high, size: 15),
        label: const Text('Record Winner',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    ];
  }

  if (draw.status == ChitAuctionStatus.won) {
    return [
      if (canRecordWinner)
        TextButton.icon(
          onPressed: () => onRecordWinner(draw),
          style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF7C3AED),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          icon: const Icon(Icons.edit_outlined, size: 15),
          label: const Text('Edit', style: TextStyle(fontSize: 12)),
        ),
      if (canSettlePayout)
        TextButton.icon(
          onPressed: () => onPayOut(draw),
          style: TextButton.styleFrom(
              foregroundColor: AppColors.kSuccess,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          icon: const Icon(Icons.payments_outlined, size: 15),
          label: const Text('Pay Out',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      if (canRecordWinner)
        IconButton(
          icon: const Icon(Icons.close, size: 16, color: AppColors.kDanger),
          tooltip: 'Remove winner record',
          onPressed: () => onDelete(draw),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
    ];
  }

  // settled — the prize has already been paid out.
  if (!canSettlePayout) {
    return [
      const Text('Paid',
          style: TextStyle(
              color: AppColors.kSuccess,
              fontWeight: FontWeight.w600,
              fontSize: 12)),
    ];
  }
  return [
    TextButton.icon(
      onPressed: () => onReverse(draw),
      style: TextButton.styleFrom(
          foregroundColor: AppColors.kDanger,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: const Icon(Icons.undo, size: 15),
      label: const Text('Reverse', style: TextStyle(fontSize: 12)),
    ),
  ];
}

/// ---- wide-screen table ----
class _AuctionTable extends StatelessWidget {
  const _AuctionTable({
    required this.draws,
    required this.canRecordWinner,
    required this.canSettlePayout,
    required this.onRecordWinner,
    required this.onPayOut,
    required this.onReverse,
    required this.onDelete,
  });

  final List<ChitAuctionDraw> draws;
  final bool canRecordWinner;
  final bool canSettlePayout;
  final ValueChanged<ChitAuctionDraw> onRecordWinner;
  final ValueChanged<ChitAuctionDraw> onPayOut;
  final ValueChanged<ChitAuctionDraw> onReverse;
  final ValueChanged<ChitAuctionDraw> onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints.tightFor(
              width: constraints.maxWidth > 1040 ? constraints.maxWidth : 1040),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.kBorder),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF6F5F1),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(14)),
                  ),
                  child: const Row(
                    children: [
                      _AuctionHCell('DRAW #', flex: 1),
                      _AuctionHCell('DATE', flex: 2),
                      _AuctionHCell('POOL', flex: 2),
                      _AuctionHCell('WINNER', flex: 3),
                      _AuctionHCell('DISCOUNT', flex: 2),
                      _AuctionHCell('PAYOUT', flex: 2),
                      _AuctionHCell('DIVIDEND', flex: 2),
                      _AuctionHCell('STATUS', flex: 2),
                      _AuctionHCell('ACTION', flex: 3),
                    ],
                  ),
                ),
                ...draws.map((d) => _AuctionRow(
                      draw: d,
                      canRecordWinner: canRecordWinner,
                      canSettlePayout: canSettlePayout,
                      onRecordWinner: onRecordWinner,
                      onPayOut: onPayOut,
                      onReverse: onReverse,
                      onDelete: onDelete,
                    )),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _AuctionRow extends StatelessWidget {
  const _AuctionRow({
    required this.draw,
    required this.canRecordWinner,
    required this.canSettlePayout,
    required this.onRecordWinner,
    required this.onPayOut,
    required this.onReverse,
    required this.onDelete,
  });

  final ChitAuctionDraw draw;
  final bool canRecordWinner;
  final bool canSettlePayout;
  final ValueChanged<ChitAuctionDraw> onRecordWinner;
  final ValueChanged<ChitAuctionDraw> onPayOut;
  final ValueChanged<ChitAuctionDraw> onReverse;
  final ValueChanged<ChitAuctionDraw> onDelete;

  @override
  Widget build(BuildContext context) {
    final auction = draw.auction;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.kBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 1,
            child: Text('#${draw.installmentNo}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          Expanded(
            flex: 2,
            child: Text(formatDate(auction?.auctionDate ?? draw.dueDate)),
          ),
          Expanded(
            flex: 2,
            child: Text(formatIndianCurrency(draw.poolAmount),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 3,
            child: auction?.memberName == null
                ? const Text('—', style: TextStyle(color: AppColors.kTextMuted))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.emoji_events,
                          size: 15, color: Color(0xFFCA8A04)),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(auction!.memberName!,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
          ),
          Expanded(
            flex: 2,
            child: Text(auction == null
                ? '—'
                : formatIndianCurrency(auction.bidAmount)),
          ),
          Expanded(
            flex: 2,
            child: Text(
                auction == null
                    ? '—'
                    : formatIndianCurrency(auction.payoutAmount),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Expanded(
            flex: 2,
            child: Text(
                auction == null
                    ? '—'
                    : formatIndianCurrency(auction.dividendTotal),
                style: const TextStyle(color: Color(0xFF4C1D95))),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _AuctionStatusPill(status: draw.status),
            ),
          ),
          Expanded(
            flex: 3,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: _auctionActions(
                draw: draw,
                canRecordWinner: canRecordWinner,
                canSettlePayout: canSettlePayout,
                onRecordWinner: onRecordWinner,
                onPayOut: onPayOut,
                onReverse: onReverse,
                onDelete: onDelete,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---- narrow-screen cards ----
class _AuctionCardList extends StatelessWidget {
  const _AuctionCardList({
    required this.draws,
    required this.canRecordWinner,
    required this.canSettlePayout,
    required this.onRecordWinner,
    required this.onPayOut,
    required this.onReverse,
    required this.onDelete,
  });

  final List<ChitAuctionDraw> draws;
  final bool canRecordWinner;
  final bool canSettlePayout;
  final ValueChanged<ChitAuctionDraw> onRecordWinner;
  final ValueChanged<ChitAuctionDraw> onPayOut;
  final ValueChanged<ChitAuctionDraw> onReverse;
  final ValueChanged<ChitAuctionDraw> onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: draws
          .map((d) => _AuctionCard(
                draw: d,
                canRecordWinner: canRecordWinner,
                canSettlePayout: canSettlePayout,
                onRecordWinner: onRecordWinner,
                onPayOut: onPayOut,
                onReverse: onReverse,
                onDelete: onDelete,
              ))
          .toList(),
    );
  }
}

class _AuctionCard extends StatelessWidget {
  const _AuctionCard({
    required this.draw,
    required this.canRecordWinner,
    required this.canSettlePayout,
    required this.onRecordWinner,
    required this.onPayOut,
    required this.onReverse,
    required this.onDelete,
  });

  final ChitAuctionDraw draw;
  final bool canRecordWinner;
  final bool canSettlePayout;
  final ValueChanged<ChitAuctionDraw> onRecordWinner;
  final ValueChanged<ChitAuctionDraw> onPayOut;
  final ValueChanged<ChitAuctionDraw> onReverse;
  final ValueChanged<ChitAuctionDraw> onDelete;

  @override
  Widget build(BuildContext context) {
    final auction = draw.auction;
    final accent = _auctionStatusForeground(draw.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.kBorder),
        boxShadow: [
          BoxShadow(
            color: AppColors.ink900.withOpacity(0.05),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(accent),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildWinnerBlock(auction),
                const SizedBox(height: 12),
                _buildFigures(auction),
                const SizedBox(height: 14),
                ..._buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Status-tinted band: which draw, when, and where it stands — the
  /// context you need before any money on the card means anything.
  Widget _buildHeader(Color accent) {
    final auction = draw.auction;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _auctionStatusBackground(draw.status).withOpacity(0.55),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: const Border(bottom: BorderSide(color: AppColors.kBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Draw #${draw.installmentNo}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: accent == AppColors.kTextMuted
                          ? AppColors.kTextDark
                          : accent),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const Icon(Icons.event_outlined,
                        size: 13, color: AppColors.kTextMuted),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        formatDate(auction?.auctionDate ?? draw.dueDate),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.kTextMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _AuctionStatusPill(status: draw.status),
        ],
      ),
    );
  }

  /// The one thing everyone looks for first — who took this draw.
  Widget _buildWinnerBlock(ChitAuctionRecord? auction) {
    final name = auction?.memberName;
    final hasWinner = name != null && name.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: hasWinner ? const Color(0xFFFFFBEB) : AppColors.ink50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: hasWinner ? const Color(0xFFF3DA88) : AppColors.kBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hasWinner ? const Color(0xFFFAEDC4) : AppColors.ink100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              hasWinner ? Icons.emoji_events : Icons.hourglass_empty,
              size: 18,
              color: hasWinner ? const Color(0xFFCA8A04) : AppColors.kTextMuted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(hasWinner ? 'WINNER' : 'NO WINNER YET',
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: AppColors.kTextMuted)),
                const SizedBox(height: 2),
                Text(
                  hasWinner ? name : 'Draw not held',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color:
                        hasWinner ? AppColors.kTextDark : AppColors.kTextMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Money block: the two figures that matter side by side, the two
  /// supporting ones as chips underneath so nothing gets squeezed at 320px.
  Widget _buildFigures(ChitAuctionRecord? auction) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.ink50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _AuctionFigure(
                  label: 'Chit Pool',
                  value: formatIndianCurrency(draw.poolAmount),
                ),
              ),
              Container(
                width: 1,
                height: 38,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: AppColors.kBorder,
              ),
              Expanded(
                child: _AuctionFigure(
                  label: 'Winner Gets',
                  value: auction == null
                      ? '—'
                      : formatIndianCurrency(auction.payoutAmount),
                  color: auction == null
                      ? AppColors.kTextMuted
                      : AppColors.kSuccess,
                ),
              ),
            ],
          ),
          if (auction != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.kBorder),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _AuctionChip(
                  icon: Icons.trending_down,
                  label: 'Discount',
                  value: formatIndianCurrency(auction.bidAmount),
                  color: AppColors.kTextDark,
                ),
                _AuctionChip(
                  icon: Icons.groups_outlined,
                  label: 'Dividend',
                  value: formatIndianCurrency(auction.dividendTotal),
                  color: const Color(0xFF4C1D95),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Full-width, thumb-sized actions instead of the desktop table's tiny
  /// text buttons — same permission gates as [_auctionActions].
  List<Widget> _buildActions() {
    switch (draw.status) {
      case ChitAuctionStatus.open:
        if (!canRecordWinner) {
          return const [
            _AuctionNote(
              icon: Icons.schedule,
              text: 'Waiting for this draw to be held.',
              color: AppColors.kTextMuted,
            ),
          ];
        }
        return [
          _AuctionPrimaryButton(
            icon: Icons.auto_fix_high,
            label: 'Record Winner',
            color: const Color(0xFF7C3AED),
            onPressed: () => onRecordWinner(draw),
          ),
        ];

      case ChitAuctionStatus.won:
        final rowButtons = <Widget>[
          if (canRecordWinner)
            _AuctionSecondaryButton(
              icon: Icons.edit_outlined,
              label: 'Edit',
              color: const Color(0xFF7C3AED),
              onPressed: () => onRecordWinner(draw),
            ),
          if (canRecordWinner)
            _AuctionSecondaryButton(
              icon: Icons.delete_outline,
              label: 'Remove',
              color: AppColors.kDanger,
              onPressed: () => onDelete(draw),
            ),
        ];
        return [
          if (canSettlePayout)
            _AuctionPrimaryButton(
              icon: Icons.payments_outlined,
              label: draw.auction == null
                  ? 'Pay Out'
                  : 'Pay Out ${formatIndianCurrency(draw.auction!.payoutAmount)}',
              color: AppColors.kSuccess,
              onPressed: () => onPayOut(draw),
            ),
          if (canSettlePayout && rowButtons.isNotEmpty)
            const SizedBox(height: 8),
          if (rowButtons.isNotEmpty)
            Row(
              children: [
                for (var i = 0; i < rowButtons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: rowButtons[i]),
                ],
              ],
            ),
          if (!canSettlePayout && rowButtons.isEmpty)
            const _AuctionNote(
              icon: Icons.hourglass_bottom,
              text: 'Winner recorded — payout pending.',
              color: AppColors.kWarning,
            ),
        ];

      case ChitAuctionStatus.settled:
        return [
          const _AuctionNote(
            icon: Icons.check_circle,
            text: 'Prize paid out to the winner.',
            color: AppColors.kSuccess,
          ),
          if (canSettlePayout) ...[
            const SizedBox(height: 8),
            _AuctionSecondaryButton(
              icon: Icons.undo,
              label: 'Reverse Payout',
              color: AppColors.kDanger,
              onPressed: () => onReverse(draw),
              fullWidth: true,
            ),
          ],
        ];
    }
  }
}

/// One headline figure inside the money block.
class _AuctionFigure extends StatelessWidget {
  const _AuctionFigure({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.kTextMuted)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              maxLines: 1,
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: color ?? AppColors.kTextDark)),
        ),
      ],
    );
  }
}

/// Supporting figure — small enough to sit two-up on the narrowest phone.
class _AuctionChip extends StatelessWidget {
  const _AuctionChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color.withOpacity(0.8)),
          const SizedBox(width: 6),
          Text('$label ',
              style:
                  const TextStyle(fontSize: 12, color: AppColors.kTextMuted)),
          Text(value,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

/// Filled, full-width call to action — the one thing to do on this draw.
class _AuctionPrimaryButton extends StatelessWidget {
  const _AuctionPrimaryButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// Outlined companion action, sized for a thumb rather than a mouse.
class _AuctionSecondaryButton extends StatelessWidget {
  const _AuctionSecondaryButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.fullWidth = false,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: fullWidth ? double.infinity : null,
      height: 44,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 17),
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          backgroundColor: color.withOpacity(0.04),
          side: BorderSide(color: color.withOpacity(0.35)),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Status line shown where there is nothing for this user to press.
class _AuctionNote extends StatelessWidget {
  const _AuctionNote(
      {required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        ),
      ],
    );
  }
}

/// ---- record / edit a draw's winner ----
class _RecordAuctionSheet extends StatefulWidget {
  const _RecordAuctionSheet({
    required this.group,
    required this.draw,
    required this.members,
  });

  final ChitGroup group;
  final ChitAuctionDraw draw;
  final List<ChitMember> members;

  @override
  State<_RecordAuctionSheet> createState() => _RecordAuctionSheetState();
}

class _RecordAuctionSheetState extends State<_RecordAuctionSheet> {
  String? _memberId;
  late final TextEditingController _bidCtrl;
  late final TextEditingController _commissionCtrl;
  late final TextEditingController _notesCtrl;
  late DateTime _auctionDate;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.draw.auction;
    _memberId = existing?.memberId;
    _bidCtrl = TextEditingController(
        text: existing != null && existing.bidAmount > 0
            ? existing.bidAmount.toStringAsFixed(0)
            : '');
    _commissionCtrl = TextEditingController(
        text: existing != null && existing.commission > 0
            ? existing.commission.toStringAsFixed(0)
            : '');
    _notesCtrl = TextEditingController(text: existing?.notes ?? '');
    _auctionDate = existing?.auctionDate ?? DateTime.now();
    _bidCtrl.addListener(_recalc);
    _commissionCtrl.addListener(_recalc);
  }

  void _recalc() => setState(() {});

  @override
  void dispose() {
    _bidCtrl.removeListener(_recalc);
    _commissionCtrl.removeListener(_recalc);
    _bidCtrl.dispose();
    _commissionCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  double get _pool => widget.draw.poolAmount;
  double get _bid => double.tryParse(_bidCtrl.text.trim()) ?? 0;
  double get _commission => double.tryParse(_commissionCtrl.text.trim()) ?? 0;
  double get _winnerReceives => (_pool - _bid).clamp(0, double.infinity);
  double get _dividendShare => (_bid - _commission).clamp(0, double.infinity);

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _auctionDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _auctionDate = picked);
  }

  Future<void> _save() async {
    if (_memberId == null || _memberId!.isEmpty) {
      setState(() => _error = 'Choose who won this draw.');
      return;
    }
    if (_bid > _pool) {
      setState(() => _error =
          'The discount cannot be more than the pool of ${formatIndianCurrency(_pool)}');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ChitGroupApiService.recordAuctionWinner(
        groupId: widget.group.id,
        installmentNo: widget.draw.installmentNo,
        memberId: _memberId!,
        bidAmount: _bid,
        commission: _commission,
        auctionDate: _auctionDate,
        notes: _notesCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final isEditing = widget.draw.auction != null;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Draw #${widget.draw.installmentNo} — ${isEditing ? 'Edit Winner' : 'Record Winner'}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: AppColors.kTextDark,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFF1F5F9)),
                      icon: const Icon(Icons.close,
                          size: 20, color: AppColors.kTextDark),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1EEFC),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(
                          color: Color(0xFF4C1D95), fontSize: 13),
                      children: [
                        const TextSpan(text: 'Pool for this draw: '),
                        TextSpan(
                            text: formatIndianCurrency(_pool),
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        const TextSpan(text: ' · collected so far '),
                        TextSpan(
                            text: formatIndianCurrency(widget.draw.collected),
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text.rich(TextSpan(
                  text: 'WINNER',
                  style: _auctionLabelStyle,
                  children: [
                    TextSpan(
                        text: ' *', style: TextStyle(color: AppColors.kDanger)),
                  ],
                )),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: widget.members.any((m) => m.id == _memberId)
                      ? _memberId
                      : null,
                  isExpanded: true,
                  hint: const Text('Select a member…'),
                  decoration: _auctionFieldDecoration(),
                  items: widget.members
                      .map((m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.memberName,
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _memberId = v),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('DISCOUNT / BID (₹)',
                              style: _auctionLabelStyle),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _bidCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: _auctionFieldDecoration(hint: '0'),
                          ),
                          const SizedBox(height: 4),
                          const Text('Leave blank for a fixed-payout scheme',
                              style: TextStyle(
                                  color: AppColors.kTextMuted, fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('COMMISSION (₹)',
                              style: _auctionLabelStyle),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _commissionCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: _auctionFieldDecoration(hint: '0'),
                          ),
                          const SizedBox(height: 4),
                          const Text('Taken out of the discount',
                              style: TextStyle(
                                  color: AppColors.kTextMuted, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('AUCTION DATE', style: _auctionLabelStyle),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: _auctionFieldDecoration(
                      suffixIcon: const Icon(Icons.calendar_today_outlined,
                          color: AppColors.kTextMuted, size: 18),
                    ),
                    child: Text(formatDate(_auctionDate),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AppColors.kTextDark)),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFECFDF5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('WINNER RECEIVES',
                                style: TextStyle(
                                    color: AppColors.kSuccess,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(formatIndianCurrency(_winnerReceives),
                                style: const TextStyle(
                                    color: AppColors.kSuccess,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7E0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('DIVIDEND TO SHARE',
                                style: TextStyle(
                                    color: Color(0xFFB45309),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(formatIndianCurrency(_dividendShare),
                                style: const TextStyle(
                                    color: Color(0xFFB45309),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('NOTES', style: _auctionLabelStyle),
                const SizedBox(height: 8),
                TextField(
                  controller: _notesCtrl,
                  maxLines: 2,
                  decoration: _auctionFieldDecoration(hint: 'Optional'),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Recording the winner does not move money. Use Pay Out when '
                  'the prize is actually handed over.',
                  style: TextStyle(color: AppColors.kTextMuted, fontSize: 12),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(
                          color: AppColors.kDanger, fontSize: 13)),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            _saving ? null : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          side: const BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                        child: const Text('Cancel',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.kGold,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.emoji_events_outlined, size: 20),
                        label: Text(
                          _saving ? 'Saving…' : 'Save Winner',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ---- pay a recorded winner out (admin) ----
class _PayOutAuctionSheet extends StatefulWidget {
  const _PayOutAuctionSheet({required this.draw, required this.auction});

  final ChitAuctionDraw draw;
  final ChitAuctionRecord auction;

  @override
  State<_PayOutAuctionSheet> createState() => _PayOutAuctionSheetState();
}

class _PayOutAuctionSheetState extends State<_PayOutAuctionSheet> {
  String _method = 'Cash';
  DateTime _date = DateTime.now();
  final _notesCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  static const _methods = ['Cash', 'UPI', 'Bank Transfer', 'Cheque', 'Card'];
  static const _methodValues = {
    'Cash': 'cash',
    'UPI': 'upi',
    'Bank Transfer': 'bank',
    'Cheque': 'cheque',
    'Card': 'card',
  };

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ChitGroupApiService.settleAuctionPayout(
        auctionId: widget.auction.id,
        paymentMethod: _methodValues[_method]!,
        payoutDate: _date,
        notes: _notesCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final shortfall = widget.draw.collected < widget.auction.payoutAmount;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Draw #${widget.draw.installmentNo} — Pay Out',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: AppColors.kTextDark,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFF1F5F9)),
                      icon: const Icon(Icons.close,
                          size: 20, color: AppColors.kTextDark),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      const Text('PAYING TO',
                          style: TextStyle(
                              color: AppColors.kSuccess,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                              letterSpacing: 0.5)),
                      const SizedBox(height: 6),
                      Text(widget.auction.memberName ?? 'Winner',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: AppColors.kTextDark)),
                      const SizedBox(height: 6),
                      Text(formatIndianCurrency(widget.auction.payoutAmount),
                          style: const TextStyle(
                              color: AppColors.kSuccess,
                              fontWeight: FontWeight.w800,
                              fontSize: 24)),
                    ],
                  ),
                ),
                if (shortfall) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7E0),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFCE3A6)),
                    ),
                    child: Text(
                      'Only ${formatIndianCurrency(widget.draw.collected)} has been '
                      "collected towards this draw. The remainder comes out of the "
                      "group's other funds.",
                      style: const TextStyle(
                          color: Color(0xFFB45309),
                          fontSize: 12.5,
                          height: 1.4),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text.rich(TextSpan(
                            text: 'METHOD',
                            style: _auctionLabelStyle,
                            children: [
                              TextSpan(
                                  text: ' *',
                                  style: TextStyle(color: AppColors.kDanger)),
                            ],
                          )),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: _method,
                            isExpanded: true,
                            decoration: _auctionFieldDecoration(),
                            items: _methods
                                .map((m) =>
                                    DropdownMenuItem(value: m, child: Text(m)))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _method = v ?? 'Cash'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text.rich(TextSpan(
                            text: 'PAYOUT DATE',
                            style: _auctionLabelStyle,
                            children: [
                              TextSpan(
                                  text: ' *',
                                  style: TextStyle(color: AppColors.kDanger)),
                            ],
                          )),
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: _pickDate,
                            borderRadius: BorderRadius.circular(12),
                            child: InputDecorator(
                              decoration: _auctionFieldDecoration(
                                suffixIcon: const Icon(
                                    Icons.calendar_today_outlined,
                                    color: AppColors.kTextMuted,
                                    size: 18),
                              ),
                              child: Text(formatDate(_date),
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.kTextDark)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('NOTES', style: _auctionLabelStyle),
                const SizedBox(height: 8),
                TextField(
                  controller: _notesCtrl,
                  maxLines: 2,
                  decoration: _auctionFieldDecoration(hint: 'Optional'),
                ),
                const SizedBox(height: 14),
                Text(
                  'This writes a cash-book entry, so Cash In Hand drops by '
                  '${formatIndianCurrency(widget.auction.payoutAmount)} straight away.',
                  style: const TextStyle(
                      color: AppColors.kTextMuted, fontSize: 12, height: 1.4),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(
                          color: AppColors.kDanger, fontSize: 13)),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            _saving ? null : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          side: const BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                        child: const Text('Cancel',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _confirm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.kGold,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.payments_outlined, size: 20),
                        label: Text(
                          _saving ? 'Paying…' : 'Confirm Payout',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: iconColor),
              ),
            ],
          ),
          const Spacer(),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.kTextMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.kTextDark,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
