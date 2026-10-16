import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_toast.dart';
import '../../models/account_ledger_model.dart';
import '../../services/account_ledger_service.dart';
import '../../routes/app_routes.dart';
import '../../widgets/app_shell.dart';

class CalculatorQuickEntryScreen extends StatefulWidget {
  final AccountLedgerService service;

  final double currentCashInHand;

  final ValueChanged<AccountLedgerEntry> onSaved;

  const CalculatorQuickEntryScreen({
    super.key,
    required this.service,
    required this.onSaved,
    this.currentCashInHand = 0,
  });

  @override
  State<CalculatorQuickEntryScreen> createState() =>
      _CalculatorQuickEntryScreenState();
}

class _CalculatorQuickEntryScreenState
    extends State<CalculatorQuickEntryScreen> {
  bool _isGot = true;
  String _display = '0';
  double _accumulator = 0;
  String? _pendingOperator;
  bool _waitingForOperand = false;
  double _memory = 0;

  final TextEditingController _noteController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  bool _isSaving = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  double get _currentValue => double.tryParse(_display) ?? 0;

  Color get _modeColor =>
      _isGot ? AppColors.kGoldDark :AppColors.kDanger;
  Color get _modeSoftBg => _isGot ? AppColors.gold50 : const Color(0xFFFFF3E0);

  // ---- Digit / decimal entry ----
  void _inputDigit(String digit) {
    setState(() {
      if (_waitingForOperand) {
        _display = digit;
        _waitingForOperand = false;
      } else {
        _display = _display == '0' ? digit : '$_display$digit';
      }
    });
  }

  void _inputDecimal() {
    setState(() {
      if (_waitingForOperand) {
        _display = '0.';
        _waitingForOperand = false;
      } else if (!_display.contains('.')) {
        _display = '$_display.';
      }
    });
  }

  void _clear() {
    setState(() {
      _display = '0';
      _accumulator = 0;
      _pendingOperator = null;
      _waitingForOperand = false;
    });
  }

  void _backspace() {
    setState(() {
      if (_display.length > 1) {
        _display = _display.substring(0, _display.length - 1);
      } else {
        _display = '0';
      }
    });
  }

  void _percent() {
    setState(() {
      _display = _formatResult(_currentValue / 100);
    });
  }

  void _memoryAdd() => setState(() => _memory += _currentValue);
  void _memorySubtract() => setState(() => _memory -= _currentValue);

  double _calc(double a, double b, String op) {
    switch (op) {
      case '+':
        return a + b;
      case '−':
        return a - b;
      case '×':
        return a * b;
      case '÷':
        return b == 0 ? 0 : a / b;
      default:
        return b;
    }
  }

  String _formatResult(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e12) {
      return v.toInt().toString();
    }
    return v
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  void _onOperator(String op) {
    final input = _currentValue;
    setState(() {
      if (_pendingOperator != null && !_waitingForOperand) {
        _accumulator = _calc(_accumulator, input, _pendingOperator!);
        _display = _formatResult(_accumulator);
      } else {
        _accumulator = input;
      }
      _pendingOperator = op;
      _waitingForOperand = true;
    });
  }

  void _onEquals() {
    if (_pendingOperator == null) return;
    final input = _currentValue;
    final result = _calc(_accumulator, input, _pendingOperator!);
    setState(() {
      _display = _formatResult(result);
      _accumulator = result;
      _pendingOperator = null;
      _waitingForOperand = true;
    });
  }

  // ==========================================
  // DATE PICKER
  // ==========================================
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: AppColors.kGoldDark,
              ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  // ==========================================
  // SAVE — creates an account_ledger row (cash_in / cash_out)
  // ==========================================
  Future<void> _handleSave() async {
    final amount = _currentValue;
    if (amount <= 0) {
      ToastService.show(
        title: 'Enter an amount',
        message: 'Amount must be greater than ₹0.',
        type: ToastType.error,
      );
      return;
    }

    final note = _noteController.text.trim();
    final entry = AccountLedgerEntry(
      id: '',
      entryType: _isGot ? LedgerEntryType.cashIn : LedgerEntryType.cashOut,
      title: note.isEmpty ? (_isGot ? 'Cash In' : 'Cash Out') : note,
      amount: amount,
      category: 'General',
      entryDate: _selectedDate,
      notes: note.isEmpty ? null : note,
    );

    setState(() => _isSaving = true);
    try {
      final saved = await widget.service.createEntry(entry);
      widget.onSaved(saved);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      ToastService.show(
        title: 'Save failed',
        message: e.toString(),
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final newCashInHand =
        widget.currentCashInHand + (_isGot ? _currentValue : -_currentValue);
    final currencyFmt = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );

    return AppShell(
      currentRoute: AppRoutes.accountBook,
      title: 'Quick Calculator',
      showBackButton: true,
      onBack: () => Navigator.of(context).pop(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- YOU GOT / YOU GAVE TOGGLE ----
            Row(
              children: [
                Expanded(
                  child: _buildModeChip(
                    label: 'You got (வரவு)',
                    selected: _isGot,
                    color: AppColors.kGoldDark,
                    onTap: () => setState(() => _isGot = true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildModeChip(
                    label: 'You gave (பற்று)',
                    selected: !_isGot,
                    color: AppColors.kDanger,
                    onTap: () => setState(() => _isGot = false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ---- AMOUNT DISPLAY ----
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _modeColor, width: 1.4),
                color: _modeSoftBg.withValues(alpha: 0.4),
              ),
              child: Row(
                children: [
                  Text('₹',
                      style: TextStyle(
                          color: _modeColor,
                          fontSize: 26,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _display,
                      style: TextStyle(
                        color: _modeColor,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ---- CASH IN HAND PREVIEW ----
            Text(
              'Cash in hand ${currencyFmt.format(widget.currentCashInHand)} → ',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                  children: [
                    TextSpan(
                        text:
                            'Cash in hand ${currencyFmt.format(widget.currentCashInHand)} → '),
                    TextSpan(
                      text: currencyFmt.format(newCashInHand),
                      style: TextStyle(
                          color: _modeColor, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),


            // ---- KEYPAD ----
            _buildKeypad(),
            const SizedBox(height: 16),

            // ---- NOTE ----
            TextField(
              controller: _noteController,
              enabled: !_isSaving,
              decoration: InputDecoration(
                hintText: 'Note (குறிப்பு)',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ---- DATE ----
            InkWell(
              onTap: _isSaving ? null : _pickDate,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today, size: 18, color: _modeColor),
                    const SizedBox(width: 10),
                    Text(
                      DateFormat('dd/MM/yyyy').format(_selectedDate),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            // ---- SAVE BUTTON ----
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _handleSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _modeColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'SAVE',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1),
                      ),
              ),
            ),
            const SizedBox(height: 80),

          ],
        ),
      ),
    );
  }

  Widget _buildModeChip({
    required String label,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? color : const Color(0xFFEFF2F7),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black54,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

Widget _buildKeypad() {
    return Column(
      children: [
        Row(children: [
          _key('C', onTap: _clear, bg: const Color(0xFFEFF2F7)),
          _key('M+', onTap: _memoryAdd, bg: const Color(0xFFEFF2F7)),
          _key('M-', onTap: _memorySubtract, bg: const Color(0xFFEFF2F7)),
          _key(null,
              icon: Icons.backspace_outlined,
              onTap: _backspace,
              bg: const Color(0xFFEFF2F7)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _key('7', onTap: () => _inputDigit('7')),
          _key('8', onTap: () => _inputDigit('8')),
          _key('9', onTap: () => _inputDigit('9')),
          _opKey('÷', onTap: () => _onOperator('÷')),
          
          // Updated to use _opKey for the gold operator styling
          _opKey('%', onTap: _percent), 
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _key('4', onTap: () => _inputDigit('4')),
          _key('5', onTap: () => _inputDigit('5')),
          _key('6', onTap: () => _inputDigit('6')),
          _opKey('×', onTap: () => _onOperator('×')),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _key('1', onTap: () => _inputDigit('1')),
          _key('2', onTap: () => _inputDigit('2')),
          _key('3', onTap: () => _inputDigit('3')),
          _opKey('−', onTap: () => _onOperator('−')),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _key('0', onTap: () => _inputDigit('0')),
          _key('.', onTap: _inputDecimal),
          _key('=', onTap: _onEquals, bg: AppColors.gold50, fg: _modeColor),
          _opKey('+', onTap: () => _onOperator('+')),
        ]),
      ],
    );
  }

  Widget _key(
    String? label, {
    IconData? icon,
    required VoidCallback onTap,
    Color bg = Colors.white,
    Color fg = Colors.black87,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: icon != null
                ? Icon(icon, size: 18, color: fg)
                : Text(
                    label ?? '',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600, color: fg),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _opKey(String label, {required VoidCallback onTap}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.kGoldDark,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
