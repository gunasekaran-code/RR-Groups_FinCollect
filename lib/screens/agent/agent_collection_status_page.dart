import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../services/agent_status_api_service.dart';
import '../../services/auth_api_service.dart' show ApiException;
import '../../widgets/app_shell.dart';
import '../../models/agent_portfolio_model.dart';
import '../../widgets/responsive_stat_grid.dart';

// -----------------------------------------------------------------------------
// PAGE IMPLEMENTATION
// -----------------------------------------------------------------------------
class AgentCollectionStatusPage extends StatefulWidget {
  final String agentId;
  final String agentName;

  const AgentCollectionStatusPage({
    super.key,
    required this.agentId,
    required this.agentName,
  });

  @override
  State<AgentCollectionStatusPage> createState() => _AgentCollectionStatusPageState();
}

class _AgentCollectionStatusPageState extends State<AgentCollectionStatusPage> {
  bool _isLoading = true;
  String? _error;
  AgentPortfolioResponse? _portfolio;

  String _searchQuery = '';
  String _selectedFilter = 'All';

  static const _filters = ['All', 'Not collected', 'Overdue', 'Collected today'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final portfolio = await AgentStatusApiService.instance
          .getAgentPortfolio(widget.agentId);
      if (!mounted) return;
      setState(() {
        _portfolio = portfolio;
        _isLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load collection status.';
        _isLoading = false;
      });
    }
  }

  String _formatCurrency(double amount) {
    final format = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
    return format.format(amount);
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return '—';
    final parsed = DateTime.tryParse(isoDate);
    if (parsed == null) return isoDate;
    return DateFormat('dd MMM yyyy').format(parsed);
  }

  List<AgentCustomer> get _filteredCustomers {
    var list = _portfolio?.customers ?? const <AgentCustomer>[];

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      list = list
          .where((c) =>
              c.fullName.toLowerCase().contains(q) ||
              c.mobile.toLowerCase().contains(q) ||
              c.customerId.toLowerCase().contains(q))
          .toList();
    }

    switch (_selectedFilter) {
      case 'Not collected':
        list = list
            .where((c) => c.status != 'collected' &&
                c.status != 'settled' &&
                c.status != 'no_loan')
            .toList();
        break;
      case 'Overdue':
        list = list.where((c) => c.status == 'overdue').toList();
        break;
      case 'Collected today':
        list = list.where((c) => c.status == 'collected').toList();
        break;
      case 'All':
      default:
        break;
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final summary = _portfolio?.summary ?? AgentPortfolioSummary.empty();
    final customers = _filteredCustomers;

    return AppShell(
      currentRoute: AppRoutes.agent,
      title: '${widget.agentName} · Customer Book',
      showBackButton: true,
      onBack: () => Navigator.of(context).pop(),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDarkHeader(summary),
              const SizedBox(height: 16),

              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 96),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Column(
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.kDanger, size: 40),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _load,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              else ...[
                _buildStatsGrid(summary),
                const SizedBox(height: 24),
                if ((_portfolio?.unlinkedLoans.isNotEmpty ?? false)) ...[
                  _buildUnlinkedLoansBanner(_portfolio!.unlinkedLoans),
                  const SizedBox(height: 16),
                ],
                _buildSearchAndFilters(),
                const SizedBox(height: 16),
                _buildListHeader(),
                const Divider(height: 1),
                if (customers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text(
                        'No customers match this filter.',
                        style: TextStyle(color: AppColors.ink500),
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: customers.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      return CustomerExpandableRow(
                        customer: customers[index],
                        formatCurrency: _formatCurrency,
                        formatDate: _formatDate,
                      );
                    },
                  ),
                const SizedBox(height: 48),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDarkHeader(AgentPortfolioSummary summary) {
    final agent = _portfolio?.agent;
    final subtitle = [
      widget.agentId,
      if (agent?.mobile != null && agent!.mobile!.isNotEmpty) agent.mobile,
    ].whereType<String>().join(' · ');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.kGold.withOpacity(0.25),
            AppColors.kGoldDark.withOpacity(0.15)
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kGold.withOpacity(0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.kGold,
            child: Text(
              widget.agentName.isNotEmpty ? widget.agentName[0].toUpperCase() : 'A',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.agentName,
                  style: const TextStyle(
                    color: AppColors.ink900,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.ink700,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'COLLECTED TODAY',
                style: TextStyle(
                  color: AppColors.ink800,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatCurrency(summary.collectedToday),
                style: const TextStyle(
                  color: AppColors.emerald,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _portfolio?.asOf.isNotEmpty == true
                    ? 'as of ${_formatDate(_portfolio!.asOf)}'
                    : '',
                style: const TextStyle(
                  color: AppColors.ink700,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildStatsGrid(AgentPortfolioSummary summary) {
    return ResponsiveStatGrid(
      children: [
        _DashboardStatCard(
          icon: Icons.people_outline,
          iconColor: AppColors.kGold,
          iconBg: AppColors.gold50,
          label: 'CUSTOMERS',
          value: '${summary.customers}',
          subtitle:
              '${summary.loanCount} loans · ${summary.chitCount} chits · ${summary.fundCount} funds',
        ),
        _DashboardStatCard(
          icon: Icons.check_circle_outline,
          iconColor: AppColors.emerald,
          iconBg: const Color(0xFFECFDF5),
          label: 'PAID TODAY',
          value: '${summary.collectedCount}',
          subtitle: '${summary.pendingToday} still to collect',
        ),
        _DashboardStatCard(
          icon: Icons.warning_amber_rounded,
          iconColor: AppColors.rose,
          iconBg: const Color(0xFFFFF1F2),
          label: 'OVERDUE',
          value: '${summary.overdueCount}',
          subtitle: _formatCurrency(summary.overdueAmount),
        ),
        _DashboardStatCard(
          icon: Icons.account_balance_wallet_outlined,
          iconColor: AppColors.violet,
          iconBg: const Color(0xFFF5F3FF),
          label: 'OUTSTANDING',
          value: _formatCurrency(summary.outstanding),
          subtitle: '${_formatCurrency(summary.fundBalance)} still to save in funds',
        ),
      ],
    );
  }

  Widget _buildUnlinkedLoansBanner(List<UnlinkedLoan> loans) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDBA74)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.link_off, color: Color(0xFFC2410C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${loans.length} loan${loans.length == 1 ? '' : 's'} on this agent\'s book '
              'point at no live customer — outstanding of these still counts as '
              'collection work, but it won\'t show in the list below until reattached.',
              style: const TextStyle(color: Color(0xFF9A3412), fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return LayoutBuilder(builder: (context, constraints) {
      final isMobile = constraints.maxWidth < 600;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: isMobile ? double.infinity : 300,
            child: TextField(
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                hintText: "Search this agent's customers...",
                prefixIcon: const Icon(Icons.search, color: AppColors.kTextMuted),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.kBorder),
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _filters.map((f) => _buildFilterChip(f)).toList(),
          ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh, color: AppColors.kTextMuted),
            tooltip: 'Refresh',
          )
        ],
      );
    });
  }

  Widget _buildFilterChip(String label) {
    final isSelected = _selectedFilter == label;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (val) => setState(() => _selectedFilter = label),
      backgroundColor: Colors.white,
      selectedColor: AppColors.kGold,
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : AppColors.kTextDark,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: isSelected ? AppColors.kGold : AppColors.kBorder),
      ),
    );
  }

  Widget _buildListHeader() {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 700) return const SizedBox.shrink();

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(flex: 3, child: Text('CUSTOMER', style: _headerStyle())),
            Expanded(flex: 1, child: Text('OUTSTANDING', style: _headerStyle())),
            Expanded(flex: 1, child: Text('DUE NOW', style: _headerStyle())),
            Expanded(flex: 2, child: Text('LAST COLLECTION', style: _headerStyle())),
          ],
        ),
      );
    });
  }

  TextStyle _headerStyle() {
    return const TextStyle(
      color: AppColors.ink500,
      fontWeight: FontWeight.w600,
      fontSize: 12,
      letterSpacing: 0.5,
    );
  }
}

// -----------------------------------------------------------------------------
// DASHBOARD STAT CARD
// -----------------------------------------------------------------------------
class _DashboardStatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String label;
  final String value;
  final String subtitle;

  const _DashboardStatCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.label,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: AppColors.ink500, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(color: AppColors.ink900, fontSize: 24, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: AppColors.ink400, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// EXPANDABLE CUSTOMER ROW
// -----------------------------------------------------------------------------
class CustomerExpandableRow extends StatefulWidget {
  final AgentCustomer customer;
  final String Function(double) formatCurrency;
  final String Function(String?) formatDate;

  const CustomerExpandableRow({
    super.key,
    required this.customer,
    required this.formatCurrency,
    required this.formatDate,
  });

  @override
  State<CustomerExpandableRow> createState() => _CustomerExpandableRowState();
}

class _CustomerExpandableRowState extends State<CustomerExpandableRow> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _isExpanded ? const Color(0xFFFAFAFA) : Colors.white,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isMobile = constraints.maxWidth < 700;

                  if (isMobile) {
                    return _buildMobileCollapsedRow();
                  }
                  return _buildDesktopCollapsedRow();
                },
              ),
            ),
          ),
          if (_isExpanded) _buildExpandedContent(),
        ],
      ),
    );
  }

  Widget _buildDesktopCollapsedRow() {
    final c = widget.customer;
    return Row(
      children: [
        // Column 1: Customer Info
        Expanded(
          flex: 3,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                color: AppColors.ink500,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.fullName,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink900),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.gold100,
                            border: Border.all(color: AppColors.kGoldLight),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            c.customerId,
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.gold800),
                          ),
                        ),
                        if (!c.directlyAssigned)
                          const Padding(
                            padding: EdgeInsets.only(left: 8.0),
                            child: Text('via loan', style: TextStyle(fontSize: 12, color: AppColors.ink400)),
                          )
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        _buildIconText(Icons.phone_outlined, c.mobile),
                        _buildIconText(Icons.account_balance_outlined, '${c.loans} loans'),
                        if (c.chitGroups > 0)
                          _buildIconText(Icons.account_balance_wallet_outlined, '${c.chitGroups} chit${c.chitGroups == 1 ? '' : 's'}'),
                        if (c.funds > 0)
                          _buildIconText(Icons.savings_outlined, '${c.funds} fund${c.funds == 1 ? '' : 's'}'
                              '${c.fundBalance > 0 ? ' · ${widget.formatCurrency(c.fundBalance)} to save' : ''}'),
                        if (c.chitGroups == 0 && c.funds == 0 && c.address.isNotEmpty)
                          _buildIconText(Icons.location_on_outlined, c.address),
                      ],
                    )
                  ],
                ),
              ),
            ],
          ),
        ),

        // Column 2: Outstanding
        Expanded(
          flex: 1,
          child: Text(
            widget.formatCurrency(c.outstanding),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),

        // Column 3: Due Now
        Expanded(
          flex: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.dueNow == 0 ? '—' : widget.formatCurrency(c.dueNow),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.status == 'overdue' ? AppColors.rose : null,
                ),
              ),
              if (c.dueNow == 0 && c.nextDueDate != null)
                Text('next ${widget.formatDate(c.nextDueDate)}', style: const TextStyle(fontSize: 11, color: AppColors.ink400))
            ],
          ),
        ),

        // Column 4: Last Collection & Status Badge
        Expanded(
          flex: 2,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.lastCollectionAmount == 0 ? '—' : widget.formatCurrency(c.lastCollectionAmount),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.lastCollectionDate == null
                        ? 'No collections yet'
                        : '${widget.formatDate(c.lastCollectionDate)}'
                            '${c.lastCollectionBy != null ? ' · ${c.lastCollectionBy}' : ''}',
                    style: const TextStyle(fontSize: 12, color: AppColors.ink400),
                  ),
                ],
              ),
              _buildStatusBadge(c.status),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobileCollapsedRow() {
    final c = widget.customer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, color: AppColors.ink500),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(c.fullName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink900)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppColors.gold100, border: Border.all(color: AppColors.kGoldLight), borderRadius: BorderRadius.circular(4)),
                        child: Text(c.customerId, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.gold800)),
                      ),
                      _buildStatusBadge(c.status),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      _buildIconText(Icons.phone_outlined, c.mobile),
                      _buildIconText(Icons.account_balance_outlined, '${c.loans} loans'),
                    ],
                  )
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.ink50, borderRadius: BorderRadius.circular(8)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMobileStat('Outstanding', widget.formatCurrency(c.outstanding)),
              _buildMobileStat('Due Now', c.dueNow == 0 ? '—' : widget.formatCurrency(c.dueNow)),
              _buildMobileStat('Last Paid', c.lastCollectionAmount == 0 ? '—' : widget.formatCurrency(c.lastCollectionAmount)),
            ],
          ),
        )
      ],
    );
  }

  Widget _buildMobileStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.ink500, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.ink900)),
      ],
    );
  }

  Widget _buildExpandedContent() {
    final c = widget.customer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(40, 0, 16, 24),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.ink100)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 600;
          return Wrap(
            spacing: 24,
            runSpacing: 24,
            alignment: WrapAlignment.start,
            children: [
              if (c.loanList.isNotEmpty)
                SizedBox(
                  width: isMobile ? double.infinity : 300,
                  child: _buildLoanSection(),
                ),
              if (c.chitList.isNotEmpty)
                SizedBox(
                  width: isMobile ? double.infinity : 320,
                  child: _buildChitSection(),
                ),
              if (c.fundList.isNotEmpty)
                SizedBox(
                  width: isMobile ? double.infinity : 320,
                  child: _buildFundSection(),
                ),
              if (c.loanList.isEmpty && c.chitList.isEmpty && c.fundList.isEmpty)
                const Text('No loans, chits, or funds on record for this customer.',
                    style: TextStyle(color: AppColors.ink400)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLoanSection() {
    final loans = widget.customer.loanList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.account_balance, color: AppColors.kGold, size: 18),
              const SizedBox(width: 8),
              Text('LOANS (${loans.length})', style: const TextStyle(color: AppColors.kGoldDark, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.5)),
            ],
          ),
        ),
        ...loans.map((loan) => _buildLoanCard(loan)),
      ],
    );
  }

  Widget _buildLoanCard(LoanItem loan) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(loan.loanNumber, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink900)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppColors.ink100, borderRadius: BorderRadius.circular(16)),
                child: Text(loan.status, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.ink600)),
              )
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('EMI', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(loan.emi), style: const TextStyle(color: AppColors.ink600, fontSize: 13)),
              const Text('Outstanding', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(loan.outstanding), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink900)),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildChitSection() {
    final chits = widget.customer.chitList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.account_balance_wallet_outlined, color: AppColors.violet, size: 18),
              const SizedBox(width: 8),
              Text('CHIT GROUPS (${chits.length})', style: const TextStyle(color: AppColors.violet, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.5)),
            ],
          ),
        ),
        ...chits.map((chit) => _buildChitCard(chit)),
      ],
    );
  }

  Widget _buildChitCard(ChitItem chit) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '${widget.formatCurrency(chit.contribution)} ${chit.groupName}',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink900, fontSize: 15),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppColors.ink100, borderRadius: BorderRadius.circular(16)),
                child: Text('${chit.paidDraws}/${chit.totalDraws}\ndraws', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.ink600)),
              )
            ],
          ),
          const SizedBox(height: 8),
          Text(chit.groupNumber, style: const TextStyle(color: AppColors.ink400, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Due now', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(chit.dueNow), style: const TextStyle(color: AppColors.ink600, fontSize: 13)),
              const Text('Balance', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(chit.balance), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink900)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Next\ndraw', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              const SizedBox(width: 24),
              Text(widget.formatDate(chit.nextDueDate), style: const TextStyle(color: AppColors.ink600, fontSize: 13)),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildFundSection() {
    final funds = widget.customer.fundList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.savings_outlined, color: AppColors.emerald, size: 18),
              const SizedBox(width: 8),
              Text('FUNDS (${funds.length})', style: const TextStyle(color: AppColors.emerald, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.5)),
            ],
          ),
        ),
        ...funds.map((fund) => _buildFundCard(fund)),
      ],
    );
  }

  Widget _buildFundCard(FundItem fund) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(fund.fundNumber, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink900, fontSize: 15)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(16)),
                child: Text(fund.status, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.emerald)),
              )
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Weekly', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(fund.weeklyAmount), style: const TextStyle(color: AppColors.ink600, fontSize: 13)),
              const Text('Saved', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(fund.collectedAmount), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink900)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('To save', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text(widget.formatCurrency(fund.balance), style: const TextStyle(color: AppColors.rose, fontSize: 13, fontWeight: FontWeight.w600)),
              const Text('Payments', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              Text('${fund.payments} of ${fund.weeks}', style: const TextStyle(color: AppColors.ink600, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Matures', style: TextStyle(color: AppColors.ink400, fontSize: 13)),
              const SizedBox(width: 16),
              Text(widget.formatDate(fund.maturityDate), style: const TextStyle(color: AppColors.ink600, fontSize: 13)),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildIconText(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.ink400),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12, color: AppColors.ink500)),
      ],
    );
  }

  Widget _buildStatusBadge(String status) {
    Color bgColor;
    Color textColor;
    String label;

    switch (status) {
      case 'settled':
        bgColor = AppColors.ink100;
        textColor = AppColors.ink700;
        label = 'Settled';
        break;
      case 'collected':
        bgColor = const Color(0xFFD1FAE5);
        textColor = AppColors.emerald;
        label = 'Collected';
        break;
      case 'overdue':
        bgColor = const Color(0xFFFFE4E6);
        textColor = AppColors.rose;
        label = 'Overdue';
        break;
      case 'due_today':
        bgColor = AppColors.gold100;
        textColor = AppColors.gold800;
        label = 'Due today';
        break;
      case 'no_loan':
        bgColor = AppColors.ink100;
        textColor = AppColors.ink500;
        label = 'No loan';
        break;
      case 'upcoming':
      default:
        bgColor = AppColors.ink100;
        textColor = AppColors.ink700;
        label = 'Upcoming';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textColor),
      ),
    );
  }
}