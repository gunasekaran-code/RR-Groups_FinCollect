import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import 'auth_api_service.dart';
import 'session_service.dart';
import 'collection_api_service.dart';
import 'method_override_http.dart';
import '../models/agent_collection.dart';

class AgentCollectionApiService {
  static String get _restEndpoint => '${ApiConfig.normalizedBaseUrl}/rest.php';

  static Future<Map<String, String>> _headers() async {
    final token = await AuthApiService.instance.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  static Uri _scheduleUri([Map<String, String>? query]) {
    return Uri.parse(_restEndpoint).replace(queryParameters: {
      'table': 'repayment_schedule',
      ...?query,
    });
  }

  static Uri _loanUri([Map<String, String>? query]) {
    return Uri.parse(_restEndpoint).replace(queryParameters: {
      'table': 'loans',
      ...?query,
    });
  }

  /// GET repayment_schedule -> unpaid schedules for either the logged-in
  /// agent or all loans when [assignedOnly] is false.
  /// Each row is enriched with customer/location/loan-balance details
  /// pulled from the joined loan record, so the UI can group everything by
  /// customer without a second round trip.
  ///
  /// NOTE ON PENALTY: `penalty_amount` is read straight from whatever the
  /// `repayment_schedule` row (or the joined loan row) already has. If
  /// your penalty is computed elsewhere (a cron job, a DB trigger, a
  /// stored procedure when a schedule goes overdue), make sure *that*
  /// logic only ever writes a non-zero `penalty_amount` for weekly and
  /// monthly-EMI loans — daily and monthly-interest loans should never
  /// have penalty written for them at the source. The model layer
  /// (`AgentCollectionItem.effectivePenalty` / `appliesPenalty`) adds a
  /// belt-and-braces guard on the client so a stray value can't leak into
  /// the UI, but the source of truth should still be fixed at the point
  /// the penalty gets calculated.
  static Future<List<AgentCollectionItem>> fetchAssignedCollections({
    bool assignedOnly = true,
  }) async {
    final currentUser = SessionService.instance.currentUser;
    final agentId = currentUser?.userId;
    if (assignedOnly && agentId == null) return [];

    final loanRes = await http.get(
      _loanUri({
        if (assignedOnly) 'assigned_agent': 'eq.$agentId',
      }),
      headers: await _headers(),
    );
    if (loanRes.statusCode != 200) {
      throw Exception(
          'Failed to load assigned loans (${loanRes.statusCode}): ${loanRes.body}');
    }

    final loanDecoded = jsonDecode(loanRes.body);
    final loanList =
        loanDecoded is List ? loanDecoded : (loanDecoded['data'] ?? []);
    final loans = loanList.cast<Map<String, dynamic>>();
    if (loans.isEmpty) return [];

    final loanById = {
      for (final row in loans) (row['id']?.toString() ?? ''): row
    };
    final loanIds = loanById.keys.where((id) => id.isNotEmpty).toList();
    if (loanIds.isEmpty) return [];

    final loanIdsParam = '(${loanIds.join(',')})';
    final scheduleRes = await http.get(
      _scheduleUri({
        'loan_id': 'in.$loanIdsParam',
        'status': 'neq.paid',
      }),
      headers: await _headers(),
    );
    if (scheduleRes.statusCode != 200) {
      throw Exception(
          'Failed to load collections (${scheduleRes.statusCode}): ${scheduleRes.body}');
    }

    final decoded = jsonDecode(scheduleRes.body);
    final List list = decoded is List ? decoded : (decoded['data'] ?? []);
    final rows = list.cast<Map<String, dynamic>>();

    AgentCollectionItem toItem(Map<String, dynamic> row) {
      final loan = loanById[row['loan_id']?.toString() ?? ''];
      final appliesPenalty = _appliesPenaltyForType(row['loan_type'] ??
          loan?['loan_type'] ??
          loan?['collection_type'] ??
          '');
      return AgentCollectionItem.fromJson({
        ...row,
        'loan_number': loan?['loan_number'] ?? row['loan_number'],
        'loan_type':
            loan?['loan_type'] ?? loan?['collection_type'] ?? row['loan_type'],
        'loan_name': loan?['loan_name'] ??
            loan?['scheme_name'] ??
            loan?['collection_name'] ??
            loan?['loan_number'] ??
            row['loan_name'],
        'customer_name': loan?['customer_name'] ?? row['customer_name'],
        'customer_id': loan?['customer_id'] ?? row['customer_id'],
        'agent_id': loan?['assigned_agent'] ?? row['agent_id'],
        'agent_name': loan?['agent_name'] ?? row['agent_name'],
        'contact_phone': row['contact_phone'] ??
            row['phone'] ??
            loan?['contact_phone'] ??
            loan?['phone'],
        'address':
            row['address'] ?? loan?['address'] ?? loan?['customer_address'],
        'latitude': row['latitude'] ?? loan?['latitude'],
        'longitude': row['longitude'] ?? loan?['longitude'],
        'outstanding_balance': row['outstanding_balance'] ??
            loan?['outstanding_balance'] ??
            loan?['balance'],
        'due_amount': row['due_amount'] ?? row['balance'] ?? row['emi_amount'],
        // Belt-and-braces: even if the row/loan carries a
        // penalty_amount, don't let it through for loan types that
        // should never show one. See the note above
        // fetchAssignedCollections for where to fix this properly.
        'penalty_amount': appliesPenalty ? row['penalty_amount'] : 0,
        'loan_penalty_amount':
            appliesPenalty ? (loan?['penalty_amount'] ?? 0) : 0,
      });
    }

    final items = rows.map(toItem).where((item) => !item.isPaid).toList();

    // A loan whose EMIs are all paid can still owe penalty for paying them
    // late. It has no open instalment, so list its penalty-bearing rows as
    // overdue with nothing due, letting the penalty still be collected.
    final listedLoans = items.map((i) => i.loanId).toSet();
    final penaltyOnlyLoanIds = loans
        .where((l) {
          final id = l['id']?.toString() ?? '';
          final penalty =
              double.tryParse(l['penalty_amount']?.toString() ?? '') ?? 0;
          return id.isNotEmpty &&
              !listedLoans.contains(id) &&
              penalty > 0 &&
              l['status']?.toString() != 'closed' &&
              _appliesPenaltyForType(
                  (l['loan_type'] ?? l['collection_type'] ?? '').toString());
        })
        .map((l) => l['id'].toString())
        .toList();
    if (penaltyOnlyLoanIds.isNotEmpty) {
      final penaltyRes = await http.get(
        _scheduleUri({
          'loan_id': 'in.(${penaltyOnlyLoanIds.join(',')})',
          'penalty_amount': 'gt.0',
        }),
        headers: await _headers(),
      );
      if (penaltyRes.statusCode == 200) {
        final penaltyDecoded = jsonDecode(penaltyRes.body);
        final List penaltyList = penaltyDecoded is List
            ? penaltyDecoded
            : (penaltyDecoded['data'] ?? []);
        items.addAll(penaltyList.cast<Map<String, dynamic>>().map((row) =>
            toItem(
                {...row, 'status': 'overdue', 'balance': 0, 'due_amount': 0})));
      }
    }

    items.sort((a, b) {
      int rank(AgentCollectionStatus s) =>
          s == AgentCollectionStatus.overdue ? 0 : 1;
      final rankCompare = rank(a.status).compareTo(rank(b.status));
      if (rankCompare != 0) return rankCompare;
      final aDate = a.dueDate ?? DateTime(2100);
      final bDate = b.dueDate ?? DateTime(2100);
      return aDate.compareTo(bDate);
    });

    return items;
  }

  static bool _appliesPenaltyForType(String rawLoanType) {
    final type = parseLoanCollectionType(rawLoanType);
    return type == LoanCollectionType.weekly ||
        type == LoanCollectionType.monthlyEmi ||
        type == LoanCollectionType.monthlyInterest;
  }

  /// Fetches and groups the agent's due collections by customer in one call
  /// — this is what the collections list screen should use.
  static Future<List<AgentCustomerGroup>>
      fetchAssignedCollectionGroups() async {
    final items = await fetchAssignedCollections();
    return AgentCustomerGroup.groupItems(items);
  }

  /// Fetches all unpaid loan schedules for admin collection views.
  static Future<List<AgentCustomerGroup>> fetchAllCollectionGroups() async {
    final items = await fetchAssignedCollections(assignedOnly: false);
    return AgentCustomerGroup.groupItems(items);
  }

  /// Records a collection against a single installment: creates a row in
  /// `collections` via [CollectionApiService.createCollection], then
  /// (best-effort) updates the schedule row so it drops off the agent's due
  /// list once fully paid.
  ///
  /// [markPaid] controls whether the schedule row is flagged `paid`. Pass
  /// `false` for a partial payment so the remaining balance stays open —
  /// the schedule's `due_amount` is reduced by the collected amount instead.
  ///
  /// This is used for the "regular" waterfall path (weekly / monthly-EMI /
  /// daily loans). Monthly-interest loans use
  /// [_collectMonthlyInterestPayment] instead, since "amount paid" doesn't
  /// map onto `due_amount` the same way there.
  static Future<void> collectPayment({
    required AgentCollectionItem item,
    required double amount,
    required String paymentMethod,
    required DateTime collectionDate,
    String? notes,
    bool markPaid = true,
  }) async {
    final currentUser = SessionService.instance.currentUser;
    final payload = {
      'customer_id': item.customerId,
      'customer_name': item.customerName,
      'loan_id': item.loanId,
      'loan_number': item.loanNumber,
      'loan_type': item.loanType,
      'loan_name': item.loanName,
      'collection_amount': amount,
      'payment_method': paymentMethod,
      'collection_date': _toIsoDate(collectionDate),
      'agent_id': currentUser?.userId,
      'agent_name': currentUser?.name,
      'schedule_id': item.scheduleId ?? item.id,
      'receipt_number': _generateReceiptNumber(),
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    };

    await CollectionApiService.createCollection(payload);

    try {
      if (markPaid) {
        await postWithMethodOverride(
          _scheduleUri({'id': item.id}),
          method: 'PATCH',
          headers: await _headers(),
          body: jsonEncode({'status': 'paid'}),
        );
      } else {
        final remainingDue =
            (item.dueAmount - amount) < 0 ? 0.0 : (item.dueAmount - amount);
        await postWithMethodOverride(
          _scheduleUri({'id': item.id}),
          method: 'PATCH',
          headers: await _headers(),
          body: jsonEncode({'due_amount': remainingDue}),
        );
      }
    } catch (_) {
      // Non-fatal — the collection itself was already recorded above.
    }
  }

  /// Records a single payment against a customer who may have several due
  /// loans/installments.
  ///
  /// - For weekly / monthly-EMI / daily loans (`paymentType == 'regular'`),
  ///   the amount is applied like a payment waterfall — oldest due date
  ///   first — fully settling each installment before moving to the next.
  /// - For monthly-interest loans, `paymentType` tells us which side of
  ///   the ledger this payment hits: 'interest' clears the month's
  ///   interest without touching principal, 'principal' reduces the
  ///   remaining principal without clearing the interest due, and 'full'
  ///   does both.
  /// - [penaltyAmount] is the part of [amount] that pays penalty. It is
  ///   recorded as its own "Penalty Payment" receipt, which the backend
  ///   keeps off the instalments; only the rest is applied as above.
  static Future<int> collectForCustomer({
    required AgentCustomerGroup group,
    required double amount,
    required String paymentMethod,
    required DateTime collectionDate,
    String? notes,
    String paymentType = 'regular',
    double penaltyAmount = 0,
  }) async {
    final penaltyPart = penaltyAmount.clamp(0.0, amount).toDouble();
    var penaltyRecords = 0;
    if (penaltyPart > 0 && group.items.isNotEmpty) {
      await _collectPenaltyPayment(
        item: group.items.first,
        amount: penaltyPart,
        paymentMethod: paymentMethod,
        collectionDate: collectionDate,
        notes: notes,
      );
      penaltyRecords = 1;
    }
    amount -= penaltyPart;
    if (amount <= 0) return penaltyRecords;

    if (group.collectionType == LoanCollectionType.monthlyInterest) {
      return penaltyRecords +
          await _collectMonthlyInterestPayment(
            group: group,
            amount: amount,
            paymentMethod: paymentMethod,
            collectionDate: collectionDate,
            notes: notes,
            paymentType: paymentType,
          );
    }

    final sortedItems = [...group.items]..sort((a, b) {
        final aDate = a.dueDate ?? DateTime(2100);
        final bDate = b.dueDate ?? DateTime(2100);
        return aDate.compareTo(bDate);
      });

    double remaining = amount;
    var recordsCreated = 0;
    for (final item in sortedItems) {
      if (remaining <= 0) break;
      final payAmount =
          remaining >= item.dueAmount ? item.dueAmount : remaining;
      if (payAmount <= 0) continue;
      remaining -= payAmount;
      final fullyCovered = payAmount >= (item.dueAmount - 0.01);
      await collectPayment(
        item: item,
        amount: payAmount,
        paymentMethod: paymentMethod,
        collectionDate: collectionDate,
        notes: notes,
        markPaid: fullyCovered,
      );
      recordsCreated++;
    }
    return penaltyRecords + recordsCreated;
  }

  /// Label written in a penalty receipt's notes. The split itself travels in
  /// `penalty_amount`; this only tells people what the receipt was for.
  static const String penaltyNote = 'Penalty Payment';

  /// Records a penalty-only payment. It touches no schedule row — the
  /// backend recalculation settles it against the loan's penalty.
  static Future<void> _collectPenaltyPayment({
    required AgentCollectionItem item,
    required double amount,
    required String paymentMethod,
    required DateTime collectionDate,
    String? notes,
  }) async {
    final currentUser = SessionService.instance.currentUser;
    final extra = notes?.trim() ?? '';
    await CollectionApiService.createCollection({
      'customer_id': item.customerId,
      'customer_name': item.customerName,
      'loan_id': item.loanId,
      'loan_number': item.loanNumber,
      'collection_amount': amount,
      // The whole receipt is penalty. The backend reads this field, not the
      // note, to keep it off the instalments and settle the loan's penalty.
      'penalty_amount': amount,
      'payment_method': paymentMethod,
      'collection_date': _toIsoDate(collectionDate),
      'agent_id': currentUser?.userId,
      'agent_name': currentUser?.name,
      'receipt_number': _generateReceiptNumber(),
      'notes': extra.isEmpty ? penaltyNote : '$penaltyNote - $extra',
    });
  }

  /// Handles a payment against a monthly-interest loan. This deliberately
  /// does NOT reuse [collectPayment]'s `markPaid` semantics, because those
  /// assume "amount paid" always reduces `due_amount` on the schedule row
  /// — which is wrong here: a principal payment must reduce the loan's
  /// `outstanding_balance` instead, and must leave the month's interest
  /// schedule row untouched.
  static Future<int> _collectMonthlyInterestPayment({
    required AgentCustomerGroup group,
    required double amount,
    required String paymentMethod,
    required DateTime collectionDate,
    String? notes,
    required String paymentType,
  }) async {
    if (group.items.isEmpty) return 0;
    final item = group.items.first;
    final currentUser = SessionService.instance.currentUser;

    final payload = {
      'customer_id': item.customerId,
      'customer_name': item.customerName,
      'loan_id': item.loanId,
      'loan_number': item.loanNumber,
      'loan_type': item.loanType,
      'loan_name': item.loanName,
      'collection_amount': amount,
      'payment_method': paymentMethod,
      // Record which side of the ledger this hit — useful for statements
      // and for reconciling interest-vs-principal collected over time.
      'payment_type': paymentType,
      'collection_date': _toIsoDate(collectionDate),
      'agent_id': currentUser?.userId,
      'agent_name': currentUser?.name,
      'schedule_id': item.scheduleId ?? item.id,
      'receipt_number': _generateReceiptNumber(),
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    };

    await CollectionApiService.createCollection(payload);

    final interestDue = item.installmentAmount;
    final currentPrincipal = group.totalOutstanding;

    try {
      switch (paymentType) {
        case 'interest':
          // Only this month's interest is covered — clear the interest
          // schedule row, principal stays exactly as it was.
          await postWithMethodOverride(
            _scheduleUri({'id': item.id}),
            method: 'PATCH',
            headers: await _headers(),
            body: jsonEncode({'status': 'paid'}),
          );
          break;

        case 'principal':
          // Reduces the loan's remaining principal only. The month's
          // interest schedule stays open — a separate interest payment
          // is still expected for it.
          final newBalance = (currentPrincipal - amount) < 0
              ? 0.0
              : (currentPrincipal - amount);
          await postWithMethodOverride(
            _loanUri({'id': item.loanId}),
            method: 'PATCH',
            headers: await _headers(),
            body: jsonEncode({'outstanding_balance': newBalance}),
          );
          break;

        case 'full':
        default:
          // Pays off the interest first, remainder goes to principal.
          final principalPortion =
              (amount - interestDue) < 0 ? 0.0 : (amount - interestDue);
          final newBalance = (currentPrincipal - principalPortion) < 0
              ? 0.0
              : (currentPrincipal - principalPortion);
          await postWithMethodOverride(
            _scheduleUri({'id': item.id}),
            method: 'PATCH',
            headers: await _headers(),
            body: jsonEncode({'status': 'paid'}),
          );
          await postWithMethodOverride(
            _loanUri({'id': item.loanId}),
            method: 'PATCH',
            headers: await _headers(),
            body: jsonEncode({'outstanding_balance': newBalance}),
          );
          break;
      }
    } catch (_) {
      // Non-fatal — the collection itself was already recorded above.
    }

    return 1;
  }

  static String _generateReceiptNumber() {
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch
        .toString()
        .substring(5); // last digits, keeps it short
    return 'RCT-$ts';
  }

  static String _toIsoDate(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}
