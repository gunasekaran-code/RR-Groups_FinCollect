import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_api_service.dart'; // adjust import path to wherever this actually lives
import '../config/api_config.dart';
import 'method_override_http.dart';

/// Counts shown in the "Collection Status" sheet for a single agent.
class AgentCollectionSummary {
  final int todayCount;
  final int pendingCount;
  final int collectedCount;
  final int overdueCount;

  const AgentCollectionSummary({
    required this.todayCount,
    required this.pendingCount,
    required this.collectedCount,
    required this.overdueCount,
  });

  factory AgentCollectionSummary.empty() => const AgentCollectionSummary(
        todayCount: 0,
        pendingCount: 0,
        collectedCount: 0,
        overdueCount: 0,
      );

  /// Parses a summary endpoint response shaped like:
  /// `{ "today": 4, "pending": 12, "collected": 30, "overdue": 3 }`
  /// (falls back to `today_count` / `pending_count` / etc. too, in case
  /// your backend uses the longer field names).
  factory AgentCollectionSummary.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    return AgentCollectionSummary(
      todayCount: asInt(json['today'] ?? json['today_count']),
      pendingCount: asInt(json['pending'] ?? json['pending_count']),
      collectedCount: asInt(json['collected'] ?? json['collected_count']),
      overdueCount: asInt(json['overdue'] ?? json['overdue_count']),
    );
  }
}

/// CRUD client for the generic `ResourceController`-backed agent/profile
/// endpoint. Mirrors AuthApiService's error handling so both services throw
/// the same ApiException type.
class AgentApiService {
  AgentApiService._();
  static final AgentApiService instance = AgentApiService._();

  static String get _baseUrl => ApiConfig.normalizedBaseUrl;
  static String get _restEndpoint => '$_baseUrl/rest.php';
  static String get _userEndpoint => '$_baseUrl/users.php';

  /// Generic `rest.php?table=...` URI builder, reused by both the profiles
  /// endpoints and the collections lookup below.
  Uri _restUri(String table, [Map<String, String>? query]) {
    return Uri.parse(_restEndpoint).replace(
      queryParameters: {'table': table, ...?query},
    );
  }

  Uri _profilesUri([Map<String, String>? query]) => _restUri('profiles', query);

  Future<Map<String, String>> _headers() async {
    final token = await AuthApiService.instance.getToken();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// GET all profiles. We deliberately don't push role/status filters into
  /// the query string (unknown QueryParser syntax on your end) — filtering
  /// happens client-side in AgentManagementScreen, same as before.
  Future<List<Map<String, dynamic>>> getAgents() async {
    late http.Response res;
    try {
      res = await http
          .get(_profilesUri(), headers: await _headers())
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection and try again.',
          0);
    }
    final decoded = _decode(res);
    if (decoded is! List) {
      throw ApiException('Unexpected server response.', res.statusCode);
    }
    return decoded.cast<Map<String, dynamic>>();
  }

  /// POST a new user account via the admin-only users endpoint.
  /// This route hashes `password` using bcrypt and also accepts
  /// `avatar_url`, `customer_id`, and other profile fields.
  Future<Map<String, dynamic>> createAgent(Map<String, dynamic> data) async {
    late http.Response res;
    try {
      res = await http
          .post(Uri.parse(_userEndpoint),
              headers: await _headers(), body: jsonEncode(data))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection and try again.',
          0);
    }
    final decoded = _decode(res);
    if (decoded is Map<String, dynamic>) return decoded;
    throw ApiException('Unexpected server response.', res.statusCode);
  }

  /// PATCH an existing profile row, filtered by id via query string.
  /// ASSUMPTION #2: QueryParser reads the filter from `?id=...` — adjust
  /// if your backend expects a different param name.
  Future<Map<String, dynamic>> updateAgent(
      String id, Map<String, dynamic> data) async {
    late http.Response res;
    try {
      res = await postWithMethodOverride(
        Uri.parse(_userEndpoint).replace(queryParameters: {'id': id}),
        method: 'PATCH',
        headers: await _headers(),
        body: jsonEncode(data),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection and try again.',
          0);
    }
    final decoded = _decode(res);
    if (decoded is Map<String, dynamic>) return decoded;
    throw ApiException('Unexpected server response.', res.statusCode);
  }

  Future<void> deleteAgent(String id) async {
    late http.Response res;
    try {
      res = await postWithMethodOverride(
        _profilesUri({'id': id}),
        method: 'DELETE',
        headers: await _headers(),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection and try again.',
          0);
    }
    _decode(res); // throws on non-2xx
  }

  /// GET the 4 collection counts (today / pending / collected / overdue)
  /// for a single agent using the existing generic collections API.
  ///
  /// The deployed backend does not expose a standalone `collections.php` summary
  /// route, so the Flutter app must read the raw `collections` table rows and
  /// compute the summary client-side. This keeps the behavior the same without
  /// requiring a PHP endpoint change.
  Future<AgentCollectionSummary> getAgentCollectionSummary(
      String agentId) async {
    final rows = await getAgentCollectionsRaw(agentId);
    return summaryFromRawList(rows);
  }

  /// Fallback: raw collections list for an agent, filtered server-side via
  /// `?table=collections&agent_id=...`. Pair with [summaryFromRawList] if
  /// there's no dedicated summary endpoint yet.
  Future<List<dynamic>> getAgentCollectionsRaw(String agentId) async {
    late http.Response res;
    try {
      res = await http
          .get(
            _restUri('collections', {'agent_id': 'eq.$agentId'}),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection and try again.',
          0);
    }
    final decoded = _decode(res);
    if (decoded is List) return decoded;
    if (decoded is Map<String, dynamic> && decoded['data'] is List) {
      return decoded['data'] as List;
    }
    throw ApiException('Unexpected server response.', res.statusCode);
  }

  /// Computes today/pending/collected/overdue counts from a raw list of
  /// collection records. Adjust the field names (`status`, `due_date`) to
  /// match your actual `collections` table schema.
  AgentCollectionSummary summaryFromRawList(List<dynamic> records) {
    final today = DateTime.now();
    bool isToday(DateTime d) =>
        d.year == today.year && d.month == today.month && d.day == today.day;

    var todayCount = 0, pending = 0, collected = 0, overdue = 0;

    for (final r in records) {
      if (r is! Map) continue;
      final status = (r['status'] ?? '').toString().toLowerCase();
      final dueRaw = r['due_date'] ?? r['collection_date'];
      DateTime? due;
      if (dueRaw != null) {
        try {
          due = DateTime.parse(dueRaw.toString());
        } catch (_) {
          due = null;
        }
      }

      if (due != null && isToday(due)) todayCount++;

      switch (status) {
        case 'collected':
        case 'paid':
          collected++;
          break;
        case 'overdue':
          overdue++;
          break;
        case 'pending':
        default:
          pending++;
          break;
      }
    }

    return AgentCollectionSummary(
      todayCount: todayCount,
      pendingCount: pending,
      collectedCount: collected,
      overdueCount: overdue,
    );
  }

  dynamic _decode(http.Response res) {
    dynamic data;
    try {
      data = jsonDecode(res.body);
    } catch (_) {
      throw ApiException('Unexpected server response.', res.statusCode);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = (data is Map && (data['error'] ?? data['message']) != null)
          ? (data['error'] ?? data['message']).toString()
          : 'Something went wrong';
      throw ApiException(msg, res.statusCode);
    }
    return data;
  }
}