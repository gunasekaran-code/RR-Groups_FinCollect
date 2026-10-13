import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/connectivity_service.dart';

/// Full-body "No Internet Connection" screen shown by [AppShell] in place of
/// the page while the device is offline. The app bar and bottom nav stay
/// put around it.
class NoInternetView extends StatefulWidget {
  const NoInternetView({super.key});

  static const Color _accent = Color(0xFFC3901F);

  @override
  State<NoInternetView> createState() => _NoInternetViewState();
}

class _NoInternetViewState extends State<NoInternetView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _checking = false;

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    if (_checking) return;
    setState(() => _checking = true);
    _spin.repeat();
    // Keep the spinner up long enough to read as "tried", even when the
    // check itself comes back instantly.
    await Future.wait([
      ConnectivityService.instance.recheck(),
      Future<void>.delayed(const Duration(milliseconds: 800)),
    ]);
    if (!mounted) return;
    _spin.stop();
    _spin.reset();
    setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // The artwork is 1080×938; on short screens it gives up its flat
        // orange top rather than squeezing the text and button.
        final artHeight =
            math.min(width * 938 / 1080, constraints.maxHeight * 0.48);

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  SizedBox(
                    width: width,
                    height: artHeight,
                    child: Image.asset(
                      'assets/images/no_internet_illustration.png',
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomCenter,
                    ),
                  ),
                  const Spacer(flex: 2),
                  Image.asset(
                    'assets/images/no_internet_tower.png',
                    width: 34,
                    height: 51,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'NO INTERNET CONNECTION',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'No Internet Connection found, check your\nConnection . Or Try again',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: isDark
                            ? const Color(0xFF9E9E9E)
                            : const Color(0xFFADADAD),
                      ),
                    ),
                  ),
                  const Spacer(flex: 3),
                  _RetryButton(
                    spin: _spin,
                    onPressed: _checking ? null : _retry,
                  ),
                  const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RetryButton extends StatelessWidget {
  final Animation<double> spin;
  final VoidCallback? onPressed;

  const _RetryButton({required this.spin, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Try again',
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: NoInternetView._accent.withValues(alpha: 0.35),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: NoInternetView._accent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(
              child: RotationTransition(
                turns: spin,
                child: const Icon(
                  Icons.sync_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
