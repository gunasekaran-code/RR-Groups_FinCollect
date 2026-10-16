import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../models/agent_collection.dart';

const Color kCollectGold = Color(0xFFA9791F);
const Color kGoldTint = Color(0xFFFBF3E1);

class CollectPaymentSheet extends StatefulWidget {
  final String customerName;
  final String subtitleLabel;
  final String subtitleValue;
  final double prefillAmount;

  /// EMI amount for weekly/monthly-EMI/daily loans, OR the current
  /// month's interest due for a monthly-interest loan.
  final double? installmentAmount;
  final double? dueAmount;
  final double? penaltyAmount;

  /// Full loan balance for weekly/monthly-EMI/daily loans, OR the
  /// remaining principal for a monthly-interest loan.
  final double? outstandingBalance;
  final int? dueCount;

  /// Drives which quick-action buttons and info boxes are shown. This is
  /// the single source of truth for "what kind of collection is this".
  final LoanCollectionType loanCollectionType;

  /// [paymentType] is one of:
  ///  - 'regular'  : normal EMI/dues/penalty/full-balance payment
  ///                 (weekly, monthly EMI, daily loans)
  ///  - 'interest' : monthly-interest loan, pays the month's interest only
  ///                 — must NOT reduce remaining principal
  ///  - 'principal': monthly-interest loan, pays down principal only
  ///                 — must NOT clear the interest due
  ///  - 'full'     : monthly-interest loan, pays interest + principal
  ///
  /// [penaltyAmount] is the part of [amount] that pays penalty. It is
  /// recorded separately and never reduces the EMI/interest due; the rest
  /// of [amount] is applied according to [paymentType].
  final void Function(
    double amount,
    String method,
    DateTime date,
    String? notes,
    String paymentType,
    double penaltyAmount,
  ) onSubmit;

  const CollectPaymentSheet({
    super.key,
    required this.customerName,
    required this.subtitleLabel,
    required this.subtitleValue,
    required this.prefillAmount,
    required this.loanCollectionType,
    this.installmentAmount,
    this.dueAmount,
    this.penaltyAmount,
    this.outstandingBalance,
    this.dueCount,
    required this.onSubmit,
  });

  @override
  State<CollectPaymentSheet> createState() => _CollectPaymentSheetState();
}

class _CollectPaymentSheetState extends State<CollectPaymentSheet> {
  static const List<String> _paymentMethods = [
    'Cash',
    'UPI',
    'Bank Transfer',
    'Cheque',
    'Card',
  ];
  static const Map<String, String> _methodApiValue = {
    'Cash': 'cash',
    'UPI': 'upi',
    'Bank Transfer': 'bank',
    'Cheque': 'cheque',
    'Card': 'card',
  };

  late final TextEditingController _amountController;
  final TextEditingController _notesController = TextEditingController();
  String _paymentMethod = 'Cash';
  DateTime _collectionDate = DateTime.now();

  /// See the doc comment on [CollectPaymentSheet.onSubmit] for the meaning
  /// of each value.
  late String _paymentType;

  /// How much of the amount goes to penalty:
  ///  - 'none': all of it pays the EMI / interest — penalty is untouched
  ///  - 'only': penalty first, anything above it pays the EMI / interest
  ///  - 'with': the dues first, the rest pays penalty
  String _penaltyMode = 'none';

  File? _screenshotFile;
  final ImagePicker _picker = ImagePicker();

  bool _submitting = false;

  bool get _isMonthlyInterest =>
      widget.loanCollectionType == LoanCollectionType.monthlyInterest;

  bool get _isDaily => widget.loanCollectionType == LoanCollectionType.daily;

  /// Weekly, monthly-EMI and monthly-interest loans show a penalty — even
  /// if the backend sends a non-zero `penaltyAmount` for a daily loan, it's
  /// ignored here.
  bool get _appliesPenalty =>
      widget.loanCollectionType == LoanCollectionType.weekly ||
      widget.loanCollectionType == LoanCollectionType.monthlyEmi ||
      widget.loanCollectionType == LoanCollectionType.monthlyInterest;

  @override
  void initState() {
    super.initState();
    if (_isMonthlyInterest) {
      _paymentType = 'interest';
      _amountController = TextEditingController(
        text: _interestDue.round().toString(),
      );
    } else if (_due <= 0 && _penalty > 0) {
      // Every EMI is paid; only the penalty for paying late is left.
      _paymentType = 'regular';
      _penaltyMode = 'only';
      _amountController = TextEditingController(
        text: _penalty.round().toString(),
      );
    } else {
      _paymentType = 'regular';
      _amountController = TextEditingController(
        text: _due.round().toString(),
      );
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  double get _amount => double.tryParse(_amountController.text.trim()) ?? 0;

  double get _emi =>
      widget.installmentAmount != null && widget.installmentAmount! > 0
          ? widget.installmentAmount!
          : (widget.dueAmount ?? widget.prefillAmount);
  double get _due => widget.dueAmount ?? widget.prefillAmount;

  /// Gated by loan type — see [_appliesPenalty].
  double get _penalty => _appliesPenalty ? (widget.penaltyAmount ?? 0) : 0;

  double get _fullBalance => (widget.outstandingBalance ?? _due) + _penalty;

  /// Monthly-interest-only figures.
  double get _interestDue => widget.installmentAmount ?? 0;
  double get _remainingPrincipal => widget.outstandingBalance ?? 0;

  /// What the dues are before any penalty — the interest for a
  /// monthly-interest loan, the overdue EMIs otherwise.
  double get _duesBeforePenalty => _isMonthlyInterest ? _interestDue : _due;

  /// The part of the amount entered that pays penalty (see [_penaltyMode]).
  double get _penaltyPart {
    if (!_appliesPenalty || _penalty <= 0) return 0;
    switch (_penaltyMode) {
      case 'only':
        return _amount < _penalty ? _amount : _penalty;
      case 'with':
        final left = _amount - _duesBeforePenalty;
        if (left <= 0) return 0;
        return left < _penalty ? left : _penalty;
      default:
        return 0;
    }
  }

  bool get _canSave => _amount > 0 && !_submitting;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _collectionDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: kCollectGold,
                ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _collectionDate = picked);
    }
  }

  Future<void> _pickScreenshot() async {
    final source = await _showSourcePicker();
    if (source == null) return;

    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 1600,
    );
    if (picked == null || !mounted) return;

    setState(() => _screenshotFile = File(picked.path));
  }

  Future<ImageSource?> _showSourcePicker() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 48,
              height: 5,
              decoration: BoxDecoration(
                color: AppColors.kBorder,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.kBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.camera_alt_outlined,
                    color: AppColors.kTextDark),
              ),
              title: const Text('Take Photo',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.kBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.photo_library_outlined,
                    color: AppColors.kTextDark),
              ),
              title: const Text('Choose from Gallery',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_canSave) return;
    setState(() => _submitting = true);
    widget.onSubmit(
      _amount,
      _methodApiValue[_paymentMethod] ?? 'cash',
      _collectionDate,
      _notesController.text,
      _paymentType,
      _penaltyPart,
    );
    if (mounted) Navigator.of(context).pop();
  }

  String _formatDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.year}';
  }

  void _setAmount(double amount,
      {String? paymentType, String penaltyMode = 'none'}) {
    _amountController.text = amount.round().toString();
    _amountController.selection = TextSelection.fromPosition(
      TextPosition(offset: _amountController.text.length),
    );
    setState(() {
      if (paymentType != null) _paymentType = paymentType;
      _penaltyMode = penaltyMode;
    });
  }

  InputDecoration _buildInputDecoration({String? hint, String? prefixText}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.kTextMuted.withValues(alpha: 0.8)),
      prefixText: prefixText,
      filled: true,
      fillColor: AppColors.kBackground,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kCollectGold, width: 1.5),
      ),
    );
  }

  Widget _amountAction(
    String label,
    double amount,
    Color bgColor,
    Color textColor, {
    String? paymentType,
    String penaltyMode = 'none',
    String? valueLabel,
    bool selected = false,
  }) {
    return TextButton(
      onPressed: () => _setAmount(amount,
          paymentType: paymentType, penaltyMode: penaltyMode),
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? bgColor.withValues(alpha: 0.85)
              : bgColor,
        ),
        foregroundColor: WidgetStateProperty.all(textColor),
        overlayColor: WidgetStateProperty.all(textColor.withValues(alpha: 0.1)),
        padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: selected
                ? BorderSide(color: textColor, width: 1.5)
                : BorderSide.none,
          ),
        ),
      ),
      child: Text(
        '$label (${valueLabel ?? AgentCollectionItem.formatAmount(amount)})',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }

  /// Builds the quick-action buttons for the current loan type. This is
  /// the "dynamic buttons" piece: the set of buttons (and whether a
  /// penalty button shows at all) is decided here, per loan type, instead
  /// of a single hard-coded list.
  List<Widget> _buildQuickActions() {
    if (_isMonthlyInterest) {
      return [
        _amountAction(
          '⚡ Interest',
          _interestDue,
          const Color(0xFFFFF4D4),
          const Color(0xFF8A5A00),
          paymentType: 'interest',
          selected: _paymentType == 'interest' && _penaltyMode == 'none',
        ),
        if (_penalty > 0) ...[
          _amountAction(
            '⚡ Penalty',
            _penalty,
            const Color(0xFFFDEBEC),
            const Color(0xFFC8103D),
            paymentType: 'interest',
            penaltyMode: 'only',
            selected: _penaltyMode == 'only',
          ),
          _amountAction(
            '⚡ Interest + Penalty',
            _interestDue + _penalty,
            const Color(0xFFF3E8FF),
            const Color(0xFF6B21A8),
            paymentType: 'interest',
            penaltyMode: 'with',
            selected: _penaltyMode == 'with',
          ),
        ],
        _amountAction(
          '💰 Principal (அசல்)',
          _remainingPrincipal,
          const Color(0xFFE7ECFF),
          const Color(0xFF2A3E9C),
          paymentType: 'principal',
          selected: _paymentType == 'principal' && _penaltyMode == 'none',
        ),
        _amountAction(
          '⚡ Full Balance',
          _remainingPrincipal,
          const Color(0xFFE7F7EE),
          const Color(0xFF166534),
          paymentType: 'full',
          selected: _paymentType == 'full' && _penaltyMode == 'none',
        ),
      ];
    }

    return [
      _amountAction(
        '⚡ 1 EMI',
        _emi,
        const Color(0xFFFFF4D4),
        const Color(0xFF8A5A00),
        paymentType: 'regular',
      ),
      _amountAction(
        '⚡ Pay Dues',
        _due,
        const Color(0xFFFDEBEC),
        const Color(0xFFC8103D),
        paymentType: 'regular',
        valueLabel: widget.dueCount != null
            ? '${AgentCollectionItem.formatAmount(_due)} · ${widget.dueCount} Dues'
            : null,
      ),
      // Only shown for weekly/monthly-EMI loans, and only when there's an
      // actual penalty to pay — daily loans never reach here because
      // _appliesPenalty is false for them.
      if (_appliesPenalty && _penalty > 0) ...[
        _amountAction(
          '⚡ Penalty',
          _penalty,
          const Color(0xFFFFEDD5),
          const Color(0xFF9A3412),
          paymentType: 'regular',
          penaltyMode: 'only',
          selected: _penaltyMode == 'only',
        ),
        _amountAction(
          '⚡ Due + Penalty',
          _due + _penalty,
          const Color(0xFFF3E8FF),
          const Color(0xFF6B21A8),
          paymentType: 'regular',
          penaltyMode: 'with',
          selected: _penaltyMode == 'with' && _amount == _due + _penalty,
        ),
      ],
      _amountAction(
        '⚡ Full Balance',
        _fullBalance,
        const Color(0xFFE7F7EE),
        const Color(0xFF166534),
        paymentType: 'regular',
        penaltyMode: 'with',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final keyboardPadding = MediaQuery.of(context).viewInsets.bottom;
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.90;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardPadding),
      // CHANGED: Replaced Center with Align to push the sheet to the bottom
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: Container(
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            decoration: const BoxDecoration(
              color: AppColors.kSurface,
              // This keeps the rounded corners at the top, flat at the bottom
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle bar
                  const SizedBox(height: 12),
                  Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppColors.kBorder,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Collect Payment',
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.5,
                                      color: AppColors.kTextDark)),
                              Container(
                                decoration: const BoxDecoration(
                                  color: AppColors.kBackground,
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.close,
                                      size: 20, color: AppColors.kTextMuted),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: kGoldTint,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: kCollectGold.withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Customer',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFFB58426))),
                                    const SizedBox(height: 2),
                                    Text(widget.customerName,
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.kTextDark)),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(widget.subtitleLabel,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFFB58426))),
                                    const SizedBox(height: 2),
                                    Text(widget.subtitleValue,
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.kTextDark)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Monthly-interest loans get an extra box up top
                          // showing remaining principal + interest due —
                          // there's no single "due amount" concept for them.
                          if (_isMonthlyInterest) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE7ECFF),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: const Color(0xFF2A3E9C)
                                        .withValues(alpha: 0.2)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Remaining Principal:',
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF2A3E9C))),
                                      Text(
                                        AgentCollectionItem.formatAmount(
                                            _remainingPrincipal),
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.kTextDark),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Monthly Interest Due:',
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF2A3E9C))),
                                      Text(
                                        AgentCollectionItem.formatAmount(
                                            _interestDue),
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.kTextDark),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _label('AMOUNT RECEIVED *'),
                                    TextField(
                                      controller: _amountController,
                                      keyboardType: TextInputType.number,
                                      style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.kTextDark),
                                      decoration: _buildInputDecoration(
                                          hint: '0', prefixText: '₹  '),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _label('PAYMENT METHOD'),
                                    DropdownButtonFormField<String>(
                                      isExpanded: true,
                                      initialValue: _paymentMethod,
                                      icon: const Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          color: AppColors.kTextMuted),
                                      decoration: _buildInputDecoration(),
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.kTextDark),
                                      items: _paymentMethods
                                          .map((m) => DropdownMenuItem(
                                              value: m, child: Text(m)))
                                          .toList(),
                                      onChanged: (v) => setState(
                                          () => _paymentMethod = v ?? 'Cash'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _buildQuickActions(),
                          ),
                          // Penalty callout: only weekly/monthly-EMI/
                          // monthly-interest loans can reach this, and only
                          // when there's an actual penalty amount. Daily
                          // loans never show this box.
                          if (_appliesPenalty && _penalty > 0) ...[
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF3DC),
                                border: Border.all(
                                    color: AppColors.kWarning
                                        .withValues(alpha: 0.3)),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.info_outline,
                                      size: 20, color: Color(0xFFB58426)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Penalty Pending: ${AgentCollectionItem.formatAmount(_penalty)}',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF7A4311)),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${_isMonthlyInterest ? 'Interest' : 'Overdue'}: ${AgentCollectionItem.formatAmount(_duesBeforePenalty)} · Total: ${AgentCollectionItem.formatAmount(_duesBeforePenalty + _penalty)}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF7A4311)),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          _penaltyPart > 0
                                              ? 'This payment: ${_isMonthlyInterest ? 'Loan' : 'EMI'} ${AgentCollectionItem.formatAmount(_amount - _penaltyPart)} · Penalty ${AgentCollectionItem.formatAmount(_penaltyPart)}'
                                              : 'Penalty is collected separately — this payment does not reduce it.',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF7A4311)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (!_isMonthlyInterest) ...[
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Text(
                                _isDaily
                                    ? 'Dues Payable: ${AgentCollectionItem.formatAmount(_due)}'
                                    : 'Dues Payable: ${AgentCollectionItem.formatAmount(_due)}${widget.dueCount != null ? ' (${widget.dueCount} Dues)' : ''}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.kTextMuted),
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Text(
                                'Monthly Interest: ${AgentCollectionItem.formatAmount(_interestDue)}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.kTextMuted),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          _label('COLLECTION DATE'),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _pickDate,
                              borderRadius: BorderRadius.circular(12),
                              child: InputDecorator(
                                decoration: _buildInputDecoration(),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _formatDate(_collectionDate),
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.kTextDark),
                                    ),
                                    const Icon(Icons.calendar_month_outlined,
                                        size: 20, color: AppColors.kTextMuted),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          _label('NOTES'),
                          TextField(
                            controller: _notesController,
                            maxLines: 3,
                            style: const TextStyle(
                                fontSize: 15, color: AppColors.kTextDark),
                            decoration: _buildInputDecoration(
                              hint: 'Optional notes about this collection...',
                            ),
                          ),
                          const SizedBox(height: 20),
                          _label('PAYMENT SCREENSHOT (OPTIONAL)'),
                          _UploadBox(
                            icon: Icons.camera_alt_outlined,
                            label: 'Tap to upload screenshot',
                            file: _screenshotFile,
                            onTap: _pickScreenshot,
                          ),
                          const SizedBox(height: 32),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  style: ButtonStyle(
                                    foregroundColor: WidgetStateProperty.all(
                                        AppColors.kTextDark),
                                    backgroundColor:
                                        WidgetStateProperty.resolveWith(
                                      (states) =>
                                          states.contains(WidgetState.hovered)
                                              ? AppColors.kBorder
                                                  .withValues(alpha: 0.3)
                                              : Colors.transparent,
                                    ),
                                    side: WidgetStateProperty.all(
                                        const BorderSide(
                                            color: AppColors.kBorder)),
                                    padding: WidgetStateProperty.all(
                                        const EdgeInsets.symmetric(
                                            vertical: 16)),
                                    shape: WidgetStateProperty.all(
                                      RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                  ),
                                  child: const Text('Cancel',
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: ElevatedButton.icon(
                                  style: ButtonStyle(
                                    backgroundColor:
                                        WidgetStateProperty.resolveWith(
                                      (states) =>
                                          states.contains(WidgetState.hovered)
                                              ? const Color(
                                                  0xFF2E7D32) // Darker green
                                              : AppColors.kSuccess,
                                    ),
                                    foregroundColor:
                                        WidgetStateProperty.all(Colors.white),
                                    elevation: WidgetStateProperty.resolveWith(
                                        (states) =>
                                            states.contains(WidgetState.hovered)
                                                ? 4
                                                : 0),
                                    padding: WidgetStateProperty.all(
                                        const EdgeInsets.symmetric(
                                            vertical: 16)),
                                    shape: WidgetStateProperty.all(
                                      RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                  ),
                                  onPressed: _canSave ? _submit : null,
                                  icon: _submitting
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2))
                                      : const Icon(Icons.receipt_long_outlined,
                                          size: 20),
                                  label: Text(
                                      _submitting
                                          ? 'Saving...'
                                          : 'Generate Receipt',
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.kTextMuted)),
      );
}

class _UploadBox extends StatefulWidget {
  final IconData icon;
  final String label;
  final File? file;
  final VoidCallback onTap;

  const _UploadBox({
    required this.icon,
    required this.label,
    required this.file,
    required this.onTap,
  });

  @override
  State<_UploadBox> createState() => _UploadBoxState();
}

class _UploadBoxState extends State<_UploadBox> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final hasFile = widget.file != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            decoration: BoxDecoration(
              color: hasFile
                  ? const Color(0xFFF0F5FF)
                  : (_isHovered
                      ? AppColors.kBorder.withValues(alpha: 0.3)
                      : AppColors.kBackground),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasFile
                    ? AppColors.kInfo
                    : (_isHovered
                        ? AppColors.kTextMuted.withValues(alpha: 0.5)
                        : AppColors.kBorder),
              ),
            ),
            child: hasFile
                ? Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(widget.file!,
                            height: 100,
                            width: double.infinity,
                            fit: BoxFit.cover),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.edit_outlined,
                              size: 16, color: AppColors.kInfo),
                          const SizedBox(width: 6),
                          Text(
                            'Tap to change image',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.kInfo.withValues(alpha: 0.8),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(widget.icon, color: AppColors.kTextMuted, size: 22),
                      const SizedBox(width: 10),
                      Text(
                        widget.label,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.kTextMuted),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
