import 'package:flutter/material.dart';
import '../../routes/app_routes.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/status_badge.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_toast.dart';
import '../../models/customer.dart';
import '../../models/loan_record.dart';
import '../../models/repayment_installment.dart';
import '../../models/user_role.dart';
import '../../services/api_service_repayment.dart';
import '../../services/loan_service.dart';
import '../../services/session_service.dart';
import 'repayment_close_screen.dart';
import '../../l10n/generated/app_localizations.dart';
import '../loans/loans_screen.dart' show friendlyCollectionTypeLabel;
import '../../widgets/responsive_stat_grid.dart';

class RepaymentScheduleScreen extends StatefulWidget {
  const RepaymentScheduleScreen({super.key});

  @override
  State<RepaymentScheduleScreen> createState() =>
      _RepaymentScheduleScreenState();
}

class _RepaymentScheduleScreenState extends State<RepaymentScheduleScreen> {
  bool _loading = true;
  String? _error;

  bool get _isCustomer =>
      SessionService.instance.currentUser?.role == UserRole.customer;

  String? get _customerId =>
      SessionService.instance.currentUser?.customerId?.toString();

  List<LoanRecord> _loanOptions = [];
  LoanRecord? _selectedLoan;
  List<RepaymentInstallment> _installments = [];
  List<Customer> _customers = [];

  // Loan picker search: customer name, loan number or agent.
  final TextEditingController _loanSearchController = TextEditingController();
  String _loanQuery = '';

  List<LoanRecord> get _matchingLoans {
    final q = _loanQuery.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _loanOptions.where((loan) {
      return loan.loanNumber.toLowerCase().contains(q) ||
          _customerLabelFor(loan).toLowerCase().contains(q) ||
          loan.customerName.toLowerCase().contains(q) ||
          loan.agentName.toLowerCase().contains(q);
    }).toList();
  }

  void _selectLoan(LoanRecord loan, AppLocalizations l10n) {
    setState(() => _selectedLoan = loan);
    ToastService.show(
      title: l10n.repaymentLoanSwitchedTitle,
      message: loan.loanNumber,
      type: ToastType.info,
    );
    _loadSchedule();
  }

  /// The customer's full name for a loan.
  ///
  /// `LoanRecord.customerName` is only as good as the `customer_name` value
  /// stored on the loan row itself, which can drift stale — so this looks
  /// the loan's customer up by id and prefers the customer record's own
  /// `full_name`, falling back to the loan's stored name only when no
  /// matching customer record is loaded.
  String _customerLabelFor(LoanRecord? loan) {
    if (loan == null) return '-';
    final id = loan.customerId;
    if (id != null && id.isNotEmpty) {
      for (final c in _customers) {
        if (c.id == id) {
          if (c.fullName.isNotEmpty && c.fullName != 'Unnamed')
            return c.fullName;
          break;
        }
      }
    }
    return loan.customerName;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadLoans();
    });
  }

  @override
  void dispose() {
    _loanSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadLoans() async {
    setState(() {
      _loading = true;
      _error = null;
      _loanOptions = [];
      _selectedLoan = null;
      _installments = [];
      _customers = [];
    });

    final l10n = AppLocalizations.of(context);

    try {
      final customers = await LoanService.instance.fetchCustomers();
      final agents = await LoanService.instance.fetchAgents();
      final loans = await LoanService.instance.fetchLoans(
        customers: customers,
        agents: agents,
      );
      // A closed loan has nothing left to schedule, so it never belongs in
      // this picker — only Active / Overdue / Pending loans do.
      final filteredLoans = loans.where((loan) {
        if (loan.status == 'Closed') return false;
        if (_isCustomer && _customerId != null) {
          return (loan.customerId ?? '').trim().toLowerCase() ==
              _customerId!.trim().toLowerCase();
        }
        return true;
      }).toList();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _loanOptions = filteredLoans;
        _selectedLoan = filteredLoans.isNotEmpty ? filteredLoans.first : null;
      });
      if (_selectedLoan != null) {
        await _loadSchedule();
      } else {
        setState(() {
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = l10n.repaymentCouldNotLoadLoans;
        _loading = false;
      });
      ToastService.show(
        title: l10n.repaymentLoanLoadFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  Future<void> _loadSchedule() async {
    if (_selectedLoan == null) {
      setState(() {
        _loading = false;
      });
      return;
    }

    final l10n = AppLocalizations.of(context);

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data =
          await ApiServiceRepayment.instance.fetchSchedule(_selectedLoan!.id);
      if (!mounted) return;
      setState(() {
        _installments = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = l10n.repaymentCouldNotLoadSchedule;
        _loading = false;
      });
      ToastService.show(
        title: l10n.repaymentLoadFailedTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  BadgeTone _toneFor(String status) {
    switch (status) {
      case 'Paid':
        return BadgeTone.success;
      case 'Overdue':
        return BadgeTone.danger;
      default:
        return BadgeTone.warning;
    }
  }

  /// Sorted list of installments not yet fully paid — used to find the
  /// "next due" row and to default-select an installment when recording
  /// a new collection.
  List<RepaymentInstallment> get _unpaidInstallments {
    final unpaid = _installments.where((i) => i.status != 'paid').toList();
    unpaid.sort((a, b) {
      final ad = a.dueDate;
      final bd = b.dueDate;
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return ad.compareTo(bd);
    });
    return unpaid;
  }

  // ---- Record Collection -------------------------------------------
  // The button no longer opens an in-page form — it hands off to the full
  // Collections screen instead.
  void _goToCollections() {
    Navigator.of(context).pushNamed(AppRoutes.collections);
  }

  Future<void> _openCloseLoan() async {
    final loan = _selectedLoan;
    if (loan == null) return;
    final closed = await RepaymentCloseScreen.show(
      context,
      loan: loan,
      customerName: _customerLabelFor(loan),
      installments: _installments,
    );
    if (closed == true && mounted)
      _loadLoans(); // closed loan drops out of the picker
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 700;
        return AppShell(
          currentRoute: AppRoutes.repayment,
          title: l10n.repaymentTitle,
          body: RefreshIndicator(
            onRefresh: _loadSchedule,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                  horizontal: isNarrow ? 12 : 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context, isNarrow, l10n),
                  const SizedBox(height: 24),
                  _buildLoanSelector(l10n),
                  const SizedBox(height: 20),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 60),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    _buildErrorState(l10n)
                  else ...[
                    if (_buildPenaltyBanner(l10n) case final banner?) ...[
                      banner,
                      const SizedBox(height: 20),
                    ],
                    _buildSummaryGrid(isNarrow, l10n),
                    const SizedBox(height: 24),
                    _buildSectionLabel(l10n.repaymentInstallmentBreakdown),
                    const SizedBox(height: 12),
                    _buildInstallmentsTable(isNarrow, l10n),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorState(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: AppColors.kDanger, size: 32),
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _loadSchedule,
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  // Header — subtitle + the "Record Collection" action. Only admins/agents
  // may write collections (the backend rejects a customer's POST with a
  // 403), so the button is hidden for customer accounts rather than shown
  // and left to fail.
  Widget _buildHeader(
      BuildContext context, bool isNarrow, AppLocalizations l10n) {
    final subtitle = Text(
      l10n.repaymentSubtitle,
      style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
    );
    final closeButton = (_isCustomer || _selectedLoan == null)
        ? null
        : OutlinedButton.icon(
            onPressed: _openCloseLoan,
            icon: const Icon(Icons.lock_outline, size: 20),
            label: const Text('Close Loan / கடனை முடி'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.kGoldDark,
              side: const BorderSide(color: AppColors.kGold),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          );
    final recordButton = _isCustomer
        ? null
        : ElevatedButton.icon(
            onPressed: _goToCollections,
            icon: const Icon(Icons.payments_outlined, size: 20),
            label: Text(l10n.repaymentRecordCollectionButton),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.kGold,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppColors.kGold.withOpacity(0.4),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          );

    if (isNarrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          subtitle,
          if (recordButton != null) ...[
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: recordButton),
          ],
          if (closeButton != null) ...[
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: closeButton),
          ],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: subtitle),
        if (closeButton != null) ...[
          closeButton,
          const SizedBox(width: 12),
        ],
        if (recordButton != null) recordButton,
      ],
    );
  }

  // Loan selector card — gold header strip over the picker, matching the
  // loan cards.
  Widget _buildLoanSelector(AppLocalizations l10n) {
    final selected = _selectedLoan;

    Widget frame({required Widget header, Widget? body}) => Container(
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
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: _kGoldGradient,
                  ),
                ),
                child: header,
              ),
              if (body != null)
                Padding(padding: const EdgeInsets.all(16), child: body),
            ],
          ),
        );

    Widget headerRow(String label, String? value) => Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.kGold.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.kGoldLight.withValues(alpha: 0.5)),
              ),
              child: const Icon(Icons.account_balance_wallet_outlined,
                  color: AppColors.gold200, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.kTextOnDarkMuted,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5),
                  ),
                  if (value != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.kTextOnDark,
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );

    if (_isCustomer) {
      return frame(
        header: headerRow(
          'Customer Loan',
          selected == null
              ? 'No active loan found'
              : '${selected.loanNumber} • ${_customerLabelFor(selected)}',
        ),
      );
    }

    return frame(
      header: headerRow(
        l10n.repaymentSelectLoanLabel,
        selected == null
            ? null
            : '${selected.loanNumber} • ${_customerLabelFor(selected)}',
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLoanSearch(l10n),
          const SizedBox(height: 10),
          DropdownButtonFormField<LoanRecord>(
            // Rebuilt when a loan is picked from the search results, since
            // initialValue is only read once.
            key: ValueKey(_selectedLoan?.id),
            initialValue: _selectedLoan,
            isExpanded: true,
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.kBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: AppColors.kGold, width: 1.4),
              ),
            ),
            hint: Text(l10n.repaymentSelectLoanHint),
            items: _loanOptions
                .map((loan) => DropdownMenuItem<LoanRecord>(
                      value: loan,
                      child: Text(
                          '${loan.loanNumber} + ${_customerLabelFor(loan)}'),
                    ))
                .toList(),
            onChanged: _loanOptions.isEmpty
                ? null
                : (loan) {
                    if (loan != null) _selectLoan(loan, l10n);
                  },
          ),
        ],
      ),
    );
  }

  /// Search box above the loan dropdown. Typing lists the matching loans
  /// (by customer name, loan number or agent); tapping one selects it.
  Widget _buildLoanSearch(AppLocalizations l10n) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.kBorder),
    );
    final matches = _matchingLoans;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _loanSearchController,
          enabled: _loanOptions.isNotEmpty,
          onChanged: (v) => setState(() => _loanQuery = v),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search by name, loan no, agent',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _loanQuery.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _loanSearchController.clear();
                      setState(() => _loanQuery = '');
                    },
                  ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: border,
            enabledBorder: border,
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.kGold, width: 1.4),
            ),
          ),
        ),
        if (_loanQuery.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: AppColors.kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.kBorder),
            ),
            child: matches.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'No matching loans',
                      style:
                          TextStyle(fontSize: 13, color: AppColors.kTextMuted),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: matches.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: AppColors.kBorder),
                    itemBuilder: (context, i) {
                      final loan = matches[i];
                      final isSelected = loan.id == _selectedLoan?.id;
                      return ListTile(
                        dense: true,
                        selected: isSelected,
                        selectedTileColor:
                            AppColors.kGold.withValues(alpha: 0.08),
                        title: Text(
                          '${loan.loanNumber} • ${_customerLabelFor(loan)}',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.kTextDark),
                        ),
                        subtitle: Text(
                          'Agent: ${loan.agentName}',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.kTextMuted),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check,
                                size: 18, color: AppColors.kGold)
                            : null,
                        onTap: () {
                          FocusScope.of(context).unfocus();
                          _loanSearchController.clear();
                          setState(() => _loanQuery = '');
                          if (!isSelected) _selectLoan(loan, l10n);
                        },
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: AppColors.kTextMuted,
        letterSpacing: 0.5,
      ),
    );
  }

  // Localized "N Weeks/Months/Days" label for the loan's duration, matching
  // the unit LoanRecalc actually applies penalties in.
  String _durationLabel(LoanRecord loan, AppLocalizations l10n) {
    switch (loan.collectionType) {
      case 'Weekly':
        return l10n.repaymentDurationWeeks(loan.durationUnits);
      case 'Daily':
        return l10n.repaymentDurationDays(loan.durationUnits);
      default:
        return l10n.repaymentDurationMonths(loan.durationUnits);
    }
  }

  // Penalty rule banner — mirrors the exact rule LoanRecalc.php applies on
  // the backend, so this never promises something the server won't do:
  //   * Weekly loans: a fixed ₹100-per-₹10,000-principal penalty per missed
  //     week (see core/LoanRecalc.php `syncRegular`).
  //   * Monthly/Daily loans: only when `penalty_enabled` and a per-day rate
  //     are actually configured on the loan.
  // Returns null (no banner) when neither rule is active for this loan.
  Widget? _buildPenaltyBanner(AppLocalizations l10n) {
    final loan = _selectedLoan;
    if (loan == null) return null;

    final isWeekly = loan.collectionType == 'Weekly';
    final hasDailyRate =
        !isWeekly && loan.penaltyEnabled && loan.penaltyRatePerDay > 0;
    if (!isWeekly && !hasDailyRate) return null;

    final title = l10n.repaymentPenaltyBannerTitle(
      friendlyCollectionTypeLabel(loan, l10n),
      _durationLabel(loan, l10n),
    );
    final body = isWeekly
        ? l10n.repaymentPenaltyBannerWeeklyBody
        : l10n.repaymentPenaltyBannerRateBody(
            LoanRecord.formatRupees(loan.penaltyRatePerDay));

    final totalPenalty =
        _installments.fold<double>(0, (sum, i) => sum + i.penaltyAmount);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFA9791F), Color(0xFFC48E28)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.bolt_rounded,
                  color: AppColors.gold200, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: AppColors.kTextOnDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppColors.kTextOnDark,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (totalPenalty > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.kSurface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                l10n.repaymentAccruedPenaltyLabel(
                    LoanRecord.formatRupees(totalPenalty)),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.kDanger,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Summary cards grid — responsive: 2 columns narrow, 4 columns wide.
  // All figures below are derived from the fetched schedule rows.
  Widget _buildSummaryGrid(bool isNarrow, AppLocalizations l10n) {
    final total = _installments.length;
    final paidCount = _installments.where((i) => i.status == 'paid').length;
    final overdueCount =
        _installments.where((i) => i.status == 'overdue').length;
    final pendingCount = total - paidCount - overdueCount;

    final emi = _installments.isNotEmpty ? _installments.first.emiAmount : 0.0;
    final totalRepayment =
        _installments.fold<double>(0, (sum, i) => sum + i.emiAmount);
    final outstanding =
        _installments.fold<double>(0, (sum, i) => sum + i.balance);
    final totalPenalty =
        _installments.fold<double>(0, (sum, i) => sum + i.penaltyAmount);
    final totalDueWithPenalty = outstanding + totalPenalty;

    final nextDue = _unpaidInstallments;
    final nextDueDisplay =
        nextDue.isNotEmpty ? nextDue.first.dueDateDisplay : '-';

    String fmt(double v) => LoanRecord.formatRupees(v);

    final split = _installmentSplit(emi);

    final cards = <Widget>[
      _buildStatCard(
          l10n.repaymentStatLoanNumber, _selectedLoan?.loanNumber ?? '-',
          icon: Icons.badge_outlined),
      _buildStatCard(
          l10n.repaymentStatCustomer, _customerLabelFor(_selectedLoan),
          icon: Icons.person_outline),
      _buildStatCard(
          l10n.repaymentStatLoanAmount, _selectedLoan?.formattedAmount ?? '-',
          icon: Icons.account_balance_wallet_outlined),
      _buildStatCard(l10n.repaymentStatEmi, fmt(split.principal),
          icon: Icons.calendar_month_outlined),
      _buildStatCard('INTEREST', fmt(split.interest),
          icon: Icons.percent,
          textColor: AppColors.kWarning,
          borderColor: AppColors.kWarning.withOpacity(0.3),
          bgColor: AppColors.kWarning.withOpacity(0.05)),
      _buildStatCard(l10n.repaymentStatTotalRepayment, fmt(totalRepayment),
          icon: Icons.summarize_outlined),
      _buildStatCard(
          l10n.repaymentStatTotalDuePenalty, fmt(totalDueWithPenalty),
          icon: Icons.account_balance, textColor: AppColors.kDanger),
      _buildStatCard(l10n.repaymentStatTotalInstallments, '$total',
          icon: Icons.format_list_numbered),
      _buildStatCard(l10n.repaymentStatPaid, '$paidCount',
          icon: Icons.check_circle_outline,
          textColor: AppColors.kSuccess,
          borderColor: AppColors.kSuccess.withOpacity(0.3),
          bgColor: AppColors.kSuccess.withOpacity(0.05)),
      _buildStatCard(l10n.repaymentStatPending, '$pendingCount',
          icon: Icons.hourglass_empty,
          textColor: AppColors.kWarning,
          borderColor: AppColors.kWarning.withOpacity(0.3),
          bgColor: AppColors.kWarning.withOpacity(0.05)),
      _buildStatCard(l10n.repaymentStatOverdue, '$overdueCount',
          icon: Icons.error_outline,
          textColor: AppColors.kDanger,
          borderColor: AppColors.kDanger.withOpacity(0.3),
          bgColor: AppColors.kDanger.withOpacity(0.05)),
      _buildStatCard(l10n.repaymentStatNextDue, nextDueDisplay,
          icon: Icons.event_outlined,
          textColor: AppColors.kGoldDark,
          borderColor: AppColors.kGold.withOpacity(0.35),
          bgColor: AppColors.kGold.withOpacity(0.08)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveStatGrid(
          children: cards,
        ),
        const SizedBox(height: 12),
        _buildInstallmentTotalCard(split, fmt, l10n),
      ],
    );
  }

  /// Splits one installment into its principal and interest parts, from the
  /// loan's own figures (loan_amount, interest_percentage, loan_duration,
  /// loan_type) — the same rules the backend's Loan::deriveTotals uses:
  ///
  ///   - Monthly EMI:      interest = principal × rate% each month,
  ///                       principal part = installment − interest
  ///                       (₹60,000 @ 3% × 12 → ₹5,000 + ₹1,800 = ₹6,800).
  ///   - Monthly Interest: the installment is all interest.
  ///   - Daily, 60 days:   the interest is added on top and spread evenly.
  ///   - Weekly / Daily 100 days: interest is deducted at disbursement, so
  ///                       every installment is principal only.
  ///
  /// [scheduleEmi] is the installment amount from the fetched schedule; the
  /// loan's stored `emi` is preferred when present.
  ({double principal, double interest, double total}) _installmentSplit(
      double scheduleEmi) {
    final loan = _selectedLoan;
    if (loan == null) return (principal: 0, interest: 0, total: scheduleEmi);

    final total = loan.emiAmount > 0 ? loan.emiAmount : scheduleEmi;
    final p = loan.principalAmount;
    final rate = loan.interestRate;
    final n = loan.durationUnits;

    double interest;
    switch (loan.collectionType.toLowerCase()) {
      case 'weekly':
        interest = 0;
        break;
      case 'daily':
        final days = n > 0 ? n : 60;
        interest = days >= 100 ? 0 : (p * rate / 100) / days;
        break;
      default: // monthly (EMI or interest-only) and monthly_interest
        interest = p * rate / 100;
    }

    double r2(double v) => (v * 100).roundToDouble() / 100;
    interest = r2(interest.clamp(0, total).toDouble());
    final principal = r2((total - interest).clamp(0, total).toDouble());
    return (principal: principal, interest: interest, total: total);
  }

  /// The full-width card closing the summary: EMI + Interest = installment.
  Widget _buildInstallmentTotalCard(
    ({double principal, double interest, double total}) split,
    String Function(double) fmt,
    AppLocalizations l10n,
  ) {
    Widget part(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.kTextMuted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.kTextDark,
                    fontWeight: FontWeight.w700)),
          ],
        );
    const opStyle = TextStyle(
        fontSize: 18, color: AppColors.kTextMuted, fontWeight: FontWeight.w600);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.kGold.withOpacity(0.08),
        border: Border.all(color: AppColors.kGold.withOpacity(0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'TOTAL ${l10n.repaymentStatEmi} + INTEREST (PER INSTALLMENT)',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.kGoldDark.withOpacity(0.85),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Icon(Icons.payments_outlined,
                  size: 18, color: AppColors.kGoldDark.withOpacity(0.7)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            fmt(split.total),
            style: const TextStyle(
              fontSize: 30,
              color: AppColors.kGoldDark,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 14,
            runSpacing: 8,
            children: [
              part(l10n.repaymentStatEmi, fmt(split.principal)),
              const Text('+', style: opStyle),
              part('INTEREST', fmt(split.interest)),
              const Text('=', style: opStyle),
              part('TOTAL', fmt(split.total)),
            ],
          ),
        ],
      ),
    );
  }

  // Reusable widget for building the summary cards
  Widget _buildStatCard(
    String title,
    String value, {
    IconData? icon,
    Color? bgColor,
    Color? borderColor,
    Color? textColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor ?? AppColors.kSurface,
        border: Border.all(color: borderColor ?? AppColors.kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor?.withOpacity(0.85) ?? AppColors.kTextMuted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (icon != null) ...[
                const SizedBox(width: 6),
                Icon(icon,
                    size: 16,
                    color: textColor?.withOpacity(0.6) ??
                        AppColors.kTextMuted.withOpacity(0.6)),
              ],
            ],
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              color: textColor ?? AppColors.kTextDark,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // Installment breakdown — sourced from live `_installments` fetched via
  // ApiServiceRepayment. One gold-header table on every screen size; it
  // scrolls sideways when narrower than its columns. Paid / next-due /
  // overdue installments stand out.
  Widget _buildInstallmentsTable(bool isNarrow, AppLocalizations l10n) {
    if (_installments.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.kSurface,
          border: Border.all(color: AppColors.kBorder),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: AppColors.gold50,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.receipt_long_outlined,
                  size: 26, color: AppColors.kGold),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.repaymentNoInstallmentsFound,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.kTextMuted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    final nextDueId =
        _unpaidInstallments.isNotEmpty ? _unpaidInstallments.first.id : null;

    return _buildInstallmentDataTable(nextDueId, isNarrow, l10n);
  }

  static const double _tableHeadingHeight = 50;

  Widget _buildInstallmentDataTable(
      String? nextDueId, bool isNarrow, AppLocalizations l10n) {
    Color rowColor(RepaymentInstallment inst, int index) {
      if (inst.status == 'paid') {
        return AppColors.kSuccess.withValues(alpha: 0.07);
      }
      if (inst.status == 'overdue') {
        return AppColors.kDanger.withValues(alpha: 0.06);
      }
      if (inst.id == nextDueId) return AppColors.kGold.withValues(alpha: 0.10);
      return index.isOdd ? AppColors.kBackground : AppColors.kSurface;
    }

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
          // Keep the key date and amount columns in consistent positions on
          // mobile and tablet. The viewport scrolls horizontally rather than
          // compressing those columns into each other.
          final tableWidth = constraints.maxWidth < 700
              ? 1000.0
              : constraints.maxWidth < 1100
                  ? 1120.0
                  : constraints.maxWidth;
          final columnSpacing = tableWidth >= 1200
              ? 40.0
              : tableWidth >= 760
                  ? 28.0
                  : 20.0;
          final table = DataTable(
            // Transparent so the gold gradient strip painted behind it shows
            // through.
            headingRowColor: WidgetStateProperty.all(Colors.transparent),
            headingRowHeight: _tableHeadingHeight,
            dataRowMinHeight: 68,
            dataRowMaxHeight: 72,
            columnSpacing: columnSpacing,
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
              DataColumn(label: Text(l10n.repaymentColInstNo)),
              // Date columns share surplus width on desktop, creating a
              // deliberate gap before the financial columns. On narrower
              // screens they collapse to their intrinsic width and the table
              // remains horizontally scrollable.
              DataColumn(
                label: Text(l10n.repaymentColDueDate),
                columnWidth: const MaxColumnWidth(
                    IntrinsicColumnWidth(), FlexColumnWidth()),
              ),
              DataColumn(
                label: Align(
                  alignment: Alignment.center,
                  child: Text(l10n.repaymentColPaidDate),
                ),
                headingRowAlignment: MainAxisAlignment.center,
                columnWidth: const MaxColumnWidth(
                    IntrinsicColumnWidth(), FlexColumnWidth(1.25)),
              ),
              DataColumn(label: Text(l10n.repaymentColEmiAmount)),
              DataColumn(label: Text(l10n.repaymentColPaid)),
              DataColumn(label: Text(l10n.repaymentColBalance)),
              DataColumn(label: Text(l10n.repaymentColPenalty)),
              DataColumn(label: Text(l10n.repaymentColStatus)),
            ],
            rows: [
              for (var i = 0; i < _installments.length; i++)
                DataRow(
                  color: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered)) {
                      return AppColors.gold50;
                    }
                    return rowColor(_installments[i], i);
                  }),
                  cells: _installmentCells(
                    _installments[i],
                    _installments[i].id == nextDueId,
                    isNarrow,
                    l10n,
                  ),
                ),
            ],
          );

          return Scrollbar(
            thumbVisibility: true,
            trackVisibility: true,
            notificationPredicate: (notification) => notification.depth == 0,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: SizedBox(
                width: tableWidth,
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    // DataTable can't take a gradient, so paint the header
                    // strip (same gold as the loan cards) behind the table.
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

  List<DataCell> _installmentCells(
    RepaymentInstallment inst,
    bool isNextDue,
    bool isNarrow,
    AppLocalizations l10n,
  ) {
    return [
      DataCell(Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.gold50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.gold200),
        ),
        child: Text('#${inst.installmentNo}',
            style: const TextStyle(
                fontWeight: FontWeight.w700, color: AppColors.kGoldDark)),
      )),
      DataCell(_dueDateCell(inst, isNextDue, isNarrow, l10n)),
      DataCell(Align(
        alignment: Alignment.center,
        child: _paidDateCell(inst, l10n),
      )),
      DataCell(Text(inst.amountDisplay)),
      DataCell(Text(inst.paidDisplay,
          style: TextStyle(
              color: inst.paidAmount > 0 ? AppColors.kSuccess : null,
              fontWeight: FontWeight.w600))),
      DataCell(Text(inst.balanceDisplay,
          style: const TextStyle(
              fontWeight: FontWeight.w700, color: AppColors.kGoldDark))),
      DataCell(Text(inst.penaltyDisplay,
          style: TextStyle(
              color: inst.penaltyAmount > 0 ? AppColors.kDanger : null,
              fontWeight: FontWeight.w600))),
      DataCell(_installmentStatusPill(inst)),
    ];
  }

  Widget _dueDateCell(
    RepaymentInstallment inst,
    bool isNextDue,
    bool isNarrow,
    AppLocalizations l10n,
  ) {
    if (!isNextDue) return Text(inst.dueDateDisplay);

    final badge = _nextDueBadge(l10n);
    if (isNarrow) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(inst.dueDateDisplay),
          const SizedBox(height: 4),
          badge,
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(inst.dueDateDisplay),
        const SizedBox(width: 8),
        badge,
      ],
    );
  }

  Widget _nextDueBadge(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.gold50,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.gold300),
      ),
      child: Text(
        l10n.repaymentStatNextDue,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: AppColors.kGoldDark,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _paidDateCell(RepaymentInstallment inst, AppLocalizations l10n) {
    final paidDate = inst.paidDate;
    final dueDate = inst.dueDate;
    if (paidDate == null) return const Text('-');

    // Compare date-only values so a time component from the API cannot turn
    // a same-day collection into a one-day-late payment.
    final daysLate = dueDate == null
        ? 0
        : DateUtils.dateOnly(paidDate)
            .difference(DateUtils.dateOnly(dueDate))
            .inDays;
    final isLate = daysLate > 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(inst.paidDateDisplay),
        const SizedBox(height: 2),
        Text(
          isLate
              ? l10n.repaymentPaidDaysLate(daysLate)
              : l10n.repaymentPaidOnTime,
          style: TextStyle(
            color: isLate ? AppColors.kWarning : AppColors.kSuccess,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// Gold pill with a status-coloured dot, matching the loan status pills.
  Widget _installmentStatusPill(RepaymentInstallment inst) {
    final Color dot;
    switch (_toneFor(inst.statusLabel)) {
      case BadgeTone.success:
        dot = AppColors.kSuccess;
        break;
      case BadgeTone.danger:
        dot = AppColors.kDanger;
        break;
      default:
        dot = AppColors.kWarning;
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
            inst.statusLabel,
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
}

/// Same gold strip as the loan cards and table headers.
const List<Color> _kGoldGradient = [Color(0xFFA9791F), Color(0xFFC48E28)];
