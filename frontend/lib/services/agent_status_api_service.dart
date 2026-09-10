import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

import 'auth_api_service.dart' show ApiException;
import 'auth_api_service.dart' show AuthApiService;
import '../models/agent_portfolio_model.dart';

/// Talks to `backend/agents.php` — the agent-portfolio endpoint.
///
/// Both routes on the PHP side are admin-only (`Controller::requireAdmin()`),
/// so every call here carries the signed-in admin's bearer token.
class AgentStatusApiService {
  AgentStatusApiService._();
  static final AgentStatusApiService instance = AgentStatusApiService._();

  String get _baseUrl => '${ApiConfig.normalizedBaseUrl}/agents.php';

  Future<Map<String, String>> _headers() async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final token = await AuthApiService.instance.getToken();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// GET /backend/agents.php?action=portfolio&agent_id=<id>[&date=YYYY-MM-DD]
  ///
  /// [onDate] is optional — omit it to get "today" as the server sees it.
  /// Pass an ISO date (YYYY-MM-DD) to view the book as of another day.
  Future<AgentPortfolioResponse> getAgentPortfolio(
    String agentId, {
    String? onDate,
  }) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'action': 'portfolio',
      'agent_id': agentId,
      if (onDate != null && onDate.isNotEmpty) 'date': onDate,
    });

    final http.Response res;
    try {
      res = await http.get(uri, headers: await _headers());
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection.', 0);
    }

    final body = _decode(res);
    return AgentPortfolioResponse.fromJson(body);
  }

  /// POST /backend/agents.php?action=attach_loan
  /// { loan_id, customer_id } → { loan, collections_relinked }
  ///
  /// Reattaches a loan (and any receipts cut loose with it) to a customer.
  /// Used from the "unlinked loans" repair flow.
  Future<Map<String, dynamic>> attachLoan({
    required String loanId,
    required String customerId,
  }) async {
    final uri = Uri.parse(_baseUrl)
        .replace(queryParameters: {'action': 'attach_loan'});

    final http.Response res;
    try {
      res = await http.post(
        uri,
        headers: await _headers(),
        body: jsonEncode({'loan_id': loanId, 'customer_id': customerId}),
      );
    } catch (_) {
      throw ApiException(
          'Could not reach the server. Check your connection.', 0);
    }

    return _decode(res);
  }

  // ---------------------------------------------------------------------
  // shared response handling
  // ---------------------------------------------------------------------

  /// The PHP side answers errors via `json_error($message, $httpCode)`,
  /// which encodes as `{"error": "..."}`.
  Map<String, dynamic> _decode(http.Response res) {
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(res.body);
      body = decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    } catch (_) {
      throw ApiException(
        'Unexpected response from server (HTTP ${res.statusCode}).',
        res.statusCode,
      );
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final message = (body['error'] ?? body['message'] ?? 'Request failed')
          .toString();
      throw ApiException(message, res.statusCode);
    }

    return body;
  }
}
