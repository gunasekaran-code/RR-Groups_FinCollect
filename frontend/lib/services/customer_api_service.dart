import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/customer.dart';
import 'method_override_http.dart';
import 'session_service.dart'; 

class CustomerApiException implements Exception {
  final String message;
  final int? statusCode;
  CustomerApiException(this.message, [this.statusCode]);
  @override
  String toString() => message;
}

class AgentOption {
  final String id;
  final String fullName;
  AgentOption(this.id, this.fullName);
}

class CustomerApiService {
  CustomerApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static String get _baseUrl => ApiConfig.normalizedBaseUrl;
  static String get _customerEndpoint => '$_baseUrl/customers.php';
  static String get _restEndpoint => '$_baseUrl/rest.php';

  Map<String, String> get _headers {
    final token = SessionService.instance.token;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  dynamic _decodeBody(http.Response res) {
    if (res.body.isEmpty) return {};
    try {
      return jsonDecode(res.body);
    } catch (_) {
      throw CustomerApiException('Invalid server response', res.statusCode);
    }
  }

  Map<String, dynamic> _decodeObject(http.Response res) {
    final data = _decodeBody(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CustomerApiException(
          _messageFromPayload(data, res.statusCode), res.statusCode);
    }

    if (data is List) {
      if (data.isEmpty) return {};
      if (data.first is Map<String, dynamic>) {
        return Map<String, dynamic>.from(data.first as Map);
      }
      throw CustomerApiException('Invalid server response', res.statusCode);
    }

    if (data is Map<String, dynamic>) {
      return data;
    }

    throw CustomerApiException('Invalid server response', res.statusCode);
  }

  List<dynamic> _decodeList(http.Response res) {
    final data = _decodeBody(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CustomerApiException(
          _messageFromPayload(data, res.statusCode), res.statusCode);
    }

    if (data is List) {
      return data;
    }

    if (data is Map<String, dynamic>) {
      final nested = data['data'];
      if (nested is List) return nested;
      if (nested is Map<String, dynamic>) return [nested];
      return [data];
    }

    throw CustomerApiException('Invalid server response', res.statusCode);
  }

  String _messageFromPayload(dynamic data, int? statusCode) {
    if (data is Map<String, dynamic>) {
      return data['message']?.toString() ??
          data['error']?.toString() ??
          'Request failed (${statusCode ?? 'unknown'})';
    }
    return 'Request failed (${statusCode ?? 'unknown'})';
  }

  Future<List<Customer>> fetchAll() async {
    final res = await _client.get(
      Uri.parse('$_restEndpoint?table=customers'),
      headers: _headers,
    );
    final list = _decodeList(res);
    return list
        .map((e) => Customer.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// One customer with every column, including the KYC images that the
  /// list endpoint deliberately leaves out, plus the login email, which
  /// lives on the linked `profiles` row rather than on `customers`.
  ///
  /// The columns are named one by one on purpose: rest.php treats
  /// `select=*` the same as no select at all and still strips the heavy
  /// image columns. Only naming them explicitly brings them back.
  static const _fullColumns = [
    'id', 'customer_id', 'full_name', 'mobile', 'alt_mobiles', 'address', 'aadhaar', 'pan',
    'occupation', 'photo_url', 'aadhaar_front_url', 'aadhaar_back_url',
    'pan_url', 'signature_url', 'latitude', 'longitude', 'loan_status',
    'assigned_agent', 'created_at',
  ];

  Future<Customer> fetchById(String id) async {
    final res = await _client.get(
      Uri.parse('$_restEndpoint?table=customers&id=eq.$id'
          '&select=${_fullColumns.join(',')}'),
      headers: _headers,
    );
    final data = _decodeObject(res);
    if (data.isEmpty) {
      throw CustomerApiException('Customer not found', 404);
    }

    // The email is a nicety for the edit form; a failure here must not
    // stop the customer's own details from loading.
    try {
      final loginRes = await _client.get(
        Uri.parse(
            '$_restEndpoint?table=profiles&role=eq.customer&customer_id=eq.$id&select=id,email'),
        headers: _headers,
      );
      final logins = _decodeList(loginRes);
      if (logins.isNotEmpty && logins.first is Map) {
        final email = (logins.first as Map)['email']?.toString();
        if (email != null && email.isNotEmpty) data['email'] = email;
      }
    } catch (_) {}

    return Customer.fromJson(data);
  }

  /// A customer's profile photo as raw bytes, served by photo.php. Null when
  /// none has been taken (the endpoint answers 204) or it cannot be read.
  Future<Uint8List?> fetchPhotoBytes(String id,
      {String column = 'photo_url'}) async {
    final res = await _client.get(
      Uri.parse(
          '$_baseUrl/photo.php?table=customers&id=${Uri.encodeQueryComponent(id)}&col=$column'),
      headers: {
        'Accept': 'image/*',
        if (_headers['Authorization'] != null)
          'Authorization': _headers['Authorization']!,
      },
    );
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
    return res.bodyBytes;
  }

  Future<Customer> create(Customer customer,
      {String? email, String? password}) async {
    final res = await _client.post(
      Uri.parse(_customerEndpoint),
      headers: _headers,
      body:
          jsonEncode(customer.toRequestBody(email: email, password: password)),
    );
    var data = _decodeObject(res);

    // customers.php only inserts a fixed column whitelist that excludes the
    // KYC document photos, so a brand-new customer's Aadhaar/PAN/signature
    // never lands in the row above. Patch them in separately through the
    // generic REST endpoint, which writes any real column on the table.
    if (customer.hasDocumentFields) {
      final newId = data['id']?.toString();
      if (newId != null && newId.isNotEmpty) {
        data = await _patchDocumentFields(newId, customer);
      }
    }
    return Customer.fromJson(data);
  }

  Future<Customer> update(
    String id,
    Customer customer, {
    String? email,
    String? password,
  }) async {
    final body = jsonEncode(
      customer.toRequestBody(email: email, password: password),
    );
    // A login change (email/password) has to go through customers.php, but
    // that endpoint's column whitelist drops the KYC document photos just
    // like create() does — so those still need the REST follow-up below.
    final wantsLogin = email != null || password != null;
    final endpoint = wantsLogin
        ? Uri.parse('$_customerEndpoint?id=$id')
        : Uri.parse('$_restEndpoint?table=customers&id=eq.$id');
    final res = await postWithMethodOverride(
      endpoint,
      method: 'PATCH',
      headers: _headers,
      body: body,
    );
    var data = _decodeObject(res);

    if (wantsLogin && customer.hasDocumentFields) {
      data = await _patchDocumentFields(id, customer);
    }
    return Customer.fromJson(data);
  }

  /// Writes just the document/photo columns for [id] through the generic
  /// REST endpoint, which (unlike customers.php) accepts any real column on
  /// the `customers` table. Returns the updated row.
  Future<Map<String, dynamic>> _patchDocumentFields(
      String id, Customer customer) async {
    final res = await postWithMethodOverride(
      Uri.parse('$_restEndpoint?table=customers&id=eq.$id'),
      method: 'PATCH',
      headers: _headers,
      body: jsonEncode(customer.documentFields()),
    );
    return _decodeObject(res);
  }

  /// Replaces a single document/photo column (`photo_url`,
  /// `aadhaar_front_url`, `aadhaar_back_url`, `pan_url`, `signature_url`)
  /// on [id]. rest.php lets admins write any column and agents exactly these
  /// KYC columns, so this works for both roles.
  Future<void> updateDocument(String id, String column, String dataUri) async {
    final res = await postWithMethodOverride(
      Uri.parse('$_restEndpoint?table=customers&id=eq.$id'),
      method: 'PATCH',
      headers: _headers,
      body: jsonEncode({column: dataUri}),
    );
    // An empty result means no row matched — the customer is gone or out of
    // this user's scope — so nothing was saved.
    if (_decodeObject(res).isEmpty) {
      throw CustomerApiException(
          'This customer could not be updated.', res.statusCode);
    }
  }

  Future<void> delete(String id) async {
    final res = await postWithMethodOverride(
      Uri.parse('$_restEndpoint?table=customers&id=eq.$id'),
      method: 'DELETE',
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _decodeList(res); // throws with server message
    }
  }

  Future<List<AgentOption>> fetchAgents() async {
    final res = await _client.get(
      Uri.parse('$_restEndpoint?table=profiles&role=eq.agent'),
      headers: _headers,
    );
    final list = _decodeList(res);
    return list
        .map((e) => AgentOption(
              (e as Map<String, dynamic>)['id'].toString(),
              e['full_name'].toString(),
            ))
        .toList();
  }

  Future<List<Map<String, String>>> fetchAllLite() async {
    final res = await _client.get(
      // Use the customers resource directly so the notification recipient
      // picker always represents every row in the customers table.
      Uri.parse('$_restEndpoint?table=customers'),
      headers: _headers,
    );

    final list = _decodeList(res);

    return list.map((e) {
      final map = e as Map<String, dynamic>;
      return {
        'id': map['id']?.toString() ?? '',
        // Fallback to 'name' if your DB uses 'name' instead of 'full_name'
        'name': map['full_name']?.toString() ??
            map['name']?.toString() ??
            'Unknown',
        'email': map['email']?.toString() ?? '',
        // For pickers that search by customer code or mobile number.
        'code': map['customer_id']?.toString() ?? '',
        'mobile': (map['mobile'] ?? map['phone'])?.toString() ?? '',
      };
    }).toList();
  }

  Future<List<Map<String, String>>> fetchCustomerLogins() async {
    final res = await _client.get(
      Uri.parse(
          '$_restEndpoint?table=profiles&role=eq.customer&select=id,customer_id'),
      headers: _headers,
    );
    final list = _decodeList(res);
    return list.map((e) {
      final map = e as Map<String, dynamic>;
      return {
        'id': map['id']?.toString() ?? '',
        'customer_id': map['customer_id']?.toString() ?? '',
      };
    }).toList();
  }
}
