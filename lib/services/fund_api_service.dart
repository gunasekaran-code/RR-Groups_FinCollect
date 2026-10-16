import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/fund.dart';
import 'method_override_http.dart';
import 'session_service.dart';

class FundApiService {
  static String get _restEndpoint => '${ApiConfig.normalizedBaseUrl}/rest.php';

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (SessionService.instance.token != null &&
            SessionService.instance.token!.isNotEmpty)
          'Authorization': 'Bearer ${SessionService.instance.token}',
      };

  static Uri _uri(String resource, [Map<String, String>? query]) {
    return Uri.parse(_restEndpoint).replace(
      queryParameters: {'table': resource, ...?query},
    );
  }

  static Uri _action(String action, [Map<String, String>? query]) {
    return Uri.parse('${ApiConfig.normalizedBaseUrl}/funds.php').replace(
      queryParameters: {'action': action, ...?query},
    );
  }

  static bool _actionIsUnavailable(http.Response res) =>
      res.statusCode == 404 || res.statusCode == 405;

  static Never _throwFromAction(http.Response res, String action) {
    if (_actionIsUnavailable(res)) {
      throw Exception('The server does not support funds.php?action=$action '
          '(HTTP ${res.statusCode}). Deploy the fund payout backend before '
          'recording payouts.');
    }
    _throwFromResponse(res);
  }

  static Never _throwFromResponse(http.Response res) {
    String message = 'Request failed (${res.statusCode})';
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] != null) {
        message = body['error'].toString();
      }
    } catch (_) {}
    throw Exception(message);
  }

  static Map<String, dynamic> _normalizeRow(dynamic data) {
    if (data is List && data.isNotEmpty) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    if (data is Map<String, dynamic>) {
      if (data['data'] is List && (data['data'] as List).isNotEmpty) {
        return Map<String, dynamic>.from((data['data'] as List).first as Map);
      }
      if (data['data'] is Map<String, dynamic>) {
        return Map<String, dynamic>.from(data['data'] as Map<String, dynamic>);
      }
      return data;
    }
    throw Exception('Unexpected response format');
  }

  static Future<FundsSummary> fetchSummary() async {
    final res = await http.get(_uri('funds'), headers: _headers);
    if (res.statusCode != 200) _throwFromResponse(res);

    final data = jsonDecode(res.body);
    if (data is List) {
      final rows = data.cast<Map<String, dynamic>>();
      final activeFunds = rows.where((row) {
        return (row['status']?.toString() ?? '').toLowerCase() == 'active';
      }).length;
      return FundsSummary(
        totalFunds: rows.length,
        activeFunds: activeFunds,
        maturityPayoutTotal: rows.fold<double>(0, (sum, row) {
          // What the schemes pay at term — deposits + bonus. Not `payoutAmount`,
          // which is what is payable today and is 0 on a fund still collecting.
          return sum + Fund.fromJson(row).maturityPayout;
        }),
        collectedTotal: rows.fold<double>(0, (sum, row) {
          return sum + Fund.fromJson(row).depositedAmount;
        }),
      );
    }

    return FundsSummary.fromJson(data as Map<String, dynamic>);
  }

  /// The server's current payout figures, keyed by fund id. Older deployments
  /// keep the Fund list usable by returning no previews rather than failing it.
  static Future<Map<String, FundPayoutPreview>> fetchPreviews() async {
    final res = await http.get(_action('previews'), headers: _headers);
    if (_actionIsUnavailable(res)) return const {};
    if (res.statusCode != 200) _throwFromAction(res, 'previews');

    final data = jsonDecode(res.body);
    final rows = (data is Map && data['previews'] is Map)
        ? Map<String, dynamic>.from(data['previews'] as Map)
        : <String, dynamic>{};
    return rows.map((fundId, row) => MapEntry(fundId,
        FundPayoutPreview.fromJson(Map<String, dynamic>.from(row as Map))));
  }

  /// One fund, its payout history, and its server-calculated payout figure.
  static Future<FundSheet> fetchSheet(String fundId) async {
    final res = await http.get(
      _action('sheet', {'fund_id': fundId}),
      headers: _headers,
    );
    if (_actionIsUnavailable(res)) return _fetchLegacySheet(fundId);
    if (res.statusCode != 200) _throwFromAction(res, 'sheet');
    return FundSheet.fromJson(
        Map<String, dynamic>.from(jsonDecode(res.body) as Map));
  }

  /// Read a single row through the deployed API.
  static Future<FundSheet> _fetchLegacySheet(String fundId) async {
    final res = await http.get(
      _uri('funds', {'id': 'eq.$fundId'}),
      headers: _headers,
    );
    if (res.statusCode != 200) _throwFromResponse(res);
    return FundSheet(
      fund: Fund.fromJson(_normalizeRow(jsonDecode(res.body))),
      payouts: const [],
      preview: null,
    );
  }

  /// Funds belonging to one customer account.  Customer screens must use this
  /// instead of [fetchAll], so they never first download another customer's
  /// funds and filter them on the device.
  ///
  /// The bearer token still lets the backend enforce the same ownership rule;
  /// this query is deliberately a least-data request, not a security boundary.
  static Future<List<Fund>> fetchForCustomer(String customerId) {
    final id = customerId.trim();
    if (id.isEmpty) return Future.value(const []);
    return _fetchFunds(
      query: {'customer_id': 'eq.$id'},
      includePreviews: false,
    );
  }

  static Future<List<Fund>> fetchAll() => _fetchFunds();

  static Future<List<Fund>> _fetchFunds({
    Map<String, String>? query,
    bool includePreviews = true,
  }) async {
    final fundsFuture = http.get(_uri('funds', query), headers: _headers);
    // The preview endpoint is portfolio-wide on older deployments. Do not ask
    // for it in the customer portal, where the plain scoped fund rows already
    // contain everything needed for the read-only card.
    final previewsFuture = includePreviews
        ? http.get(_action('previews'), headers: _headers)
        : Future.value(null);
    final fundsRes = await fundsFuture;
    final previewsRes = await previewsFuture;
    if (fundsRes.statusCode != 200) _throwFromResponse(fundsRes);
    if (previewsRes != null &&
        previewsRes.statusCode != 200 &&
        !_actionIsUnavailable(previewsRes)) {
      _throwFromAction(previewsRes, 'previews');
    }

    final fundsData = jsonDecode(fundsRes.body);
    final fundRows = (fundsData is Map && fundsData['data'] is List)
        ? fundsData['data'] as List
        : (fundsData is List ? fundsData : const []);
    dynamic previewData = <String, dynamic>{};
    if (previewsRes?.statusCode == 200) {
      previewData = jsonDecode(previewsRes!.body);
    }
    final previews = (previewData is Map && previewData['previews'] is Map)
        ? Map<String, dynamic>.from(previewData['previews'] as Map)
        : <String, dynamic>{};

    return fundRows.map((row) {
      final fundRow = Map<String, dynamic>.from(row as Map);
      final preview = previews[fundRow['id']?.toString()];
      if (preview is Map) fundRow['payout_preview'] = preview;
      return Fund.fromJson(fundRow);
    }).toList();
  }

  static Future<Fund> create(Fund fund) async {
    final res = await http.post(
      _uri('funds'),
      headers: _headers,
      body: jsonEncode(fund.toCreateJson()),
    );
    if (res.statusCode != 200 && res.statusCode != 201) _throwFromResponse(res);
    final data = jsonDecode(res.body);
    final row = _normalizeRow(data);
    return Fund.fromJson(row);
  }

  static Future<Fund> update(String id, Fund fund) async {
    final res = await postWithMethodOverride(
      _uri('funds', {'id': id}),
      method: 'PATCH',
      headers: _headers,
      body: jsonEncode(fund.toCreateJson()),
    );
    if (res.statusCode != 200) _throwFromResponse(res);
    final data = jsonDecode(res.body);
    final row = _normalizeRow(data);
    return Fund.fromJson(row);
  }

  static Future<void> delete(String id) async {
    final res = await postWithMethodOverride(
      _uri('funds', {'id': id}),
      method: 'DELETE',
      headers: _headers,
    );
    if (res.statusCode != 200 && res.statusCode != 204) _throwFromResponse(res);
  }

  /// Record a deposit through `funds.php?action=collect`.
  ///
  /// The server writes the passbook row and re-derives the fund's running
  /// total and status in one transaction, and stamps `agent_id`/`agent_name`
  /// from the auth token. The Cash Handover screen reads `fund_payments`
  /// filtered by `agent_id`, so a row written without it — which the old
  /// PATCH + raw `fund_payments` POST did — never showed up in the agent's
  /// handover. [collectedAmount] and [status] are only used by the legacy
  /// fallback for servers that predate the collect action.
  static Future<Fund> recordCollection(
    String id, {
    required double collectedAmount,
    required String status,
    double? paymentAmount,
    String? paymentMethod,
    DateTime? paymentDate,
    String? fundCode,
    String? customerId,
    String? customerName,
    String? notes,
  }) async {
    final amount = paymentAmount ?? 0;
    final dateStr =
        (paymentDate ?? DateTime.now()).toIso8601String().substring(0, 10);
    final method = _paymentMethod(paymentMethod ?? 'Cash');

    final res = await http.post(
      _action('collect'),
      headers: _headers,
      body: jsonEncode({
        'fund_id': id,
        'amount': amount,
        'payment_method': method,
        'payment_date': dateStr,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }),
    );
    if (res.statusCode == 200) {
      return _sheetFromActionResponse(jsonDecode(res.body)).fund;
    }
    if (!_collectIsUnavailable(res)) _throwFromResponse(res);

    return _legacyRecordCollection(
      id,
      collectedAmount: collectedAmount,
      status: status,
      amount: amount,
      paymentMethod: method,
      dateStr: dateStr,
      fundCode: fundCode,
      customerId: customerId,
      customerName: customerName,
      notes: notes,
    );
  }

  /// A 404/405 from funds.php means the collect action is missing, unless the
  /// body is the service's own error (e.g. "That fund no longer exists."),
  /// which must be shown rather than retried through the legacy path.
  static bool _collectIsUnavailable(http.Response res) {
    if (!_actionIsUnavailable(res)) return false;
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] != null) {
        final error = body['error'].toString();
        return res.statusCode == 405 || error.startsWith('Unknown fund action');
      }
    } catch (_) {}
    return true;
  }

  /// Pre-collect-action path: passbook row first (it is what Cash In Hand and
  /// the handover sum), then the fund's running total. The row carries the
  /// collecting user's `agent_id` so the handover can attribute it.
  static Future<Fund> _legacyRecordCollection(
    String id, {
    required double collectedAmount,
    required String status,
    required double amount,
    required String paymentMethod,
    required String dateStr,
    String? fundCode,
    String? customerId,
    String? customerName,
    String? notes,
  }) async {
    if (amount > 0) {
      final user = SessionService.instance.currentUser;
      final agentId = user?.userId.trim() ?? '';
      final paymentRes = await http.post(
        _uri('fund_payments'),
        headers: _headers,
        body: jsonEncode({
          'fund_id': id,
          'fund_number': fundCode ?? '',
          'customer_id': customerId ?? '',
          'customer_name': customerName ?? '',
          'amount': amount,
          'balance_after': collectedAmount,
          'payment_method': paymentMethod,
          'payment_date': dateStr,
          if (agentId.isNotEmpty) 'agent_id': agentId,
          'agent_name': user?.name ?? 'Admin',
          if (notes != null && notes.isNotEmpty) 'notes': notes,
        }),
      );
      if (paymentRes.statusCode != 200 && paymentRes.statusCode != 201) {
        _throwFromResponse(paymentRes);
      }
    }

    final res = await postWithMethodOverride(
      _uri('funds', {'id': id}),
      method: 'PATCH',
      headers: _headers,
      body: jsonEncode({
        'collected_amount': collectedAmount,
        'status': status,
      }),
    );
    if (res.statusCode != 200) _throwFromResponse(res);
    return Fund.fromJson(_normalizeRow(jsonDecode(res.body)));
  }

  static Future<Fund> settleInFull(
    String id, {
    required String paymentMethod,
    required DateTime settlementDate,
    required double totalDeposit,
    double depositedAmount = 0,
    String? fundCode,
    String? customerId,
    String? customerName,
  }) async {
    final remaining = totalDeposit - depositedAmount;
    final res = await postWithMethodOverride(
      _uri('funds', {'id': id}),
      method: 'PATCH',
      headers: _headers,
      body: jsonEncode({
        'collected_amount': totalDeposit,
        'status': FundStatus.closed.label,
      }),
    );
    if (res.statusCode != 200) _throwFromResponse(res);
    final data = jsonDecode(res.body);
    final row = _normalizeRow(data);

    if (remaining > 0) {
      try {
        final dateStr = settlementDate.toIso8601String().substring(0, 10);
        await http.post(
          _uri('fund_payments'),
          headers: _headers,
          body: jsonEncode({
            'fund_id': id,
            'fund_number': fundCode ?? '',
            'customer_id': customerId ?? '',
            'customer_name': customerName ?? '',
            'amount': remaining,
            'balance_after': totalDeposit,
            'payment_method': paymentMethod.toLowerCase(),
            'payment_date': dateStr,
            'agent_name': SessionService.instance.currentUser?.name ?? 'Admin',
            'notes': 'Settled in full',
          }),
        );
      } catch (_) {}
    }

    return Fund.fromJson(row);
  }

  /// Close a fund through the backend transaction. That transaction records
  /// the cash-out ledger row and the payout row together.
  static Future<FundSheet> closeFund(
    String id, {
    double? units,
    required String paymentMethod,
    required DateTime payoutDate,
    String? notes,
  }) async {
    final res = await http.post(
      _action('close'),
      headers: _headers,
      body: jsonEncode({
        'fund_id': id,
        if (units != null) 'units': units,
        'payment_method': _paymentMethod(paymentMethod),
        'payout_date': payoutDate.toIso8601String().substring(0, 10),
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }),
    );
    if (res.statusCode != 200) _throwFromAction(res, 'close');
    return _sheetFromActionResponse(jsonDecode(res.body));
  }

  static String _paymentMethod(String value) {
    final normalized = value.toLowerCase().replaceAll(' ', '_');
    return normalized == 'bank_transfer' ? 'bank' : normalized;
  }

  /// Pay out a matured fund. FundService writes the `fund_payouts` record and
  /// its linked Account Book `cash_out` row in the same database transaction.
  static Future<FundSheet> payout(
    String id, {
    required String paymentMethod,
    required DateTime payoutDate,
    String? notes,
  }) async {
    final res = await http.post(
      _action('payout'),
      headers: _headers,
      body: jsonEncode({
        'fund_id': id,
        'payment_method': _paymentMethod(paymentMethod),
        'payout_date': payoutDate.toIso8601String().substring(0, 10),
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }),
    );
    if (res.statusCode != 200) _throwFromAction(res, 'payout');
    return _sheetFromActionResponse(jsonDecode(res.body));
  }

  static FundSheet _sheetFromActionResponse(dynamic data) {
    if (data is Map && data['fund'] is Map) {
      return FundSheet.fromJson(Map<String, dynamic>.from(data));
    }
    return FundSheet(
      fund: Fund.fromJson(_normalizeRow(data)),
      payouts: const [],
      preview: null,
    );
  }

  static Future<List<FundEntry>> fetchPassbook(String fundId) async {
    final res = await http.get(
      _uri('fund_payments', {'fund_id': fundId}),
      headers: _headers,
    );
    if (res.statusCode != 200) _throwFromResponse(res);
    final data = jsonDecode(res.body);
    final list = (data is Map && data['data'] is List)
        ? data['data'] as List
        : (data is List ? data : const []);

    return list
        .map((e) => FundEntry.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.week.compareTo(b.week));
  }
}
