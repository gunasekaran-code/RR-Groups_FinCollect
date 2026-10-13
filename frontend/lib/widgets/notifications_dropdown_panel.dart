import 'package:flutter/material.dart';

import '../models/AppNotification.dart';
import '../screens/notifications/notification_state.dart';
import '../services/NotificationService.dart';
import '../theme/app_theme.dart';

// ---------------------------------------------------------------------------
// NOTIFICATIONS DROPDOWN PANEL
// ---------------------------------------------------------------------------

/// The panel behind the app bar's bell: a preview of the newest unread
/// notifications, with a link through to the full screen.
///
/// It owns its own fetch rather than taking a list, because the dropdown is
/// built from a transitionBuilder that reruns on every animation frame — a
/// future created there would restart ~14 times on the way in.
class NotificationsDropdownPanel extends StatefulWidget {
  const NotificationsDropdownPanel({
    super.key,
    required this.width,
    required this.maxHeight,
    required this.onViewAll,
    this.loader,
  });

  /// How many of the newest unread notifications the panel previews.
  static const int previewCount = 4;

  /// Height of the scrolling area between header and footer. Sized so the
  /// whole panel matches the profile dropdown's height (~268). Fixed, so the
  /// panel does not resize when the fetch lands.
  static const double contentHeight = 170;

  final double width;
  final double maxHeight;
  final VoidCallback onViewAll;

  /// Overrides where the notifications come from. Only used by tests; in the
  /// app this is left null and the panel reads the signed-in user's own.
  final Future<List<AppNotification>> Function()? loader;

  @override
  State<NotificationsDropdownPanel> createState() =>
      _NotificationsDropdownPanelState();
}

class _NotificationsDropdownPanelState
    extends State<NotificationsDropdownPanel> {
  late final Future<List<AppNotification>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadPreview();
  }

  Future<List<AppNotification>> _loadPreview() async {
    final fetch = widget.loader ?? NotificationService.fetchForCurrentUser;
    // Unread only, so the panel always agrees with the count on the bell.
    final unread = (await fetch()).where((n) => !n.read).toList();
    // Sort here rather than trusting the query's ordering, then keep only what
    // the panel can show.
    unread.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return unread.take(NotificationsDropdownPanel.previewCount).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          Divider(height: 1, color: AppColors.kBorder.withValues(alpha: 0.7)),
          // A fixed content height between the header and footer, so the panel
          // is exactly the same shape while loading as it is once the fetch
          // lands — no growing out to full height and snapping back, and the
          // same size again on every reload. The list scrolls inside it.
          //
          // Flexible only matters on a viewport too short for the full height;
          // with room to spare the SizedBox keeps its natural size.
          Flexible(
            child: SizedBox(
              height: NotificationsDropdownPanel.contentHeight,
              child: FutureBuilder<List<AppNotification>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return _centeredState(
                      const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return _messageState(
                      Icons.cloud_off_rounded,
                      "Couldn't load notifications",
                    );
                  }
                  final items = snapshot.data ?? const <AppNotification>[];
                  if (items.isEmpty) {
                    return _messageState(
                      Icons.notifications_none_rounded,
                      "You're all caught up",
                    );
                  }
                  return ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      indent: 56,
                      color: AppColors.kBorder.withValues(alpha: 0.5),
                    ),
                    itemBuilder: (context, i) => _row(items[i]),
                  );
                },
              ),
            ),
          ),
          Divider(height: 1, color: AppColors.kBorder.withValues(alpha: 0.7)),
          _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Notifications',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.kTextDark,
            ),
          ),
          AnimatedBuilder(
            animation: NotificationState.instance,
            builder: (context, _) {
              final count = NotificationState.instance.unreadCount;
              if (count == 0) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.gold100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count new',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.gold700,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _row(AppNotification n) {
    return InkWell(
      onTap: widget.onViewAll,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: n.type.iconBg,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(n.type.icon, size: 16, color: n.type.iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // No unread dot: every row here is unread, so it would mark
                  // all of them and tell the reader nothing.
                  Text(
                    n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.kTextDark,
                    ),
                  ),
                  if (n.body.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      n.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: AppColors.kTextMuted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    formatNotificationTime(n.timestamp),
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.ink400,
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

  Widget _footer() {
    return InkWell(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(22)),
      onTap: widget.onViewAll,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        child: const Text(
          'View all notifications',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.gold600,
          ),
        ),
      ),
    );
  }

  /// Centres a placeholder in the fixed content box. The box already supplies
  /// the height, so there's no vertical padding to push the content out of it
  /// when the panel is trimmed on a short screen.
  Widget _centeredState(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Center(child: child),
    );
  }

  Widget _messageState(IconData icon, String label) {
    return _centeredState(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: AppColors.ink50,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: AppColors.ink400),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: AppColors.kTextMuted,
            ),
          ),
        ],
      ),
    );
  }
}
