import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../models/user_role.dart';
import '../routes/app_routes.dart';
import '../services/privilege_service.dart';
import '../services/session_service.dart';
import '../services/branding_service.dart';
import '../theme/app_theme.dart';
import 'user_avatar.dart';
import '../theme/confirm_dialog.dart'; // <-- Adjust this path to wherever you saved AppConfirmDialog

class _DrawerItem {
  final String label;
  final IconData icon;
  final String route;

  const _DrawerItem({
    required this.label,
    required this.icon,
    required this.route,
  });
}

class _DrawerSection {
  final String title;
  final List<_DrawerItem> items;
  const _DrawerSection({required this.title, required this.items});
}

// ---------------- OWNER / ADMIN ----------------
const List<_DrawerSection> _ownerAdminSections = [
  _DrawerSection(title: 'OVERVIEW', items: [
    _DrawerItem(label: 'Dashboard', icon: Icons.grid_view_rounded, route: AppRoutes.dashboard),
  ]),
  _DrawerSection(title: 'MANAGE', items: [
    _DrawerItem(label: 'Customers', icon: Icons.people_outline, route: AppRoutes.customers),
    _DrawerItem(label: 'Loans', icon: Icons.account_balance_outlined, route: AppRoutes.loans),
    _DrawerItem(label: 'Repayment Schedule', icon: Icons.event_note_outlined, route: AppRoutes.repayment),
    _DrawerItem(label: 'Collections', icon: Icons.account_balance_wallet_outlined, route: AppRoutes.collections),
    _DrawerItem(label: 'Handover', icon: Icons.handshake_outlined, route: AppRoutes.handover),
    _DrawerItem(label: 'Funds', icon: Icons.account_balance_wallet_outlined, route: AppRoutes.funds),
    _DrawerItem(label: 'Account Book', icon: Icons.menu_book_outlined, route: AppRoutes.accountBook),
    _DrawerItem(label: 'Overdue', icon: Icons.error_outline, route: AppRoutes.overdue),
    _DrawerItem(label: 'Chit Groups', icon: Icons.groups_2_outlined, route: AppRoutes.chitGroups),
  ]),
  _DrawerSection(title: 'AGENT', items: [
    _DrawerItem(label: 'Agent', icon: Icons.support_agent_outlined, route: AppRoutes.agent),
    _DrawerItem(label: 'Agent Map', icon: Icons.map_outlined, route: AppRoutes.routeMap),
  ]),
  _DrawerSection(title: 'INSIGHTS', items: [
    _DrawerItem(label: 'Reports', icon: Icons.bar_chart_outlined, route: AppRoutes.reports),
    _DrawerItem(label: 'Notifications', icon: Icons.notifications_none_rounded, route: AppRoutes.notifications),
  ]),
  _DrawerSection(title: 'SYSTEM', items: [
    _DrawerItem(label: 'User Management', icon: Icons.manage_accounts_outlined, route: AppRoutes.userManagement),
    _DrawerItem(label: 'Promotional Popup', icon: Icons.campaign_outlined, route: AppRoutes.promotionalPopup),
    _DrawerItem(label: 'Recycle Bin', icon: Icons.delete_outline, route: AppRoutes.recycleBin),
    _DrawerItem(label: 'Settings', icon: Icons.settings_outlined, route: AppRoutes.settings),
  ]),
];

// ---------------- AGENT ----------------
const List<_DrawerSection> _agentSections = [
  _DrawerSection(title: 'OVERVIEW', items: [
    _DrawerItem(label: 'Dashboard', icon: Icons.grid_view_rounded, route: AppRoutes.dashboard),
  ]),
  _DrawerSection(title: 'MANAGE', items: [
    _DrawerItem(label: 'Customers', icon: Icons.people_outline, route: AppRoutes.customers),
    _DrawerItem(label: 'Loans', icon: Icons.account_balance_outlined, route: AppRoutes.loans),
    _DrawerItem(label: 'Repayment Schedule', icon: Icons.event_note_outlined, route: AppRoutes.repayment),
    _DrawerItem(label: 'Collections', icon: Icons.account_balance_wallet_outlined, route: AppRoutes.collections),
    _DrawerItem(label: 'Overdue', icon: Icons.error_outline, route: AppRoutes.overdue),
    _DrawerItem(label: 'Chit Groups', icon: Icons.groups_2_outlined, route: AppRoutes.chitGroups),
    _DrawerItem(label: 'Funds', icon: Icons.account_balance_wallet_outlined, route: AppRoutes.funds),
    _DrawerItem(label: 'Cash Handover', icon: Icons.handshake_outlined, route: AppRoutes.handover),
  ]),
  _DrawerSection(title: 'AGENT', items: [
    _DrawerItem(label: 'My Route', icon: Icons.map_outlined, route: AppRoutes.routeMap),
  ]),
  _DrawerSection(title: 'INSIGHTS', items: [
    _DrawerItem(label: 'Notifications', icon: Icons.notifications_none_rounded, route: AppRoutes.notifications),
    _DrawerItem(label: 'Settings', icon: Icons.settings_outlined, route: AppRoutes.settings),
  ]),
];

// ---------------- CUSTOMER ----------------
const List<_DrawerSection> _customerSections = [
  _DrawerSection(title: 'OVERVIEW', items: [
    _DrawerItem(label: 'Dashboard', icon: Icons.grid_view_rounded, route: AppRoutes.dashboard),
  ]),
  _DrawerSection(title: 'MY ACCOUNT', items: [
    _DrawerItem(label: 'My Loans', icon: Icons.account_balance_outlined, route: AppRoutes.loans),              // CMD
    _DrawerItem(label: 'Repayment Schedule', icon: Icons.event_note_outlined, route: AppRoutes.repayment),     // CMD
    _DrawerItem(label: 'My Funds', icon: Icons.account_balance_wallet_outlined, route: AppRoutes.funds),
    _DrawerItem(label: 'My Chits', icon: Icons.groups_2_outlined, route: AppRoutes.chitGroups),
  ]),
  _DrawerSection(title: 'INSIGHTS', items: [
    _DrawerItem(label: 'Notifications', icon: Icons.notifications_none_rounded, route: AppRoutes.notifications),
    _DrawerItem(label: 'Settings', icon: Icons.settings_outlined, route: AppRoutes.settings),
  ]),
];

class AppDrawer extends StatelessWidget {
  final String currentRoute;
  const AppDrawer({super.key, required this.currentRoute});

  List<_DrawerSection> _sectionsForRole(UserRole role) {
    switch (role) {
      case UserRole.owner:
      case UserRole.admin:
        return _ownerAdminSections;
      case UserRole.agent:
        return _agentSections;
      case UserRole.customer:
        return _customerSections;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppUser user = SessionService.instance.currentUser!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sections = _sectionsForRole(user.role);

    return Drawer(
      backgroundColor: scheme.surface, // Clean solid background
      elevation: 0,
      child: SafeArea(
        child: Column(
          children: [
            // --- HEADER ---
            ValueListenableBuilder<AppBranding>(
              valueListenable: BrandingService.instance.branding,
              builder: (context, branding, _) => Container(
                padding: const EdgeInsets.fromLTRB(20, 24, 16, 20),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.4),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    // Thin gold frame on a white circle.
                    Container(
                    width: 52,
                    height: 52,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: const Color.fromARGB(255, 255, 210, 148), width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: const Color.fromARGB(255, 255, 211, 124).withOpacity(0.6), // The glow color
                          blurRadius: 5.0, // Adjust this to make the glow softer or sharper
                          spreadRadius: 2.0, // Adjust this to make the glow extend further
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/logo_app_icon.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            branding.companyName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              letterSpacing: -0.5,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Loan & Collection',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
                      onPressed: () => Navigator.of(context).pop(),
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            // --- MENU ITEMS ---
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 20),
                physics: const BouncingScrollPhysics(), // Smoother scrolling feel
                children: [
                  for (final section in sections)
                    _buildSection(context, section, user.role),
                ],
              ),
            ),

            // --- FLOATING FOOTER ---
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                children: [
                  UserAvatar(
                    user: user,
                    radius: 20,
                    backgroundColor: scheme.primary,
                    textStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: scheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          user.role.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.logout_rounded, color: scheme.error, size: 22),
                    tooltip: 'Logout',
                    onPressed: () async {
                      // --- NEW CONFIRMATION LOGIC ADDED HERE ---
                      final confirm = await AppConfirmDialog.show(
                        context: context,
                        title: 'Confirm Logout',
                        message: 'Are you sure you want to log out of your account?',
                        confirmLabel: 'Logout',
                        confirmButtonColor: scheme.error,
                      );

                      if (confirm == true && context.mounted) {
                        SessionService.instance.logout();
                        Navigator.of(context).pushNamedAndRemoveUntil(
                          AppRoutes.login,
                          (route) => false,
                        );
                      }
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.errorContainer.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, _DrawerSection section, UserRole role) {
    final visibleItems = role == UserRole.admin
        ? section.items.where((i) => PrivilegeService.instance.isEnabledForAdmin(i.route)).toList()
        : section.items;

    if (visibleItems.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 20, 8),
          child: Text(
            section.title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: scheme.primary, // Tinted section headers
              letterSpacing: 1.2,
            ),
          ),
        ),
        for (final item in visibleItems) _buildItem(context, item),
      ],
    );
  }

  Widget _buildItem(BuildContext context, _DrawerItem item) {
    final scheme = Theme.of(context).colorScheme;
    final bool selected = currentRoute == item.route;
    
    // Modern colors for selection state
    final activeColor = scheme.primary;
    final inactiveColor = scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: selected ? activeColor.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            highlightColor: activeColor.withValues(alpha: 0.05),
            splashColor: activeColor.withValues(alpha: 0.1),
            onTap: () {
              Navigator.of(context).pop();
              if (!selected) {
                Navigator.of(context).pushReplacementNamed(item.route);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    item.icon,
                    size: 22,
                    color: selected ? activeColor : inactiveColor,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 14,
                        color: selected ? activeColor : scheme.onSurface,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: activeColor,
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