import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fincollect/services/session_http_client.dart';
import 'package:fincollect/services/session_service.dart';

/// Returns a canned response for whatever it is sent.
class _StubClient extends http.BaseClient {
  _StubClient(this.statusCode, this.body);

  final int statusCode;
  final String body;
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream.value(bytes),
      statusCode,
      contentLength: bytes.length,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Future<http.Response> _get(_StubClient stub) {
  return SessionAwareHttpClient(stub).get(Uri.parse('https://example.test/x'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int expiredCallbacks;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    // flutter_secure_storage has no in-memory fake; back it with a map.
    final store = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        switch (call.method) {
          case 'read':
            return store[call.arguments['key'] as String];
          case 'write':
            store[call.arguments['key'] as String] =
                call.arguments['value'] as String;
            return null;
          case 'delete':
            store.remove(call.arguments['key'] as String);
            return null;
          case 'readAll':
            return Map<String, String>.from(store);
          default:
            return null;
        }
      },
    );
  });

  setUp(() {
    expiredCallbacks = 0;
    final session = SessionService.instance;
    session.logout();
    session.onSessionExpired = () async => expiredCallbacks++;
  });

  test('a rejected token expires the session and hides the 401', () async {
    final session = SessionService.instance;
    session.token = 'stale-token';

    final stub = _StubClient(401, '{"error":"Invalid or expired token"}');

    await expectLater(_get(stub), throwsA(isA<SessionExpiredException>()));
    expect(expiredCallbacks, 1, reason: 'should route back to login');
    expect(session.token, isNull, reason: 'stored token should be dropped');
    expect(session.isLoggedIn, isFalse);
    expect(session.sessionExpired, isTrue, reason: 'error toasts stay quiet');
  });

  test('a missing token is treated the same way', () async {
    SessionService.instance.token = 'stale-token';
    final stub = _StubClient(401, '{"error":"Missing authorization token"}');

    await expectLater(_get(stub), throwsA(isA<SessionExpiredException>()));
    expect(expiredCallbacks, 1);
  });

  test('a failed sign-in still reaches the caller as a normal 401', () async {
    final stub = _StubClient(401, '{"error":"Invalid credentials"}');

    final response = await _get(stub);
    expect(response.statusCode, 401);
    expect(jsonDecode(response.body), {'error': 'Invalid credentials'});
    expect(expiredCallbacks, 0, reason: 'the login screen shows this itself');
  });

  test('a non-401 body is passed through untouched', () async {
    final stub = _StubClient(200, '{"data":[1,2,3]}');

    final response = await _get(stub);
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {
      'data': [1, 2, 3]
    });
  });

  test('concurrent rejections expire the session only once', () async {
    SessionService.instance.token = 'stale-token';
    final stub = _StubClient(401, '{"error":"Invalid or expired token"}');

    final results = await Future.wait(
      List.generate(3, (_) => _get(stub).then<Object?>((r) => r, onError: (e) => e)),
    );

    expect(results, everyElement(isA<SessionExpiredException>()));
    expect(stub.sendCount, 3);
    expect(expiredCallbacks, 1);
  });
}
