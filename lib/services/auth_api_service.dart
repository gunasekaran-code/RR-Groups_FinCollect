import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import 'session_service.dart';
import 'session_http_client.dart';

/// Thrown for any non-2xx response. `message` is the human-readable
/// error your PHP `json_error()` sends back.
class ApiException implements Exception {
  final String message;
  final int statusCode;
  ApiException(this.message, this.statusCode);
  @override
  String toString() => message;
}

class AuthApiService {
  AuthApiService._();
  static final AuthApiService instance = AuthApiService._();

  static String get baseUrl => ApiConfig.normalizedBaseUrl;
  static final String authEndpoint = '$baseUrl/auth.php';

  static const _tokenKey = 'auth_token';
  static const _profileKey = 'auth_profile';
  static const _secureStorage = FlutterSecureStorage();

  Future<Map<String, dynamic>> _post(
      String action, Map<String, dynamic> body) async {
    late http.Response res;
    final token = await getToken();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    try {
      res = await http
          .post(
            Uri.parse('$authEndpoint?action=$action'),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
    } on SessionExpiredException {
      rethrow;
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection and try again.',
          0);
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('Unexpected server response.', res.statusCode);
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      await SessionService.instance.handleUnauthorized(res);
      throw ApiException(
          (data['error'] ?? data['message'] ?? 'Something went wrong')
              .toString(),
          res.statusCode);
    }
    return data;
  }

  // ---- login -----------------------------------------------------------

  /// Returns the decoded response: { token, user, profile }
Future<Map<String, dynamic>> login(
    {required String identifier, required String password}) async {
  final data =
      await _post('login', {'identifier': identifier, 'password': password});
  final token = data['token'] as String?;
  if (token != null) {
    await _saveSession(token, data['profile'] as Map<String, dynamic>?);
  }
  return data;
}

  // ---- forgot password (2-step OTP flow) --------------------------------

  /// Step 1: verify email + mobile, triggers OTP send.
  /// Returns e.g. { ok, channels, sent_to, email_masked, demo_otp? }
  Future<Map<String, dynamic>> requestOtp(
      {required String email, required String mobile}) {
    return _post('request_otp', {'email': email, 'mobile': mobile});
  }

  /// Step 2: verify OTP + set new password.
  Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String mobile,
    required String otp,
    required String newPassword,
  }) {
    return _post('reset_password', {
      'email': email,
      'mobile': mobile,
      'otp': otp,
      'new_password': newPassword,
    });
  }

  // ---- session helpers ---------------------------------------------------

  Future<void> _saveSession(String token, Map<String, dynamic>? profile) async {
    await _secureStorage.write(key: _tokenKey, value: token);
    if (profile != null) {
      await _secureStorage.write(key: _profileKey, value: jsonEncode(profile));
    }
  }

  Future<String?> getToken() async {
    final token = await _secureStorage.read(key: _tokenKey);
    if (token != null && token.isNotEmpty) return token;

    // Migrate tokens saved by versions that used SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    final legacyToken = prefs.getString(_tokenKey);
    if (legacyToken == null || legacyToken.isEmpty) return null;
    await _secureStorage.write(key: _tokenKey, value: legacyToken);
    await prefs.remove(_tokenKey);
    return legacyToken;
  }

  Future<Map<String, dynamic>?> getStoredProfile() async {
    final raw = await _secureStorage.read(key: _profileKey);
    if (raw != null && raw.isNotEmpty) {
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    // Migrate profiles saved by versions that used SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    final legacyProfile = prefs.getString(_profileKey);
    if (legacyProfile == null || legacyProfile.isEmpty) return null;
    await _secureStorage.write(key: _profileKey, value: legacyProfile);
    await prefs.remove(_profileKey);
    return jsonDecode(legacyProfile) as Map<String, dynamic>;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.delete(key: _tokenKey);
    await _secureStorage.delete(key: _profileKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileKey);
  }

  Future<bool> isLoggedIn() async => (await getToken()) != null;

  Future<Map<String, dynamic>> updateProfile({
    required String fullName,
    required String mobile,
    String? occupation,
    String? aadhaar,
    String? pan,
    String? address,
    String? avatarBase64, // NEW: data URI, e.g. "data:image/jpeg;base64,...."
  }) async {
    final token = await getToken();
    if (token == null) {
      throw ApiException('Not logged in.', 401);
    }

    final data = await _post('update_profile', {
      'full_name': fullName,
      'mobile': mobile,
      'occupation': occupation,
      'aadhaar': aadhaar,
      'pan': pan,
      'address': address,
      if (avatarBase64 != null) 'avatar_url': avatarBase64, // NEW
    });

    final updatedProfile = data['profile'] as Map<String, dynamic>?;
    if (updatedProfile != null) {
      await _secureStorage.write(
          key: _profileKey, value: jsonEncode(updatedProfile));
      return updatedProfile;
    }

    final current = await getStoredProfile() ?? {};
    final merged = {
      ...current,
      'full_name': fullName,
      'mobile': mobile,
      'occupation': occupation,
      'aadhaar': aadhaar,
      'pan': pan,
      'address': address,
      if (avatarBase64 != null) 'avatar_url': avatarBase64, // NEW
    };
    await _secureStorage.write(key: _profileKey, value: jsonEncode(merged));
    return merged;
  }
}
