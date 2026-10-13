import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../theme/confirm_dialog.dart';
import '../../theme/glass_toast.dart';
import '../../models/AppNotification.dart';
import '../../models/user_role.dart';
import '../../services/NotificationService.dart';
import '../../services/session_service.dart';
import '../../services/customer_api_service.dart';
import 'notification_state.dart';

enum NotificationFilter { all, unread, emiDue, overdue, approvals, reminders }

extension NotificationFilterX on NotificationFilter {
  String label(AppLocalizations l10n) {
    switch (this) {
      case NotificationFilter.all:
        return l10n.filterAll;
      case NotificationFilter.unread:
        return l10n.filterUnread;
      case NotificationFilter.emiDue:
        return l10n.filterEmiDue;
      case NotificationFilter.overdue:
        return l10n.filterOverdue;
      case NotificationFilter.approvals:
        return l10n.filterApprovals;
      case NotificationFilter.reminders:
        return l10n.filterReminders;
    }
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

/// At or above this width the screen uses the tablet layout (same cut-off as
/// the other screens).
const double _tabletBreakpoint = 700;

/// Content stops growing past this so lines stay readable on big tablets.
const double _maxContentWidth = 1100;

/// Content at least this wide shows notifications two per row.
const double _twoColumnMinWidth = 900;

class _NotificationsScreenState extends State<NotificationsScreen> {
  NotificationFilter _filter = NotificationFilter.all;
  final ScrollController _scrollController = ScrollController();

  List<AppNotification> _notifications = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool get _canSendNotifications {
    final role = SessionService.instance.currentUser?.role;
    return role == UserRole.admin || role == UserRole.agent;
  }

  Future<void> _loadNotifications() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await NotificationService.fetchForCurrentUser();
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (!mounted) return;
      setState(() => _notifications = list);
      NotificationState.instance.setCount(list.where((n) => !n.read).length);
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() => _error = l10n.failedToLoadNotifications);
      ToastService.show(
        title: l10n.couldNotLoadNotificationsToastTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalCount => _notifications.length;
  int get _unreadCount => _notifications.where((n) => !n.read).length;
  int get _overdueCount =>
      _notifications.where((n) => n.type == NotificationType.overdue).length;

  int _countFor(NotificationFilter f) {
    switch (f) {
      case NotificationFilter.all:
        return _totalCount;
      case NotificationFilter.unread:
        return _unreadCount;
      case NotificationFilter.emiDue:
        return _notifications
            .where((n) => n.type == NotificationType.emiDue)
            .length;
      case NotificationFilter.overdue:
        return _overdueCount;
      case NotificationFilter.approvals:
        return _notifications
            .where((n) => n.type == NotificationType.approval)
            .length;
      case NotificationFilter.reminders:
        return _notifications
            .where((n) => n.type == NotificationType.reminder)
            .length;
    }
  }

  List<AppNotification> get _filtered {
    switch (_filter) {
      case NotificationFilter.all:
        return _notifications;
      case NotificationFilter.unread:
        return _notifications.where((n) => !n.read).toList();
      case NotificationFilter.emiDue:
        return _notifications
            .where((n) => n.type == NotificationType.emiDue)
            .toList();
      case NotificationFilter.overdue:
        return _notifications
            .where((n) => n.type == NotificationType.overdue)
            .toList();
      case NotificationFilter.approvals:
        return _notifications
            .where((n) => n.type == NotificationType.approval)
            .toList();
      case NotificationFilter.reminders:
        return _notifications
            .where((n) => n.type == NotificationType.reminder)
            .toList();
    }
  }

  void _markAllRead() async {
    final unreadIds =
        _notifications.where((n) => !n.read).map((n) => n.id).toList();
    if (unreadIds.isEmpty) return;

    final previousStates = {for (var n in _notifications) n.id: n.read};

    setState(() {
      for (var n in _notifications) {
        n.read = true;
      }
    });

    final l10n = AppLocalizations.of(context);

    try {
      await NotificationService.markAllRead(unreadIds);
      if (!mounted) return;
      NotificationState.instance.setCount(0);
      ToastService.show(
        title: l10n.allNotificationsClearedToastTitle,
        message: l10n.allNotificationsClearedToastMessage,
        type: ToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        for (var n in _notifications) {
          n.read = previousStates[n.id] ?? n.read;
        }
      });
      ToastService.show(
        title: l10n.failedToUpdateToastTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  void _deleteNotification(AppNotification n) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: l10n.deleteNotificationTitle,
      message: l10n.deleteNotificationMessage(n.title),
      confirmLabel: l10n.delete,
      confirmButtonColor: AppColors.kDanger,
    );

    if (confirmed != true || !mounted) return;

    final index = _notifications.indexOf(n);
    setState(() => _notifications.removeWhere((x) => x.id == n.id));

    try {
      await NotificationService.delete(n.id);
      if (!mounted) return;
      NotificationState.instance
          .setCount(_notifications.where((x) => !x.read).length);
      ToastService.show(
        title: l10n.notificationRemovedToastTitle,
        message: n.title,
        type: ToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _notifications.insert(index.clamp(0, _notifications.length), n),
      );
      ToastService.show(
        title: l10n.failedToDeleteToastTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  void _markRead(AppNotification notification) async {
    if (notification.read) return;

    setState(() => notification.read = true);
    final l10n = AppLocalizations.of(context);

    try {
      await NotificationService.markRead(notification.id);
      if (!mounted) return;
      NotificationState.instance
          .setCount(_notifications.where((n) => !n.read).length);
      ToastService.show(
          title: l10n.markedAsReadToastTitle, type: ToastType.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => notification.read = false);
      ToastService.show(
        title: l10n.failedToMarkAsReadToastTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  // ==== NEW: Notification Details Big Card Dialog ====
  void _showNotificationDetails(AppNotification n) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) {
        final isTablet = MediaQuery.of(context).size.width >= _tabletBreakpoint;
        return Dialog(
          backgroundColor: AppColors.kSurface,
          clipBehavior: Clip.antiAlias,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          // The default 40px side inset wastes a lot of a phone's width.
          insetPadding: isTablet
              ? const EdgeInsets.symmetric(horizontal: 40, vertical: 24)
              : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isTablet ? 560 : 500),
            // Scrolls when a long message would not fit on the screen.
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Gold header — same strip as the notification cards.
                  _NotificationHeader(
                    notification: n,
                    titleMaxLines: null,
                    padding: EdgeInsets.fromLTRB(
                        isTablet ? 24 : 18, 18, isTablet ? 18 : 12, 18),
                    trailing: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded,
                          color: AppColors.kTextOnDark),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(isTablet ? 28 : 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _notificationTypeBadge(n),
                        const SizedBox(height: 24),
                        // Full Message Body
                        Text(
                          n.body,
                          style: const TextStyle(
                              fontSize: 15,
                              height: 1.5,
                              color: AppColors.kTextDark),
                        ),
                        const SizedBox(height: 24),
                        // Meta Info Footer
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF9FAFB),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.kBorder),
                          ),
                          // Wrap instead of Row so a long user id drops the time
                          // onto its own line instead of overflowing on phones.
                          child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Text(
                                l10n.userIdLabel(n.userId),
                                style: const TextStyle(
                                    color: AppColors.kTextMuted, fontSize: 12),
                              ),
                              Text(
                                formatNotificationTime(n.timestamp),
                                style: const TextStyle(
                                    color: AppColors.kTextMuted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Action Buttons
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () {
                                Navigator.of(context).pop();
                                _deleteNotification(
                                    n); // Shows the confirmation dialog automatically
                              },
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 18),
                              label: Text(l10n.delete),
                              style: TextButton.styleFrom(
                                  foregroundColor: AppColors.kDanger),
                            ),
                            if (!n.read)
                              ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  _markRead(n);
                                },
                                icon: const Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 18),
                                // Use localized string if you have one, falling back to basic text format
                                label: const Text('Mark as Read'),
                              )
                            else
                              OutlinedButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: Text(l10n.cancel), // Just closes
                              ),
                          ],
                        )
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Uses the sheet's own context: the screen's context sits under the
  // Scaffold, which strips the keyboard inset, so the sheet would never lift.
  Widget _sheetFrame(BuildContext context, {required Widget child}) {
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

  Future<void> _openSendDialog() async {
    final isTablet = MediaQuery.of(context).size.width >= _tabletBreakpoint;
    final Future<bool?> result = isTablet
        // A full-width bottom sheet stretches the form across the whole
        // tablet, so tablets get a centred dialog instead.
        ? showDialog<bool>(
            context: context,
            barrierColor: Colors.black.withOpacity(0.4),
            builder: (context) => Dialog(
              backgroundColor: AppColors.kSurface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: const SingleChildScrollView(
                  child: _SendNotificationDialog(),
                ),
              ),
            ),
          )
        : showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black.withOpacity(0.4),
            builder: (context) =>
                _sheetFrame(context, child: const _SendNotificationDialog()),
          );
    if (await result == true) _loadNotifications();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (_loading) {
      return AppShell(
        currentRoute: AppRoutes.notifications,
        title: l10n.notificationsScreenTitle,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _notifications.isEmpty) {
      return AppShell(
        currentRoute: AppRoutes.notifications,
        title: l10n.notificationsScreenTitle,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.kTextMuted)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _loadNotifications,
                  child: Text(l10n.retry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final filtered = _filtered;

    return AppShell(
      currentRoute: AppRoutes.notifications,
      title: l10n.notificationsScreenTitle,
      body: LayoutBuilder(builder: (context, constraints) {
        final isTablet = constraints.maxWidth >= _tabletBreakpoint;
        final hPad = isTablet ? 24.0 : 16.0;
        final contentWidth = (constraints.maxWidth - hPad * 2)
            .clamp(0.0, _maxContentWidth)
            .toDouble();
        final twoColumns = contentWidth >= _twoColumnMinWidth;

        return RefreshIndicator(
          onRefresh: _loadNotifications,
          child: ListView(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(hPad, isTablet ? 24 : 16, hPad, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(l10n, isTablet),
                      SizedBox(height: isTablet ? 24 : 20),
                      _buildStats(l10n, isTablet),
                      SizedBox(height: isTablet ? 24 : 20),
                      _buildFilters(l10n, isTablet),
                      SizedBox(height: isTablet ? 24 : 20),
                      _buildList(l10n, filtered, isTablet, twoColumns),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  /// Phone: subtitle above two full-width buttons.
  /// Tablet: subtitle on the left, buttons sized to their labels on the right.
  Widget _buildHeader(AppLocalizations l10n, bool isTablet) {
    final subtitle = Text(
      l10n.notificationsSubtitle,
      style:
          TextStyle(color: AppColors.kTextMuted, fontSize: isTablet ? 15 : 14),
    );
    final buttonPadding =
        EdgeInsets.symmetric(horizontal: isTablet ? 20 : 12, vertical: 14);
    final markAll = OutlinedButton.icon(
      onPressed: _unreadCount == 0 ? null : _markAllRead,
      icon: const Icon(Icons.done_all_rounded, size: 18),
      label: Text(l10n.markAllRead),
      style: OutlinedButton.styleFrom(padding: buttonPadding),
    );
    final send = ElevatedButton.icon(
      onPressed: _openSendDialog,
      icon: const Icon(Icons.send_rounded, size: 18),
      label: Text(l10n.send),
      style: ElevatedButton.styleFrom(padding: buttonPadding),
    );

    if (isTablet) {
      return Row(
        children: [
          Expanded(child: subtitle),
          const SizedBox(width: 16),
          markAll,
          if (_canSendNotifications) ...[
            const SizedBox(width: 12),
            send,
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        subtitle,
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: markAll),
            if (_canSendNotifications) ...[
              const SizedBox(width: 10),
              Expanded(child: send),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildStats(AppLocalizations l10n, bool isTablet) {
    final cards = [
      _StatCard(
        icon: Icons.notifications_none_rounded,
        iconBg: const Color(0xFFDCEAFE),
        iconColor: AppColors.kInfo,
        label: l10n.statTotal,
        value: '$_totalCount',
        horizontal: isTablet,
      ),
      _StatCard(
        icon: Icons.notifications_off_outlined,
        iconBg: const Color(0xFFEDE9FE),
        iconColor: const Color(0xFF7C3AED),
        label: l10n.statUnread,
        value: '$_unreadCount',
        horizontal: isTablet,
      ),
      _StatCard(
        icon: Icons.error_outline_rounded,
        iconBg: const Color(0xFFFEE2E2),
        iconColor: AppColors.kDanger,
        label: l10n.statOverdue,
        value: '$_overdueCount',
        horizontal: isTablet,
      ),
    ];
    final gap = isTablet ? 16.0 : 10.0;

    // IntrinsicHeight + stretch keeps the three cards the same height when a
    // longer translated label wraps in one of them.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }

  /// Phone: one horizontally scrolling row. Tablet: every pill visible at
  /// once, wrapping onto a second line only if the width runs out.
  Widget _buildFilters(AppLocalizations l10n, bool isTablet) {
    Widget pill(NotificationFilter f) => _FilterPill(
          label: f.label(l10n),
          count: _countFor(f),
          selected: f == _filter,
          onTap: () => setState(() => _filter = f),
        );

    if (isTablet) {
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: NotificationFilter.values.map(pill).toList(),
      );
    }

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: NotificationFilter.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) => pill(NotificationFilter.values[index]),
      ),
    );
  }

  Widget _buildList(
    AppLocalizations l10n,
    List<AppNotification> filtered,
    bool isTablet,
    bool twoColumns,
  ) {
    if (filtered.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: isTablet ? 64 : 40),
        child: Center(
          child: Text(
            l10n.noNotificationsHere,
            style: const TextStyle(color: AppColors.kTextMuted),
          ),
        ),
      );
    }

    Widget card(AppNotification n, {bool fillHeight = false}) =>
        _NotificationCard(
          notification: n,
          onTap: () => _showNotificationDetails(n),
          onDelete: () => _deleteNotification(n),
          onMarkRead: () => _markRead(n),
          bodyMaxLines: isTablet ? 3 : 2,
          fillHeight: fillHeight,
        );

    if (!twoColumns) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final n in filtered)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: card(n),
            ),
        ],
      );
    }

    // Wide tablets (landscape): two cards per row, each row as tall as its
    // taller card so the grid lines up.
    const gap = 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < filtered.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: gap),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: card(filtered[i], fillHeight: true)),
                  const SizedBox(width: gap),
                  Expanded(
                    child: i + 1 < filtered.length
                        ? card(filtered[i + 1], fillHeight: true)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
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
    this.horizontal = false,
  });

  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;

  /// Icon beside the text instead of above it; used on tablets, where the
  /// cards are wide enough and the stacked layout leaves them mostly empty.
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final iconBox = Container(
      padding: EdgeInsets.all(horizontal ? 10 : 8),
      decoration:
          BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: iconColor, size: horizontal ? 22 : 18),
    );
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: horizontal ? 12 : 11,
            fontWeight: FontWeight.w600,
            color: AppColors.kTextMuted,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
                fontSize: horizontal ? 26 : 22,
                fontWeight: FontWeight.w700,
                color: AppColors.kTextDark),
          ),
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(horizontal ? 18 : 14),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: horizontal
          ? Row(
              children: [
                iconBox,
                const SizedBox(width: 14),
                Expanded(child: text),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                iconBox,
                const SizedBox(height: 10),
                text,
              ],
            ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? null : AppColors.kSurface,
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _kGoldGradient,
                )
              : null,
          borderRadius: BorderRadius.circular(999),
          border:
              Border.all(color: selected ? AppColors.kGold : AppColors.kBorder),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.kGold.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : AppColors.kTextDark,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.25)
                    : AppColors.gold50,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.kGoldDark,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Same gold strip as the loan cards and table headers.
const List<Color> _kGoldGradient = [Color(0xFFA9791F), Color(0xFFC48E28)];

/// Gold header strip shared by the notification card and the details dialog:
/// type icon, title, time and an "Unread" pill while unread.
class _NotificationHeader extends StatelessWidget {
  const _NotificationHeader({
    required this.notification,
    this.titleMaxLines = 1,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 14, 14),
  });

  final AppNotification notification;
  final int? titleMaxLines;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: padding,
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
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.kGold.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppColors.kGoldLight.withValues(alpha: 0.5)),
            ),
            child: Icon(n.type.icon, color: AppColors.gold200, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.title,
                  maxLines: titleMaxLines,
                  overflow: titleMaxLines == null
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.kTextOnDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatNotificationTime(n.timestamp),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.kTextOnDarkMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          if (!n.read) ...[
            const SizedBox(width: 8),
            Container(
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
                    decoration: const BoxDecoration(
                        color: AppColors.kInfo, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.filterUnread,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.gold800,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Coloured pill naming the notification type (EMI due, overdue, ...).
Widget _notificationTypeBadge(AppNotification n) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: n.type.badgeBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(n.type.icon, size: 13, color: n.type.badgeFg),
          const SizedBox(width: 5),
          Text(
            n.type.label,
            style: TextStyle(
              color: n.type.badgeFg,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.onTap,
    required this.onDelete,
    required this.onMarkRead,
    this.bodyMaxLines = 2,
    this.fillHeight = false,
  });

  final AppNotification notification;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onMarkRead;
  final int bodyMaxLines;

  /// True when laid out in a grid row of equal-height cards: the action row
  /// is then pushed to the bottom of the card.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final l10n = AppLocalizations.of(context);

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
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: n.read ? AppColors.kBorder : AppColors.kGold,
            width: n.read ? 1 : 1.4,
          ),
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
            _NotificationHeader(notification: n),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _notificationTypeBadge(n),
                  const SizedBox(height: 10),
                  Text(
                    n.body,
                    maxLines: bodyMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.kTextDark,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.kBackground,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline,
                            size: 15, color: AppColors.kGold),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            l10n.userIdLabel(n.userId),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.kTextMuted, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (fillHeight) const Spacer(),
            const Divider(height: 1),
            Row(
              children: [
                action(Icons.visibility_outlined, l10n.loansActionView,
                    AppColors.kGoldDark, onTap),
                if (!n.read)
                  action(Icons.check_circle_outline_rounded, 'Mark as read',
                      AppColors.kSuccess, onMarkRead),
                action(Icons.delete_outline_rounded, l10n.delete,
                    AppColors.kDanger, onDelete),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SendNotificationDialog extends StatefulWidget {
  const _SendNotificationDialog();

  @override
  State<_SendNotificationDialog> createState() =>
      _SendNotificationDialogState();
}

class _SendNotificationDialogState extends State<_SendNotificationDialog> {
  bool _allCustomers = true;
  List<Map<String, String>> _customers = []; // {id, name, email}
  Map<String, String> _customerUserIds = {}; // customer id -> portal profile id
  final Set<String> _selectedIds = {};
  String _search = '';
  String _type = 'info';
  final _titleCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  bool _loadingCustomers = true;
  bool _sending = false;

  List<Map<String, String>> _typeOptions(AppLocalizations l10n) => [
        {'value': 'info', 'label': l10n.typeInfo},
        {'value': 'reminder', 'label': l10n.typeReminder},
        {'value': 'emi_due', 'label': l10n.typeEmiDue},
        {'value': 'overdue', 'label': l10n.typeOverdue},
        {'value': 'approval', 'label': l10n.typeApproval},
      ];

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCustomers() async {
    try {
      final api = CustomerApiService();
      final list = await api.fetchAllLite();
      final logins = await api.fetchCustomerLogins();
      if (!mounted) return;
      setState(() {
        _customers = list;
        _customerUserIds = {
          for (final row in logins)
            if ((row['customer_id'] ?? '').isNotEmpty)
              row['customer_id']!: row['id']!,
        };
        _loadingCustomers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingCustomers = false);
      ToastService.show(
        title: AppLocalizations.of(context).couldNotLoadCustomersToastTitle,
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  List<Map<String, String>> get _filteredCustomers {
    if (_search.trim().isEmpty) return _customers;
    final q = _search.toLowerCase();
    return _customers
        .where((c) =>
            (c['name'] ?? '').toLowerCase().contains(q) ||
            (c['email'] ?? '').toLowerCase().contains(q))
        .toList();
  }

  int get _recipientCount => _allCustomers
      ? _customers.where((c) => _customerUserIds[c['id']] != null).length
      : _selectedIds.where(_customerUserIds.containsKey).length;

  Future<void> _handleSend() async {
    final l10n = AppLocalizations.of(context);

    if (_titleCtrl.text.trim().isEmpty) {
      ToastService.show(title: l10n.titleRequiredError, type: ToastType.error);
      return;
    }
    if (_allCustomers && _customers.isEmpty) {
      ToastService.show(
          title: l10n.noCustomersFoundError, type: ToastType.error);
      return;
    }
    if (_allCustomers && _customerUserIds.isEmpty) {
      ToastService.show(
          title: l10n.noLinkedCustomerLoginsFoundError, type: ToastType.error);
      return;
    }
    if (!_allCustomers && _selectedIds.isEmpty) {
      ToastService.show(
          title: l10n.selectAtLeastOneRecipientError, type: ToastType.error);
      return;
    }

    final recipientIds = _allCustomers
        ? _customers
            .map((c) => _customerUserIds[c['id']])
            .whereType<String>()
            .toList()
        : _selectedIds
            .map((customerId) => _customerUserIds[customerId])
            .whereType<String>()
            .toList();

    if (recipientIds.isEmpty) {
      ToastService.show(
        title: l10n.noEligibleRecipientsToastTitle,
        message: l10n.noEligibleRecipientsToastMessage,
        type: ToastType.error,
      );
      return;
    }

    setState(() => _sending = true);
    try {
      await NotificationService.send(
        userIds: recipientIds,
        type: _type,
        title: _titleCtrl.text.trim(),
        message: _messageCtrl.text.trim(),
      );
      if (!mounted) return;
      ToastService.show(
        title: l10n.notificationSentToastTitle,
        message: l10n.recipientsCount(_recipientCount),
        type: ToastType.success,
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ToastService.show(
          title: l10n.sendFailedToastTitle,
          message: e.toString(),
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
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
                child: const Icon(Icons.send_rounded,
                    color: AppColors.kGold, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.sendNotificationTitle,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.kTextDark)),
                    const SizedBox(height: 2),
                    Text(l10n.sendNotificationSubtitle,
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
          const SizedBox(height: 24),
          Text(l10n.recipientsLabel,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _ToggleChip(
                  icon: Icons.groups_outlined,
                  label: l10n.allCustomers,
                  trailing: '${_customerUserIds.length}',
                  selected: _allCustomers,
                  onTap: () => setState(() => _allCustomers = true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ToggleChip(
                  icon: Icons.person_search_outlined,
                  label: l10n.selectLabel,
                  selected: !_allCustomers,
                  onTap: () => setState(() => _allCustomers = false),
                ),
              ),
            ],
          ),
          if (!_allCustomers) ...[
            const SizedBox(height: 12),
            TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: l10n.searchCustomersHint,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.kBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _loadingCustomers
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _filteredCustomers.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text(l10n.noCustomersFoundInList,
                                style: const TextStyle(
                                    color: AppColors.kTextMuted)),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _filteredCustomers.length,
                          separatorBuilder: (_, __) => const Divider(
                              height: 1, color: AppColors.kBorder),
                          itemBuilder: (context, i) {
                            final c = _filteredCustomers[i];
                            final id = c['id']!;
                            final checked = _selectedIds.contains(id);
                            return CheckboxListTile(
                              value: checked,
                              enabled: _customerUserIds.containsKey(id),
                              onChanged: _customerUserIds.containsKey(id)
                                  ? (v) => setState(() {
                                        if (v == true) {
                                          _selectedIds.add(id);
                                        } else {
                                          _selectedIds.remove(id);
                                        }
                                      })
                                  : null,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(c['name'] ?? '',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.kTextDark)),
                              subtitle: Text(
                                  _customerUserIds.containsKey(id)
                                      ? (c['email'] ?? '')
                                      : l10n.noPortalLogin,
                                  style: const TextStyle(
                                      color: AppColors.kTextMuted,
                                      fontSize: 12)),
                              activeColor: AppColors.kGold,
                            );
                          },
                        ),
            ),
          ],
          const SizedBox(height: 20),
          Text(l10n.typeLabel,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _typeOptions(l10n).map((t) {
              final selected = _type == t['value'];
              return ChoiceChip(
                label: Text(t['label']!),
                selected: selected,
                onSelected: (_) => setState(() => _type = t['value']!),
                selectedColor: AppColors.kGold,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : AppColors.kTextDark,
                  fontWeight: FontWeight.w600,
                ),
                backgroundColor: const Color(0xFFF3F4F6),
                side: BorderSide.none,
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          Text(l10n.titleFieldLabel,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 8),
          TextField(
            controller: _titleCtrl,
            decoration:
                InputDecoration(isDense: true, hintText: l10n.titleFieldHint),
          ),
          const SizedBox(height: 16),
          Text(l10n.messageFieldLabel,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 8),
          TextField(
            controller: _messageCtrl,
            maxLines: 3,
            decoration:
                InputDecoration(isDense: true, hintText: l10n.messageFieldHint),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 420;
            final recipientLabel = Text(
              _recipientCount == 0
                  ? l10n.noRecipientsSelected
                  : l10n.recipientsSelectedCount(_recipientCount),
              style: const TextStyle(color: AppColors.kTextMuted, fontSize: 13),
            );
            final actionButtons = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed:
                      _sending ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _sending ? null : _handleSend,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  label: Text(l10n.send),
                ),
              ],
            );
            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  recipientLabel,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: actionButtons),
                ],
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [recipientLabel, actionButtons],
            );
          }),
        ],
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFEF3C7) : AppColors.kSurface,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: selected ? AppColors.kGold : AppColors.kBorder),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: selected ? AppColors.kGold : AppColors.kTextMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.kGold : AppColors.kTextDark)),
            ),
            if (trailing != null)
              Text(trailing!,
                  style: const TextStyle(color: AppColors.kTextMuted)),
          ],
        ),
      ),
    );
  }
}
