import 'package:flutter/material.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../theme/glass_toast.dart';
import '../../theme/locale_controller.dart';
import '../../theme/theme_controller.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/user_role.dart';
import '../../services/session_service.dart';
import '../../services/auth_api_service.dart';
import '../../screens/help/contact_support_screen.dart';
import '../../screens/help/faq_screen.dart';
import '../../widgets/user_avatar.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _paymentReminders = true;
  bool _groupUpdates = true;
  // bool _biometricLogin = false;
  
  bool get _darkMode => ThemeController.mode.value == ThemeMode.dark;

  void _notify(String label, AppLocalizations l10n) {
    ToastService.show(
      title: label,
      message: l10n.connectBackendToEnable,
      type: ToastType.info,
    );
  }

  void _openLanguagePicker() {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                child: Row(
                  children: [
                    Text(
                      l10n.selectLanguage,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.kTextDark,
                      ),
                    ),
                  ],
                ),
              ),
              for (final option in LocaleController.supported.entries)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  title: Text(
                    option.key,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: AppColors.kTextDark,
                    ),
                  ),
                  trailing: option.value == LocaleController.locale.value
                      ? Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppColors.kGold.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.check,
                              color: AppColors.kGold, size: 20),
                        )
                      : null,
                  onTap: () {
                    // Persists against the signed-in user's id (not just this
                    // device), so it's restored on their next login here.
                    LocaleController.setForUser(
                      SessionService.instance.currentUser?.userId ?? '',
                      option.value,
                    );
                    Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmLogout() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.kSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          l10n.logout,
          style: const TextStyle(
            color: AppColors.kTextDark,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          l10n.confirmLogoutQuestion,
          style: const TextStyle(color: AppColors.kTextMuted, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              l10n.cancel,
              style: const TextStyle(
                color: AppColors.kTextMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.kDanger.withOpacity(0.1),
              foregroundColor: AppColors.kDanger,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.logout,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      SessionService.instance.logout();
      await AuthApiService.instance.logout();
      _notify(l10n.loggedOut, l10n);
      if (mounted) {
        Navigator.of(context)
            .pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final notifications = _Section(
      icon: Icons.notifications_active_outlined,
      title: l10n.notifications,
      children: [
        _SwitchTile(
          icon: Icons.payments_rounded,
          label: l10n.paymentReminders,
          value: _paymentReminders,
          onChanged: (v) => setState(() => _paymentReminders = v),
        ),
        _SwitchTile(
          icon: Icons.groups_rounded,
          label: l10n.groupUpdates,
          value: _groupUpdates,
          onChanged: (v) => setState(() => _groupUpdates = v),
        ),
      ],
    );

    final preferences = _Section(
      icon: Icons.tune_rounded,
      title: l10n.preferences,
      children: [
        _SettingsTile(
          icon: Icons.language_rounded,
          label: l10n.language,
          trailingText: LocaleController.labelFor(
            LocaleController.locale.value,
          ),
          onTap: _openLanguagePicker,
        ),
        _SwitchTile(
          icon: Icons.dark_mode_rounded,
          label: l10n.darkMode,
          value: _darkMode,
          onChanged: (v) {
            ThemeController.mode.value = v ? ThemeMode.dark : ThemeMode.light;
            setState(() {});
          },
        ),
      ],
    );

    final help = _Section(
      icon: Icons.support_rounded,
      title: l10n.help,
      children: [
        _SettingsTile(
          icon: Icons.support_agent_rounded,
          label: l10n.contactSupport,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ContactSupportScreen()),
          ),
        ),
        _SettingsTile(
          icon: Icons.help_outline_rounded,
          label: l10n.faq,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FaqScreen()),
          ),
        ),
      ],
    );

    return AppShell(
      currentRoute: AppRoutes.settings,
      title: l10n.settings,
      body: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = width < 600 ? 16.0 : 24.0;
        // Wide tablets: sections side by side instead of one long column.
        final twoColumns = width >= 900;

        return ListView(
          padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 32),
          physics: const BouncingScrollPhysics(),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Gold profile card
                    _buildProfileCard(context, l10n),
                    const SizedBox(height: 24),

                    // 2–4. Notifications, preferences, help
                    if (twoColumns)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                notifications,
                                const SizedBox(height: 20),
                                help,
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(child: preferences),
                        ],
                      )
                    else ...[
                      notifications,
                      const SizedBox(height: 20),
                      preferences,
                      const SizedBox(height: 20),
                      help,
                    ],

                    const SizedBox(height: 28),

                    // 5. Logout
                    Align(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: _buildLogoutButton(l10n),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildLogoutButton(AppLocalizations l10n) {
    return Material(
      color: AppColors.kSurface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _confirmLogout,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.kDanger.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.kDanger.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.logout_rounded,
                    size: 18, color: AppColors.kDanger),
              ),
              const SizedBox(width: 10),
              Text(
                l10n.logout,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.kDanger,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Gold profile card at the top: avatar, name, role and an Edit Profile
  /// pill. Tapping anywhere opens the profile screen.
  Widget _buildProfileCard(BuildContext context, AppLocalizations l10n) {
    final user = SessionService.instance.currentUser;
    final name = user?.name.trim() ?? '';

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _kGoldGradient,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.kGold.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pushNamed(AppRoutes.profile),
          child: Stack(
            children: [
              // Soft decorative rings in the corner.
              Positioned(
                right: -30,
                top: -40,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
              ),
              Positioned(
                right: 40,
                bottom: -50,
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.gold200, width: 2),
                      ),
                      // Same avatar the app shell shows — real photo when the
                      // user has one, initials fallback otherwise.
                      child: UserAvatar(
                        user: user,
                        radius: 30,
                        backgroundColor: AppColors.gold800,
                        textStyle: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isNotEmpty ? name : l10n.profile,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: AppColors.kTextOnDark,
                            ),
                          ),
                          if (user != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              user.role.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.kTextOnDarkMuted,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.gold100,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.gold300),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.edit_outlined,
                                    size: 13, color: AppColors.gold800),
                                const SizedBox(width: 5),
                                Text(
                                  l10n.editProfile,
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
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.kTextOnDark,
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

/// Same gold strip as the loan cards and table headers.
const List<Color> _kGoldGradient = [Color(0xFFA9791F), Color(0xFFC48E28)];

/// Gold-tinted rounded badge holding a tile's icon.
Widget _goldIconBadge(IconData icon) => Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.gold50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.gold200),
      ),
      child: Icon(icon, size: 20, color: AppColors.kGoldDark),
    );

/// A grouped settings card with a gold gradient title strip.
class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _Section({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.kGold.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.kGoldLight.withValues(alpha: 0.5)),
                  ),
                  child: Icon(icon, size: 16, color: AppColors.gold200),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.kTextOnDark,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: 64, right: 16),
                child: Divider(height: 1, color: AppColors.kBorder),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A tappable settings row with a gold icon badge.
class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailingText;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailingText,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.gold50,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(
            children: [
              _goldIconBadge(icon),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.kTextDark,
                  ),
                ),
              ),
              if (trailingText != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.gold100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.gold300),
                  ),
                  child: Text(
                    trailingText!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.gold800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.kGoldDark,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A settings row with a gold icon badge and a gold switch.
class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          _goldIconBadge(icon),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.kTextDark,
              ),
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.kGold,
            inactiveThumbColor: AppColors.kTextMuted,
            inactiveTrackColor: AppColors.kBorder,
            trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? AppColors.kGold
                    : AppColors.kBorder),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
