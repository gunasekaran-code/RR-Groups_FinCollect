/// Chit auctions & settlement — who won each draw, and whether the prize
/// has actually been handed over. Mirrors the `chit_auctions` table via
/// `ChitAuctionService::forGroup()` on the backend (backend/chit.php,
/// action=auctions), which drives the sheet from the group's draw schedule
/// so every installment shows even before an auction has been recorded
/// against it.
///
/// Save as: lib/models/chit_auction.dart
library;

/// A draw's settlement state — kept as plain strings on the wire so a status
/// the app doesn't yet know about still round-trips instead of crashing.
enum ChitAuctionStatus { open, won, settled }

ChitAuctionStatus chitAuctionStatusFromString(dynamic v) {
  switch ('$v'.toLowerCase()) {
    case 'settled':
      return ChitAuctionStatus.settled;
    case 'won':
      return ChitAuctionStatus.won;
    default:
      return ChitAuctionStatus.open;
  }
}

double _num(dynamic v) => double.tryParse('$v') ?? 0;
int _int(dynamic v) => int.tryParse('$v') ?? 0;
DateTime? _date(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v');
}

/// One recorded auction — who won a draw, the discount they bid, and
/// whether the prize has been paid out. Null on a draw that hasn't been
/// drawn yet.
class ChitAuctionRecord {
  ChitAuctionRecord({
    required this.id,
    required this.installmentNo,
    this.auctionDate,
    this.memberId,
    this.customerId,
    this.memberName,
    required this.poolAmount,
    required this.bidAmount,
    required this.commission,
    required this.payoutAmount,
    required this.dividendTotal,
    required this.status,
    this.payoutDate,
    required this.paymentMethod,
    this.ledgerId,
    this.agentName,
    this.notes,
  });

  final String id;
  final int installmentNo;
  final DateTime? auctionDate;
  final String? memberId;
  final String? customerId;
  final String? memberName;
  final double poolAmount;
  final double bidAmount;
  final double commission;
  final double payoutAmount;
  final double dividendTotal;
  final ChitAuctionStatus status;
  final DateTime? payoutDate;
  final String paymentMethod;
  final String? ledgerId;
  final String? agentName;
  final String? notes;

  bool get isSettled => status == ChitAuctionStatus.settled;

  factory ChitAuctionRecord.fromJson(Map<String, dynamic> json) {
    return ChitAuctionRecord(
      id: '${json['id']}',
      installmentNo: _int(json['installment_no']),
      auctionDate: _date(json['auction_date']),
      memberId: json['member_id']?.toString(),
      customerId: json['customer_id']?.toString(),
      memberName: json['member_name']?.toString(),
      poolAmount: _num(json['pool_amount']),
      bidAmount: _num(json['bid_amount']),
      commission: _num(json['commission']),
      payoutAmount: _num(json['payout_amount']),
      dividendTotal: _num(json['dividend_total']),
      status: chitAuctionStatusFromString(json['status']),
      payoutDate: _date(json['payout_date']),
      paymentMethod: (json['payment_method'] ?? 'cash').toString(),
      ledgerId: json['ledger_id']?.toString(),
      agentName: json['agent_name']?.toString(),
      notes: json['notes']?.toString(),
    );
  }
}

/// One row of the draw sheet — always present for every installment in the
/// group's schedule, whether or not it has been auctioned yet.
class ChitAuctionDraw {
  ChitAuctionDraw({
    required this.installmentNo,
    this.dueDate,
    required this.poolAmount,
    required this.payableAmount,
    required this.collected,
    this.auction,
    required this.status,
    this.orphaned = false,
  });

  final int installmentNo;
  final DateTime? dueDate;
  final double poolAmount;
  final double payableAmount;
  final double collected;
  final ChitAuctionRecord? auction;
  final ChitAuctionStatus status;
  final bool orphaned;

  factory ChitAuctionDraw.fromJson(Map<String, dynamic> json) {
    return ChitAuctionDraw(
      installmentNo: _int(json['installment_no']),
      dueDate: _date(json['due_date']),
      poolAmount: _num(json['pool_amount']),
      payableAmount: _num(json['payable_amount']),
      collected: _num(json['collected']),
      auction: json['auction'] is Map<String, dynamic>
          ? ChitAuctionRecord.fromJson(json['auction'] as Map<String, dynamic>)
          : null,
      status: chitAuctionStatusFromString(json['status']),
      orphaned: json['orphaned'] == true,
    );
  }
}

/// Group-wide totals for the summary strip at the top of the tab.
class ChitAuctionGroupSummary {
  ChitAuctionGroupSummary({
    required this.totalDraws,
    required this.won,
    required this.settled,
    required this.open,
    required this.paidOut,
    required this.pendingPayout,
    required this.dividendTotal,
  });

  final int totalDraws;
  final int won;
  final int settled;
  final int open;
  final double paidOut;
  final double pendingPayout;
  final double dividendTotal;

  factory ChitAuctionGroupSummary.empty() => ChitAuctionGroupSummary(
        totalDraws: 0,
        won: 0,
        settled: 0,
        open: 0,
        paidOut: 0,
        pendingPayout: 0,
        dividendTotal: 0,
      );

  factory ChitAuctionGroupSummary.fromJson(Map<String, dynamic> json) {
    return ChitAuctionGroupSummary(
      totalDraws: _int(json['total_draws']),
      won: _int(json['won']),
      settled: _int(json['settled']),
      open: _int(json['open']),
      paidOut: _num(json['paid_out']),
      pendingPayout: _num(json['pending_payout']),
      dividendTotal: _num(json['dividend_total']),
    );
  }
}

/// The whole Auctions & Settlement tab's data for one group.
class ChitAuctionData {
  ChitAuctionData({required this.draws, required this.summary});

  final List<ChitAuctionDraw> draws;
  final ChitAuctionGroupSummary summary;

  factory ChitAuctionData.fromJson(Map<String, dynamic> json) {
    final rows = json['draws'];
    return ChitAuctionData(
      draws: rows is List
          ? rows
              .whereType<Map>()
              .map((e) => ChitAuctionDraw.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      summary: json['summary'] is Map<String, dynamic>
          ? ChitAuctionGroupSummary.fromJson(json['summary'] as Map<String, dynamic>)
          : ChitAuctionGroupSummary.empty(),
    );
  }
}
