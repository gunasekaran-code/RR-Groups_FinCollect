import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../models/user_role.dart';
import '../routes/app_routes.dart';
import '../services/connectivity_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../screens/agent_collection/agent_collection_screen.dart';
import '../screens/collections/collections_screen.dart';
import '../screens/customers/customers_screen.dart';
import '../screens/dashboard/admin_dashboard.dart';
import '../screens/dashboard/agent_dashboard.dart';
import '../screens/dashboard/customer_dashboard.dart';
import '../screens/funds/funds_screen.dart';
import '../screens/loans/loans_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/notifications/notification_state.dart';
import '../screens/repayment/repayment_schedule_screen.dart';
import '../screens/settings/profile_page.dart';
import '../theme/confirm_dialog.dart'; // Adjust path if needed
import '../screens/chit_groups/chit_groups_screen.dart';
import 'app_navbar.dart';
import 'notifications_dropdown_panel.dart';
import 'app_drawer.dart';
import 'no_internet_view.dart';
import 'user_avatar.dart';

class _AppShellContentOnly extends InheritedWidget {
  const _AppShellContentOnly({required super.child});

  static bool of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_AppShellContentOnly>() !=
        null;
  }

  @override
  bool updateShouldNotify(_AppShellContentOnly oldWidget) => false;
}

class AppShell extends StatefulWidget {
  final String currentRoute;
  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final bool showBackButton;
  final VoidCallback? onBack;

  const AppShell({
    super.key,
    required this.currentRoute,
    required this.title,
    this.subtitle,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.showBackButton = false,
    this.onBack,
  });

  static const Map<String, String> _tabTitles = {
    AppRoutes.dashboard: 'Dashboard',
    AppRoutes.customers: 'Customers',
    AppRoutes.loans: 'Loans',
    AppRoutes.repayment: 'Repayment Schedule',
    AppRoutes.collections: 'Collections',
    AppRoutes.chitGroups: 'Chits',
    AppRoutes.funds: 'My Funds',
    AppRoutes.notifications: 'Notifications',
    AppRoutes.profile: 'My Profile',
    AppRoutes.settings: 'Settings',
  };

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late String _activeRoute;

  @override
  void initState() {
    super.initState();
    _activeRoute = widget.currentRoute;
    NotificationState.instance.refreshUnreadCount();
    ConnectivityService.instance.addListener(_onConnectivityChanged);
  }

  @override
  void dispose() {
    ConnectivityService.instance.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  void _onConnectivityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentRoute != widget.currentRoute) {
      _activeRoute = widget.currentRoute;
    }
  }

  String get _headerTitle {
    if (_activeRoute == widget.currentRoute) return widget.title;
    return AppShell._tabTitles[_activeRoute] ?? widget.title;
  }

  // ---------------------------------------------------------------------------
  // DROPDOWN SIZING & ANCHORING
  // ---------------------------------------------------------------------------

  /// Key on the right-most app-bar button (the profile avatar). Both
  /// dropdowns anchor to its right edge so they open flush with the same
  /// gutter on every phone width, instead of the notifications panel hanging
  /// off the bell and spilling over the title.
  final GlobalKey _profileButtonKey = GlobalKey();

  static const double _screenGutter = 12.0;

  /// Shared by the profile and notifications dropdowns so both open at the
  /// same size.
  static const double _dropdownPreferredWidth = 250.0;

  /// Distance from the screen's right edge to the right edge of [key]'s
  /// widget, clamped so the panel never runs past the left edge either.
  double _rightInsetFor(BuildContext context, GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return _screenGutter;
    final screenWidth = MediaQuery.of(context).size.width;
    final topRight = box.localToGlobal(
      Offset(box.size.width, 0),
    );
    final inset = screenWidth - topRight.dx;
    return inset.clamp(_screenGutter, screenWidth - _screenGutter);
  }

  /// The panel's width on this screen: [preferred] on anything roomy, but
  /// never wide enough to run past the left edge on a small phone, where the
  /// panel's own right [inset] eats into the space available to it.
  double _dropdownWidth(
    BuildContext context, {
    required double inset,
    required double preferred,
  }) {
    return math.min(
      preferred,
      MediaQuery.of(context).size.width - inset - _screenGutter,
    );
  }

  /// Keeps a panel inside the viewport when the screen is short — a small
  /// phone in landscape, or one with the keyboard up.
  double _dropdownMaxHeight(BuildContext context, double topPadding) {
    final media = MediaQuery.of(context);
    return media.size.height - topPadding - media.padding.bottom - 16;
  }

  // ---------------------------------------------------------------------------
  // PROFILE DROPDOWN MENU
  // ---------------------------------------------------------------------------
  void _showProfileDropdown(BuildContext context, AppUser? user) {
    final topPadding = MediaQuery.of(context).padding.top + kToolbarHeight + 6;
    final rightInset = _rightInsetFor(context, _profileButtonKey);
    final panelWidth = _dropdownWidth(
      context,
      inset: rightInset,
      preferred: _dropdownPreferredWidth,
    );

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Profile Menu',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (dialogContext, animation, _, child) {
        final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);

        return Stack(
          children: [
            Positioned(
              top: topPadding,
              right: rightInset,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.88, end: 1.0).animate(curve),
                alignment: Alignment.topRight,
                child: FadeTransition(
                  opacity: curve,
                  child: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: panelWidth,
                      child: Container(
                      constraints: BoxConstraints(
                        maxHeight: _dropdownMaxHeight(context, topPadding),
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.kSurface,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: AppColors.kBorder.withValues(alpha: 0.8),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.ink900.withValues(alpha: 0.12),
                            blurRadius: 28,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      // Scrolls rather than overflows when the panel hits the
                      // height cap on a short screen.
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // User Info Card Header
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                              child: Row(
                                children: [
                                  UserAvatar(
                                    user: user,
                                    radius: 20,
                                    backgroundColor: AppColors.gold600,
                                    textStyle: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          user?.name ?? 'User',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                            color: AppColors.kTextDark,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 5),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.gold50,
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(
                                              color: AppColors.gold200,
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Text(
                                            (user?.role.label ?? 'ADMIN').toUpperCase(),
                                            style: const TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w800,
                                              color: AppColors.gold700,
                                              letterSpacing: 0.4,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(
                              height: 1,
                              color: AppColors.kBorder.withValues(alpha: 0.7),
                            ),
                            const SizedBox(height: 4),

                            // Menu Items
                            _buildDropdownItem(
                              icon: Icons.person_outline_rounded,
                              label: 'My Profile',
                              onTap: () {
                                Navigator.pop(dialogContext);
                                setState(() => _activeRoute = AppRoutes.profile);
                              },
                            ),
                            _buildDropdownItem(
                              icon: Icons.notifications_none_rounded,
                              label: 'Notifications',
                              onTap: () {
                                Navigator.pop(dialogContext);
                                setState(() => _activeRoute = AppRoutes.notifications);
                              },
                            ),
                            _buildDropdownItem(
                              icon: Icons.settings_outlined,
                              label: 'Settings',
                              onTap: () {
                                Navigator.pop(dialogContext);
                                Navigator.of(context).pushNamed(AppRoutes.settings);
                              },
                            ),

                            const SizedBox(height: 4),
                            Divider(
                              height: 1,
                              color: AppColors.kBorder.withValues(alpha: 0.7),
                            ),

                            // Sign Out Button
                            _buildDropdownItem(
                              icon: Icons.logout_rounded,
                              label: 'Sign Out',
                              color: AppColors.kDanger,
                              onTap: () async {
                                Navigator.pop(dialogContext);
                                final confirm = await AppConfirmDialog.show(
                                  context: context,
                                  title: 'Confirm Logout',
                                  message: 'Are you sure you want to sign out?',
                                  confirmLabel: 'Sign Out',
                                  confirmButtonColor: AppColors.kDanger,
                                );
                                if (confirm == true && context.mounted) {
                                  SessionService.instance.logout();
                                  Navigator.of(context).pushNamedAndRemoveUntil(
                                    AppRoutes.login,
                                    (route) => false,
                                  );
                                }
                              },
                            ),
                            const SizedBox(height: 6),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // NOTIFICATIONS DROPDOWN MENU
  // ---------------------------------------------------------------------------
  void _showNotificationsDropdown(BuildContext context) {
    final media = MediaQuery.of(context);
    final topPadding = media.padding.top + kToolbarHeight + 6;
    final rightInset = _rightInsetFor(context, _profileButtonKey);
    final panelWidth = _dropdownWidth(
      context,
      inset: rightInset,
      preferred: _dropdownPreferredWidth,
    );

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Notifications Menu',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (dialogContext, animation, _, child) {
        final curve =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);

        return Stack(
          children: [
            Positioned(
              top: topPadding,
              right: rightInset,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.88, end: 1.0).animate(curve),
                alignment: Alignment.topRight,
                child: FadeTransition(
                  opacity: curve,
                  child: Material(
                    color: Colors.transparent,
                    // Force the exact width — don't let the panel's own
                    // intrinsic sizing push it wider than the screen allows.
                    child: SizedBox(
                      width: panelWidth,
                      child: NotificationsDropdownPanel(
                        width: panelWidth,
                        maxHeight: _dropdownMaxHeight(context, topPadding),
                        onViewAll: () {
                          Navigator.pop(dialogContext);
                          // Match the profile menu: the shell swaps its own
                          // body rather than stacking another route on top
                          // of itself.
                          setState(
                              () => _activeRoute = AppRoutes.notifications);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDropdownItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final itemColor = color ?? AppColors.kTextDark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 20, color: itemColor),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: color != null ? FontWeight.w600 : FontWeight.w500,
                  color: itemColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SCAFFOLD & APPBAR
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_AppShellContentOnly.of(context)) {
      return widget.body;
    }

    final AppUser? user = SessionService.instance.currentUser;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        elevation: 0,
        titleSpacing: 8,
        title: Text(
          _headerTitle,
          style: TextStyle(
            color: scheme.onSurface,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        leading: widget.showBackButton
            ? IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
              )
            : null,
actions: [
          // 1. Notification Action Button (Styled Bell)
          // The builder's own context sits inside the AppBar, which strips the
          // status-bar inset from MediaQuery — so it's deliberately unnamed and
          // the dropdown is opened with the shell's context, exactly like the
          // profile menu. Otherwise the panel lands a status bar too high.
          AnimatedBuilder(
            animation: NotificationState.instance,
            builder: (_, __) {
              final unreadCount = NotificationState.instance.unreadCount;
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.gold50.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.gold200.withValues(alpha: 0.5),
                  ),
                ),
                child: IconButton(
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                  tooltip: unreadCount == 0
                      ? 'Notifications'
                      : '$unreadCount unread notifications',
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(
                        Icons.notifications_none_rounded,
                        color: AppColors.gold700,
                        size: 21,
                      ),
                      if (unreadCount > 0)
                        Positioned(
                          right: -5,
                          top: -5,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 15),
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: AppColors.kDanger,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              unreadCount > 99 ? '99+' : '$unreadCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  onPressed: () => _showNotificationsDropdown(context),
                ),
              );
            },
          ),

          const SizedBox(width: 12),

           // 2. Profile Action Button (Avatar with Light Gold Border)
          Padding(
            key: _profileButtonKey,
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _showProfileDropdown(context, user),
                  child: Container(
                    // This padding creates the small gap between the border and the avatar
                    padding: const EdgeInsets.all(2.5), 
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.gold200, // The light gold border
                        width: 1.5,
                      ),
                    ),
                    child: UserAvatar(
                      user: user,
                      radius: 17, // Adjusted slightly so the overall button isn't too huge
                      backgroundColor: AppColors.gold600,
                      textStyle: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      drawer: widget.showBackButton
          ? null
          : AppDrawer(currentRoute: currentRoute),
      body: SafeArea(
        // Offline replaces the page body only; the app bar and bottom nav
        // stay usable. Coming back online remounts the page so it reloads
        // whatever failed meanwhile.
        child: ConnectivityService.instance.isOffline
            ? const NoInternetView()
            : KeyedSubtree(
                key: ValueKey(ConnectivityService.instance.reconnectCount),
                child: _buildActiveBody(),
              ),
      ),
      bottomNavigationBar: AppBottomNav(
        currentRoute: _activeRoute,
        onTabSelected: (route) => setState(() => _activeRoute = route),
      ),
      floatingActionButton: !ConnectivityService.instance.isOffline &&
              _activeRoute == widget.currentRoute
          ? widget.floatingActionButton
          : null,
    );
  }

  String get currentRoute => _activeRoute;

  Widget _buildActiveBody() {
    if (_activeRoute == widget.currentRoute) return widget.body;

    final user = SessionService.instance.currentUser;
    return _AppShellContentOnly(
      child: switch (_activeRoute) {
        AppRoutes.dashboard => _dashboardForRole(user?.role),
        AppRoutes.customers => const CustomersScreen(),
        AppRoutes.loans => const LoansScreen(),
        AppRoutes.repayment => const RepaymentScheduleScreen(),
        AppRoutes.funds => const FundsScreen(),
        AppRoutes.notifications => const NotificationsScreen(),
        AppRoutes.chitGroups => const ChitGroupsScreen(),
        AppRoutes.collections => user?.role == UserRole.agent
            ? const AgentCollectionScreen()
            : const CollectionsScreen(),
        AppRoutes.profile => const ProfilePage(showScaffold: false),
        _ => widget.body,
      },
    );
  }

  Widget _dashboardForRole(UserRole? role) {
    return switch (role) {
      UserRole.customer => const CustomerDashboardScreen(),
      UserRole.agent => const AgentDashboardScreen(),
      UserRole.owner || UserRole.admin || null => const DashboardScreen(),
    };
  }
}
