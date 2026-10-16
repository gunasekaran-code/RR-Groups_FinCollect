import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// App-wide online/offline state, watched by [AppShell] to swap the page body
/// for the "No Internet Connection" screen.
///
/// Two signals feed it: the OS reporting that every network interface went
/// away, and a request failing at the socket level (wifi connected but no
/// actual internet). Either one triggers a real reachability check before the
/// state flips, so a single flaky request doesn't blank the page.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Future<bool>? _pendingCheck;

  bool _isOffline = false;
  bool get isOffline => _isOffline;

  /// Bumped every time the app comes back online so the shell can remount the
  /// page and let it reload whatever failed while offline.
  int _reconnectCount = 0;
  int get reconnectCount => _reconnectCount;

  void start() {
    if (_subscription != null) return;
    _subscription = _connectivity.onConnectivityChanged.listen((_) => recheck());
    recheck();
  }

  /// Called by the HTTP client when a request fails before reaching the
  /// server.
  void reportNetworkFailure() => recheck();

  /// Re-evaluates connectivity and returns whether the app is online.
  /// Concurrent callers share the same check.
  Future<bool> recheck() {
    return _pendingCheck ??= _check().whenComplete(() => _pendingCheck = null);
  }

  Future<bool> _check() async {
    final online = await _hasInternet();
    if (online == _isOffline) {
      _isOffline = !online;
      if (online) _reconnectCount++;
      notifyListeners();
    }
    return online;
  }

  Future<bool> _hasInternet() async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (results.every((r) => r == ConnectivityResult.none)) return false;
      // The browser already answers this from navigator.onLine, and dart:io
      // lookups aren't available there.
      if (kIsWeb) return true;
      final lookup = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      return lookup.isNotEmpty && lookup.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
