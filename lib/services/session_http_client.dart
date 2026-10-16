import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'connectivity_service.dart';
import 'session_service.dart';

/// Raised in place of a 401 whose body says the bearer token is gone or
/// expired.
///
/// By the time this surfaces the session has already been torn down and the
/// app is on its way back to the login screen, so callers are expected to let
/// it pass rather than turning it into an error message — there is nothing the
/// user can do about it and nothing left on screen to show it on.
class SessionExpiredException implements Exception {
  const SessionExpiredException();

  @override
  String toString() => 'Session expired';
}

/// Wraps every request the app makes so a rejected token is handled once,
/// centrally, instead of in each of the API services individually.
///
/// Installed in `main()` via `runWithClient`, which makes the top-level
/// `http.get`/`http.post`/… helpers — and `http.MultipartRequest.send()` —
/// route through this client without the services having to know about it.
class SessionAwareHttpClient extends http.BaseClient {
  SessionAwareHttpClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } on http.ClientException {
      // The request never reached the server — let the shell decide whether
      // that means the device is offline.
      ConnectivityService.instance.reportNetworkFailure();
      rethrow;
    }
    if (response.statusCode != 401) return response;

    // A rejected token and a rejected sign-in are both 401s, so the body has
    // to be read to tell them apart. Buffer it and replay a fresh stream for
    // anything that turns out not to be a token failure.
    final bytes = await response.stream.toBytes();
    if (!_isTokenFailure(bytes)) return _replay(response, bytes);

    await SessionService.instance.expireSession();
    throw const SessionExpiredException();
  }

  bool _isTokenFailure(Uint8List bytes) {
    try {
      final body = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return body is Map &&
          SessionService.isTokenFailureMessage(body['error']?.toString());
    } catch (_) {
      return false;
    }
  }

  http.StreamedResponse _replay(
    http.StreamedResponse response,
    Uint8List bytes,
  ) {
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
