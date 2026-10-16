import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_user.dart';
import '../models/user_role.dart';
import '../theme/locale_controller.dart';
import 'api_client.dart';

class SessionService {
  SessionService._internal();
  static final SessionService instance = SessionService._internal();

  static const String _tokenKey = 'auth_token';
  static const String _profileKey = 'auth_profile';
  static const _secureStorage = FlutterSecureStorage();

  AppUser? currentUser;
  String? token;
  bool _promoPopupAttempted = false;
  bool _handlingUnauthorized = false;
  bool _sessionExpired = false;
  Future<void> Function()? onSessionExpired;

  Future<void> restoreFromStorage() async {
    try {
      await _restoreFromStorage();
    } catch (_) {
      // Secure storage can become unreadable on Android, e.g. when a backup
      // restores the encrypted values after a reinstall but not the Keystore
      // key that decrypts them. Start logged out and wipe the unreadable
      // entries so the next login can write fresh ones, instead of failing
      // startup and leaving the app on a white screen.
      currentUser = null;
      token = null;
      ApiClient.instance.authToken = null;
      try {
        await _secureStorage.deleteAll();
      } catch (_) {}
    }
  }

  Future<void> _restoreFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    token = await _secureStorage.read(key: _tokenKey);
    if (token == null || token!.isEmpty) {
      // Migrate tokens saved by versions that used SharedPreferences.
      final legacyToken = prefs.getString(_tokenKey);
      if (legacyToken != null && legacyToken.isNotEmpty) {
        await _secureStorage.write(key: _tokenKey, value: legacyToken);
        await prefs.remove(_tokenKey);
        token = legacyToken;
      }
    }
    ApiClient.instance.authToken = token;

    var rawProfile = await _secureStorage.read(key: _profileKey);
    if (rawProfile == null || rawProfile.isEmpty) {
      // Migrate profiles saved by versions that used SharedPreferences.
      final legacyProfile = prefs.getString(_profileKey);
      if (legacyProfile != null && legacyProfile.isNotEmpty) {
        await _secureStorage.write(key: _profileKey, value: legacyProfile);
        await prefs.remove(_profileKey);
        rawProfile = legacyProfile;
      }
    }
    if (rawProfile == null || rawProfile.isEmpty) {
      currentUser = null;
      return;
    }

    try {
      final profile = jsonDecode(rawProfile) as Map<String, dynamic>;
      currentUser = AppUser(
        userId: (profile['id'] ?? '').toString(),
        customerId: profile['customer_id']?.toString(),
        name: (profile['full_name'] as String?)?.trim().isNotEmpty == true
            ? profile['full_name'] as String
            : (profile['email'] ?? 'User').toString(),
        role: _roleFromProfile(profile['role']),
        avatarUrl: profile['avatar_url']?.toString(),
      );
      // A session survived an app restart — restore this user's own saved
      // language (or English if they've never picked one) rather than
      // whatever LocaleController's in-memory default happens to be.
      await LocaleController.loadForUser(currentUser!.userId);
    } catch (_) {
      currentUser = null;
      token = null;
      ApiClient.instance.authToken = null;
    }
  }

  AppUser login(AppUser user, {String? token}) {
    currentUser = user;
    this.token = token;
    _promoPopupAttempted = false;
    _sessionExpired = false;
    ApiClient.instance.authToken = token;
    // Fire-and-forget: apply this user's saved language (English if they've
    // never set one). Not awaited so login isn't blocked on local I/O; the
    // UI updates the moment the read resolves, which is effectively instant.
    LocaleController.loadForUser(user.userId);
    return user;
  }

  void logout() {
    currentUser = null;
    token = null;
    _promoPopupAttempted = false;
    ApiClient.instance.authToken = null;
    // Don't leave the outgoing user's language active for whoever signs in
    // next on this device — reset it, then their own login() call above
    // loads their saved choice.
    LocaleController.resetToDefault();
  }

  Future<void> handleUnauthorized(http.Response response) async {
    if (response.statusCode != 401 || !_isTokenFailure(response)) return;
    await expireSession();
  }

  /// Drops the rejected session and sends the user back to the login screen.
  ///
  /// Safe to call from several in-flight requests at once: only the first one
  /// through does the work.
  Future<void> expireSession() async {
    if (!_hasActiveSession || _handlingUnauthorized) return;

    _handlingUnauthorized = true;
    try {
      logout();
      _sessionExpired = true;
      // Navigate before touching storage so no screen gets a frame to render
      // the failure that brought us here; the stale token is already out of
      // memory and off every outgoing request by this point.
      await onSessionExpired?.call();
      try {
        await _clearPersistedSession();
      } catch (_) {
        // The session is already gone from memory and the user is back on the
        // login screen; a storage wipe that fails must not undo either of
        // those, and the server rejects the leftover token anyway.
      }
    } finally {
      _handlingUnauthorized = false;
    }
  }

  /// True from the moment a token is rejected until the next sign-in.
  ///
  /// Toasts outlive the routes they were raised from, so the toast layer uses
  /// this to stay quiet about failures that are just the dead session's
  /// in-flight requests unwinding.
  bool get sessionExpired => _sessionExpired;

  bool get _hasActiveSession =>
      (token?.isNotEmpty ?? false) || currentUser != null;

  bool _isTokenFailure(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      return body is Map && isTokenFailureMessage(body['error']?.toString());
    } catch (_) {
      return false;
    }
  }

  /// Whether an error message from a 401 means the token itself was refused,
  /// as opposed to the credentials in a sign-in attempt. Matches the two
  /// messages `Controller::requireAuth()` sends.
  static bool isTokenFailureMessage(String? error) {
    final message = error?.trim().toLowerCase();
    return message == 'invalid or expired token' ||
        message == 'missing authorization token';
  }

  Future<void> _clearPersistedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.delete(key: _tokenKey);
    await _secureStorage.delete(key: _profileKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileKey);
  }

  UserRole? get role => currentUser?.role;

  bool get isLoggedIn => currentUser != null;

  bool claimPromoPopupAttempt() {
    if (_promoPopupAttempted) return false;
    _promoPopupAttempted = true;
    return true;
  }
}

UserRole _roleFromProfile(dynamic rawRole) {
  switch ((rawRole ?? '').toString().trim().toLowerCase()) {
    case 'owner':
      return UserRole.owner;
    case 'admin':
      return UserRole.admin;
    case 'agent':
      return UserRole.agent;
    case 'customer':
      return UserRole.customer;
    default:
      return UserRole.agent;
  }
}
