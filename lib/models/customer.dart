import '../widgets/phone_numbers_field.dart';

class Customer {
  final String id;

  // New fields
  final String customerId;
  final String fullName;
  final String? mobile;

  /// Extra contact numbers (the `alt_mobiles` column). Never used for
  /// sign-in — that is always [mobile].
  final List<String> altMobiles;
  final String? address;
  final String? aadhaar;
  final String? pan;
  final String? email;
  final String? occupation;

  // Photo / document fields (all stored as base64 data URIs, e.g.
  // "data:image/jpeg;base64,...."). `photoUrl` is the customer's profile
  // photo; the rest are scanned/photographed documents. Names mirror the
  // `customers` table columns (aadhaar_front_url, aadhaar_back_url,
  // pan_url, signature_url) so they round-trip through the generic REST
  // endpoint without any backend mapping.
  final String? photoUrl;
  final String? aadhaarFrontUrl;
  final String? aadhaarBackUrl;
  final String? panUrl;
  final String? signatureUrl;

  /// The list endpoint leaves the image columns out and sends `has_photo`
  /// instead, so a card knows whether there is an avatar worth fetching
  /// from photo.php without carrying the picture itself.
  final bool hasPhoto;

  final String? assignedAgent;
  final String? assignedAgentName;
  final double? latitude;
  final double? longitude;
  final String loanStatus;
  final DateTime? createdAt;

  Customer({
    required this.id,
    this.customerId = '',
    required this.fullName,
    this.mobile,
    this.altMobiles = const [],
    this.address,
    this.aadhaar,
    this.pan,
    this.email,
    this.occupation,
    this.photoUrl,
    this.aadhaarFrontUrl,
    this.aadhaarBackUrl,
    this.panUrl,
    this.signatureUrl,
    this.hasPhoto = false,
    this.assignedAgent,
    this.assignedAgentName,
    this.latitude,
    this.longitude,
    this.loanStatus = 'none',
    this.createdAt,
  });

  /// Backward compatibility
  String get name => fullName;
  String? get phone => mobile;

  factory Customer.fromJson(Map<String, dynamic> json) {
    double? toDouble(dynamic value) {
      if (value == null) return null;
      return double.tryParse(value.toString());
    }

    String? nonEmpty(dynamic value) {
      final s = value?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    return Customer(
      id: json['id']?.toString() ?? '',
      customerId: json['customer_id']?.toString() ?? '',
      fullName: (json['full_name'] ??
              json['name'] ??
              json['customer_name'] ??
              'Unnamed')
          .toString(),
      mobile: (json['mobile'] ?? json['phone'])?.toString(),
      altMobiles: PhoneNumbersController.parse(json['alt_mobiles']),
      address: json['address']?.toString(),
      aadhaar: json['aadhaar']?.toString(),
      pan: json['pan']?.toString(),
      email: nonEmpty(json['email']),
      occupation: json['occupation']?.toString(),
      photoUrl: nonEmpty(json['photo_url']),
      aadhaarFrontUrl: nonEmpty(json['aadhaar_front_url']),
      aadhaarBackUrl: nonEmpty(json['aadhaar_back_url']),
      panUrl: nonEmpty(json['pan_url']),
      signatureUrl: nonEmpty(json['signature_url']),
      hasPhoto: nonEmpty(json['photo_url']) != null ||
          json['has_photo'] == true ||
          json['has_photo']?.toString() == '1',
      assignedAgent: json['assigned_agent']?.toString(),
      assignedAgentName: json['assigned_agent_name']?.toString(),
      latitude: toDouble(json['latitude']),
      longitude: toDouble(json['longitude']),
      loanStatus: json['loan_status']?.toString() ?? 'none',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toRequestBody({
    String? email,
    String? password,
  }) {
    final body = <String, dynamic>{
      'full_name': fullName,
      'mobile': mobile,
      'alt_mobiles': PhoneNumbersController.encode(altMobiles),
      'address': address,
      'aadhaar': aadhaar,
      'pan': pan,
      'occupation': occupation,
      'photo_url': photoUrl,
      'aadhaar_front_url': aadhaarFrontUrl,
      'aadhaar_back_url': aadhaarBackUrl,
      'pan_url': panUrl,
      'signature_url': signatureUrl,
      'assigned_agent': assignedAgent,
      'latitude': latitude,
      'longitude': longitude,
    };

    if (email != null && email.isNotEmpty) {
      body['email'] = email;
    }
    if (password != null && password.isNotEmpty) {
      body['password'] = password;
    }

    return body;
  }

  /// True when at least one document/photo field is set. Used to decide
  /// whether a follow-up write is needed to persist them (see
  /// [documentFields] and [CustomerApiService]).
  bool get hasDocumentFields =>
      aadhaarFrontUrl != null ||
      aadhaarBackUrl != null ||
      panUrl != null ||
      signatureUrl != null;

  /// Just the document/photo columns, keyed exactly as the `customers`
  /// table names them. The create endpoint (customers.php) only writes a
  /// fixed whitelist of columns that excludes these, so after creating (or
  /// updating alongside a login change) a customer, this is PATCHed
  /// separately through the generic REST endpoint, which writes any real
  /// column on the table.
  Map<String, dynamic> documentFields() => {
        'photo_url': photoUrl,
        'aadhaar_front_url': aadhaarFrontUrl,
        'aadhaar_back_url': aadhaarBackUrl,
        'pan_url': panUrl,
        'signature_url': signatureUrl,
      };

  Customer copyWith({
    String? photoUrl,
    String? aadhaarFrontUrl,
    String? aadhaarBackUrl,
    String? panUrl,
    String? signatureUrl,
  }) {
    return Customer(
      id: id,
      customerId: customerId,
      fullName: fullName,
      mobile: mobile,
      altMobiles: altMobiles,
      address: address,
      aadhaar: aadhaar,
      pan: pan,
      email: email,
      occupation: occupation,
      photoUrl: photoUrl ?? this.photoUrl,
      aadhaarFrontUrl: aadhaarFrontUrl ?? this.aadhaarFrontUrl,
      aadhaarBackUrl: aadhaarBackUrl ?? this.aadhaarBackUrl,
      panUrl: panUrl ?? this.panUrl,
      signatureUrl: signatureUrl ?? this.signatureUrl,
      hasPhoto: hasPhoto,
      assignedAgent: assignedAgent,
      assignedAgentName: assignedAgentName,
      latitude: latitude,
      longitude: longitude,
      loanStatus: loanStatus,
      createdAt: createdAt,
    );
  }

  @override
  String toString() => fullName;
}