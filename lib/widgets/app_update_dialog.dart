import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:upgrader/upgrader.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

/// Checks the store for a newer build and, if one exists, shows a
/// mandatory gold "Update Available" dialog that cannot be dismissed.
class AppUpdateChecker {
  AppUpdateChecker._();

  static const String _playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.cloudhawk.rrgroups';

  static final Upgrader _upgrader = Upgrader();

  /// Returns true when a newer version is published on the store.
  /// Any failure (offline, web, store lookup error) counts as "no update"
  /// so the user is never locked out of the app.
  static Future<bool> isUpdateAvailable() async {
    if (kIsWeb) return false;
    try {
      await _upgrader.initialize().timeout(const Duration(seconds: 8));
      return _upgrader.isUpdateAvailable();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _openStore() async {
    final url = _upgrader.currentAppStoreListingURL;
    final uri = Uri.parse(url == null || url.isEmpty ? _playStoreUrl : url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Shows the blocking update dialog. It never closes on its own; the user
  /// can only go to the store.
  static Future<void> showUpdateDialog(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Update Available',
      barrierColor: Colors.black.withOpacity(0.55),
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (context, animation, _, __) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return PopScope(
          canPop: false,
          child: FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
              child: _UpdateDialogCard(
                newVersion: _upgrader.currentAppStoreVersion,
                onUpdate: _openStore,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UpdateDialogCard extends StatelessWidget {
  const _UpdateDialogCard({required this.onUpdate, this.newVersion});

  final VoidCallback onUpdate;
  final String? newVersion;

  static const _goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEEDD82), Color(0xFFD4AF37), Color(0xFF996515)],
  );

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: AppColors.kSurface,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: AppColors.kGold.withOpacity(0.35),
                blurRadius: 40,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ---- Gold header with icon ----
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(top: 30, bottom: 26),
                decoration: const BoxDecoration(gradient: _goldGradient),
                child: Column(
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.22),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.6),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.system_update_rounded,
                        size: 42,
                        color: Colors.white,
                      ),
                    ),
                    if (newVersion != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Version $newVersion',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // ---- Body ----
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 24, 26, 26),
                child: Column(
                  children: [
                    const Text(
                      'Update Available',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.kTextDark,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'A new version of RR Groups is available.\n'
                      'Please update to continue.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: AppColors.kTextMuted,
                      ),
                    ),
                    const SizedBox(height: 26),
                    _GoldButton(label: 'Update Now', onPressed: onUpdate),
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

class _GoldButton extends StatelessWidget {
  const _GoldButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.gold400, AppColors.kGold, AppColors.kGoldDark],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.kGold.withOpacity(0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.download_rounded,
                    color: Colors.white, size: 22),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
