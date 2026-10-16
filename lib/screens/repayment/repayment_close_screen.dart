import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/loan_record.dart';
import '../../models/repayment_installment.dart';
import '../../routes/app_routes.dart';
import '../../services/api_service_repayment.dart' show ApiException;
import '../../services/method_override_http.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_toast.dart';
import '../../widgets/app_shell.dart';

// ---------------------------------------------------------------------------
// BACKEND CALL
// ---------------------------------------------------------------------------
class _CloseLoanApi {
  static const _storage = FlutterSecureStorage();
  static String get _base => '${ApiConfig.normalizedBaseUrl}/rest.php';

  static Future<Map<String, String>> _headers() async {
    final token = await _storage.read(key: 'auth_token');
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Uri _uri(String table, [Map<String, String>? q]) =>
      Uri.parse(_base).replace(queryParameters: {'table': table, ...?q});

  static Future<void> closeLoan({
    required String loanId,
    required double amount,
    required double interestCharged,
    required String paymentMethod,
    required DateTime date,
  }) async {
    final d = '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    final res = await http.post(
      _uri('collections'),
      headers: await _headers(),
      body: jsonEncode({
        'loan_id': loanId,
        'amount': amount,
        'payment_method': paymentMethod,
        'collection_date': d,
        'notes': 'Early closure. Interest charged: '
            '${interestCharged.toStringAsFixed(2)}',
      }),
    );
    await SessionService.instance.handleUnauthorized(res);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(
          'Failed to record closing payment', res.statusCode, res.body);
    }

    final patch = await postWithMethodOverride(
      _uri('loans', {'id': loanId}),
      method: 'PATCH',
      headers: await _headers(),
      body: jsonEncode({'status': 'Closed'}),
    );
    if (patch.statusCode != 200) {
      throw ApiException('Failed to close loan', patch.statusCode, patch.body);
    }
  }
}

// ---------------------------------------------------------------------------

enum _Mode { interest, closing }

class RepaymentCloseScreen extends StatefulWidget {
  final LoanRecord loan;
  final String customerName;
  final List<RepaymentInstallment> installments;

  const RepaymentCloseScreen({
    super.key,
    required this.loan,
    required this.customerName,
    required this.installments,
  });

  static Future<bool?> show(
    BuildContext context, {
    required LoanRecord loan,
    required String customerName,
    required List<RepaymentInstallment> installments,
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RepaymentCloseScreen(
          loan: loan,
          customerName: customerName,
          installments: installments,
        ),
      ),
    );
  }

  @override
  State<RepaymentCloseScreen> createState() => _RepaymentCloseScreenState();
}

class _RepaymentCloseScreenState extends State<RepaymentCloseScreen> {
  static const _methods = <String, String>{
    'Cash': 'Cash / ரொக்கம்',
    'UPI': 'UPI / யுபிஐ',
    'Bank Transfer': 'Bank Transfer / வங்கி பரிமாற்றம்',
  };

  final _interestCtrl = TextEditingController();
  final _closeCtrl = TextEditingController();
  _Mode _mode = _Mode.interest;
  bool _editingClose = false;
  bool _manualInterest = false;
  bool _saving = false;

  String _method = 'Cash';
  DateTime _date = DateTime.now();

  late final List<RepaymentInstallment> _sorted;
  late final double _principal;
  late final double _totalRepayment;
  late final double _totalInterest;
  late final double _paidSoFar;
  late final int _n;

  @override
  void initState() {
    super.initState();
    _sorted = [...widget.installments]
      ..sort((a, b) => a.installmentNo.compareTo(b.installmentNo));
    _n = _sorted.length;
    _principal = widget.loan.principalAmount;
    _totalRepayment = _sorted.fold(0.0, (s, i) => s + i.emiAmount);
    _totalInterest =
        (_totalRepayment - _principal).clamp(0, double.infinity).toDouble();
    _paidSoFar = _sorted.fold(0.0, (s, i) => s + i.paidAmount);
    _syncFromCalculated();
  }

  @override
  void dispose() {
    _interestCtrl.dispose();
    _closeCtrl.dispose();
    super.dispose();
  }

  double _r2(double v) => (v * 100).roundToDouble() / 100;

  String get _unit {
    switch (widget.loan.collectionType.toLowerCase()) {
      case 'weekly':
        return 'weeks';
      case 'daily':
        return 'days';
      default:
        return 'months';
    }
  }

  DateTime? get _startDate {
    if (_sorted.isEmpty || _sorted.first.dueDate == null) return null;
    final d = _sorted.first.dueDate!;
    switch (_unit) {
      case 'weeks':
        return d.subtract(const Duration(days: 7));
      case 'days':
        return d.subtract(const Duration(days: 1));
      default:
        return DateTime(d.year, d.month - 1, d.day);
    }
  }

  double get _elapsed {
    final start = _startDate;
    if (start == null || _n == 0) return 0;
    final end = DateTime(_date.year, _date.month, _date.day);
    if (!end.isAfter(start)) return 0;

    double units;
    switch (_unit) {
      case 'weeks':
        units = end.difference(start).inDays / 7;
        break;
      case 'days':
        units = end.difference(start).inDays.toDouble();
        break;
      default:
        var whole = (end.year - start.year) * 12 + (end.month - start.month);
        var anchor = DateTime(start.year, start.month + whole, start.day);
        if (anchor.isAfter(end)) {
          whole--;
          anchor = DateTime(start.year, start.month + whole, start.day);
        }
        units = whole + end.difference(anchor).inDays / 30;
    }
    return units.floorToDouble().clamp(0, _n.toDouble()).toDouble();
  }

  double get _calculatedInterest =>
      _n == 0 ? 0 : _r2(_totalInterest * _elapsed / _n);

  double get _interest => double.tryParse(_interestCtrl.text) ?? 0;
  double get _closing => double.tryParse(_closeCtrl.text) ?? 0;

  double _closingFor(double interest) =>
      _r2((_principal + interest - _paidSoFar)
          .clamp(0, double.infinity)
          .toDouble());

  double get _remainingToEnd =>
      (_totalRepayment - _paidSoFar).clamp(0, double.infinity).toDouble();

  void _syncFromCalculated() {
    final i = _calculatedInterest;
    _interestCtrl.text = _fmtInput(i);
    _closeCtrl.text = _fmtInput(_closingFor(i));
  }

  String _fmtInput(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  String _rs(double v) => LoanRecord.formatRupees(v);

  String _dateText(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  void _onInterestChanged(String _) {
    _manualInterest = true;
    setState(() => _closeCtrl.text = _fmtInput(_closingFor(_interest)));
  }

  void _onClosingChanged(String _) {
    final i = _r2((_closing + _paidSoFar - _principal)
        .clamp(0, double.infinity)
        .toDouble());
    setState(() => _interestCtrl.text = _fmtInput(i));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.kGold,
              onPrimary: Colors.white,
              onSurface: AppColors.kTextDark,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _date = picked;
      if (!_manualInterest && !_editingClose) _syncFromCalculated();
    });
  }

  Future<void> _submit() async {
    final amount = _closing;
    if (amount <= 0) {
      ToastService.show(
        title: 'Invalid amount / தவறான தொகை',
        message: 'Enter an amount greater than 0',
        type: ToastType.error,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _CloseLoanApi.closeLoan(
        loanId: widget.loan.id,
        amount: amount,
        interestCharged: _interest,
        paymentMethod: _method,
        date: _date,
      );
      if (!mounted) return;
      ToastService.show(
        title: 'Loan closed / கடன் முடிக்கப்பட்டது',
        message: widget.loan.loanNumber,
        type: ToastType.success,
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ToastService.show(
        title: 'Could not close loan / கடனை முடிக்க முடியவில்லை',
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  // ---- UI Styles & Builders -----------------------------------------------

  InputDecoration _fieldDecoration() => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.kBackground, // Distinct from the white card
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.kGold, width: 2.0),
        ),
      );

  List<TextInputFormatter> get _numFormatters =>
      [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))];

  @override
  Widget build(BuildContext context) {
    final notCharged =
        (_totalInterest - _interest).clamp(0, double.infinity).toDouble();
    final elapsedLabel = _elapsed
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');

    // Layout Breakpoint
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 600;

    return AppShell(
      currentRoute: AppRoutes.repayment,
      title: 'Close Loan Early',
      showBackButton: true,
      onBack: () {
        if (!_saving) Navigator.of(context).pop(false);
      },
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 32 : 16,
            vertical: isTablet ? 32 : 24,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720), // Tablet wide
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- Header ---
                  Text(widget.customerName,
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.kTextDark)),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.loan.loanNumber} · paid $elapsedLabel of $_n instalments\n'
                    '$_n-ல் $elapsedLabel தவணை கட்டியாச்சு',
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.kTextMuted, height: 1.4),
                  ),
                  const SizedBox(height: 24),

                  // --- Cards ---
                  _summaryCard(notCharged, elapsedLabel),
                  const SizedBox(height: 20),
                  _interestCard(isTablet),
                  const SizedBox(height: 20),
                  _closeCard(),
                  const SizedBox(height: 20),
                  _methodAndDate(isTablet),
                  const SizedBox(height: 32),

                  // --- Footer Actions ---
                  _actions(isTablet),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _summaryCard(double notCharged, String elapsedLabel) {
    Widget row(String label, String value,
        {String? sub, Color? color, bool last = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
            border: last
                ? null
                : const Border(
                    bottom: BorderSide(color: AppColors.kBorder, width: 1))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.kTextDark)),
                  if (sub != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(sub,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.kTextMuted,
                              height: 1.4)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text(value,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: color ?? AppColors.kTextDark)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.kTextDark.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        children: [
          row('Given to the customer / கொடுத்தது', _rs(_principal)),
          row('Paid so far / இதுவரை கட்டியது', _rs(_paidSoFar)),
          row('Interest earned / வட்டி', _rs(_interest),
              sub: '$elapsedLabel of $_n instalments\n'
                  'மொத்த வட்டி ${_rs(_totalInterest)}'),
          row('Interest not charged / தள்ளுபடி வட்டி', '– ${_rs(notCharged)}',
              color: AppColors.kSuccess,
              sub: 'Unused instalments\nபயன்படுத்தாத தவணைகள்'),
          row('Cost if paid till end / கடைசி வரை கட்டினால்',
              _rs(_remainingToEnd),
              last: true),
        ],
      ),
    );
  }

  Widget _interestCard(bool isTablet) {
    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('INTEREST TO CHARGE / வசூலிக்க வேண்டிய வட்டி',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.kTextDark)),
        const SizedBox(height: 6),
        Text(
          'Calculated ${_rs(_calculatedInterest)} · the closing amount follows\n'
          'கணக்குப்படி ${_rs(_calculatedInterest)} · மாற்றினால் கீழே உள்ள தொகை மாறும்',
          style: const TextStyle(
              fontSize: 13, color: AppColors.kTextMuted, height: 1.4),
        ),
      ],
    );

    final inputWidget = _mode == _Mode.interest
        ? SizedBox(
            width: isTablet ? 140 : double.infinity,
            child: TextField(
              controller: _interestCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: _numFormatters,
              onChanged: _onInterestChanged,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              decoration: _fieldDecoration(),
            ),
          )
        : const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        border: Border.all(color: AppColors.kBorder),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.kTextDark.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isTablet)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: infoColumn),
                if (_mode == _Mode.interest) const SizedBox(width: 20),
                inputWidget,
              ],
            )
          else ...[
            infoColumn,
            if (_mode == _Mode.interest) const SizedBox(height: 16),
            inputWidget,
          ],
          if (_mode == _Mode.closing) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => setState(() {
                _mode = _Mode.interest;
                _editingClose = false;
              }),
              child: const Text(
                'Set the interest instead / வட்டியை நேரடியாக அமைக்க',
                style: TextStyle(
                    fontSize: 14,
                    color: AppColors.kGoldDark,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _closeCard() {
    final repaid = _paidSoFar + _closing;
    final editing = _mode == _Mode.closing;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.kGold.withOpacity(0.08),
        border: Border.all(color: AppColors.kGold.withOpacity(0.5), width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('TO CLOSE TODAY / இன்று கட்ட வேண்டியது',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: AppColors.kGoldDark)),
              ),
              if (!editing)
                InkWell(
                  onTap: () => setState(() {
                    _mode = _Mode.closing;
                    _editingClose = true;
                  }),
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined,
                            size: 18, color: AppColors.kGoldDark),
                        SizedBox(width: 6),
                        Text('Change',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.kGoldDark)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (editing)
            TextField(
              controller: _closeCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: _numFormatters,
              onChanged: _onClosingChanged,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
              decoration: _fieldDecoration().copyWith(
                fillColor: AppColors.kSurface, // Solid white input on tinted card
              ),
            )
          else
            Text(_rs(_closing),
                style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    color: AppColors.kGoldDark)),
          const SizedBox(height: 12),
          Text(
            'They will have repaid ${_rs(repaid)} against the ${_rs(_principal)} received.\n'
            '${_rs(_principal)} வாங்கி மொத்தம் ${_rs(repaid)} கட்டியிருப்பார்.',
            style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: AppColors.kGoldDark,
                height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _methodAndDate(bool isTablet) {
    const labelStyle = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: AppColors.kTextMuted);

    final methodWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PAYMENT METHOD / செலுத்தும் முறை', style: labelStyle),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _method,
          isExpanded: true,
          icon: const Icon(Icons.expand_more, color: AppColors.kTextMuted),
          decoration: _fieldDecoration().copyWith(fillColor: AppColors.kSurface),
          items: _methods.entries
              .map((e) => DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (v) => setState(() => _method = v ?? _method),
        ),
      ],
    );

    final dateWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('DATE / தேதி', style: labelStyle),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pickDate,
          borderRadius: BorderRadius.circular(12),
          child: InputDecorator(
            decoration: _fieldDecoration().copyWith(fillColor: AppColors.kSurface),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_dateText(_date),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const Icon(Icons.calendar_today_outlined,
                    size: 20, color: AppColors.kTextMuted),
              ],
            ),
          ),
        ),
      ],
    );

    // Responsive Structure
    if (isTablet) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: methodWidget),
          const SizedBox(width: 20),
          Expanded(child: dateWidget),
        ],
      );
    } else {
      return Column(
        children: [
          methodWidget,
          const SizedBox(height: 20),
          dateWidget,
        ],
      );
    }
  }

  Widget _actions(bool isTablet) {
    final cancelButton = OutlinedButton(
      onPressed: _saving ? null : () => Navigator.of(context).pop(false),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18),
        side: const BorderSide(color: AppColors.kBorder, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: const Text('Cancel / ரத்து',
          style: TextStyle(
              color: AppColors.kTextDark,
              fontSize: 16,
              fontWeight: FontWeight.w700)),
    );

    final submitButton = ElevatedButton.icon(
      onPressed: _saving ? null : _submit,
      icon: _saving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: Colors.white))
          : const Icon(Icons.check_circle_outline, size: 22),
      label: Text('Collect ${_rs(_closing)} & Close',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.kGold,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );

    // Responsive Structure
    if (isTablet) {
      return Row(
        children: [
          Expanded(flex: 2, child: cancelButton),
          const SizedBox(width: 16),
          Expanded(flex: 3, child: submitButton),
        ],
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          submitButton,
          const SizedBox(height: 12),
          cancelButton,
        ],
      );
    }
  }
}