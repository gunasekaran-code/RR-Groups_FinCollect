import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Holds a primary mobile number plus up to [maxNumbers] - 1 alternates.
///
/// The primary number is what sign-in resolves, so it is kept apart from the
/// extras — the backend stores those in their own `alt_mobiles` column as
/// digits separated by commas.
class PhoneNumbersController extends ChangeNotifier {
  static const int maxNumbers = 3;

  final TextEditingController primary;
  final List<TextEditingController> alternates;

  PhoneNumbersController({String? primary, List<String> alternates = const []})
      : primary = TextEditingController(text: primary ?? ''),
        alternates = alternates
            .take(maxNumbers - 1)
            .map((n) => TextEditingController(text: n))
            .toList();

  bool get canAdd => 1 + alternates.length < maxNumbers;

  String get primaryNumber => primary.text.trim();

  List<String> get alternateNumbers => alternates
      .map((c) => c.text.trim())
      .where((n) => n.isNotEmpty)
      .toList();

  void add() {
    if (!canAdd) return;
    alternates.add(TextEditingController());
    notifyListeners();
  }

  void removeAt(int index) {
    final removed = alternates.removeAt(index);
    notifyListeners();
    // The field still holds this controller until the rebuild lands.
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  /// Parses `alt_mobiles` as the API sends it: a comma-separated string, or
  /// a list.
  static List<String> parse(dynamic value) {
    if (value == null) return const [];
    final parts = value is List ? value : value.toString().split(',');
    return parts
        .map((p) => p.toString().trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  /// The value to send as `alt_mobiles`; null clears the column.
  static String? encode(List<String> numbers) =>
      numbers.isEmpty ? null : numbers.join(',');

  @override
  void dispose() {
    primary.dispose();
    for (final c in alternates) {
      c.dispose();
    }
    super.dispose();
  }
}

/// Mobile number input with a "+" button that adds alternate numbers (three
/// numbers in all), each validated as a 10-digit mobile number. Must sit
/// inside a [Form] for the validators to run.
class PhoneNumbersField extends StatelessWidget {
  final PhoneNumbersController controller;
  final String label;
  final String primaryHint;

  const PhoneNumbersField({
    super.key,
    required this.controller,
    this.label = 'Mobile',
    this.primaryHint = '10-digit number',
  });

  static final RegExp _mobilePattern = RegExp(r'^[6-9]\d{9}$');

  String? _validatePrimary(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Mobile number is required';
    if (!_mobilePattern.hasMatch(value)) {
      return 'Enter a valid 10-digit mobile number';
    }
    return null;
  }

  String? _validateAlternate(int index, String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Enter the number or remove this field';
    if (!_mobilePattern.hasMatch(value)) {
      return 'Enter a valid 10-digit mobile number';
    }
    final others = [
      controller.primaryNumber,
      for (var i = 0; i < index; i++) controller.alternates[i].text.trim(),
    ];
    if (others.contains(value)) return 'This number is already added';
    return null;
  }

  InputDecoration _decoration(String hint) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: hint,
      counterText: '',
      filled: true,
      fillColor: AppColors.kSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: border(AppColors.kBorder),
      enabledBorder: border(AppColors.kBorder),
      focusedBorder: border(AppColors.kGoldDark, 1.5),
      errorBorder: border(AppColors.kDanger),
      focusedErrorBorder: border(AppColors.kDanger, 1.5),
    );
  }

  Widget _numberField(
    TextEditingController c,
    String hint,
    String? Function(String?) validator,
  ) {
    return TextFormField(
      controller: c,
      validator: validator,
      keyboardType: TextInputType.phone,
      maxLength: 10,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      style: const TextStyle(color: AppColors.kTextDark, fontSize: 14),
      decoration: _decoration(hint),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text.rich(
              TextSpan(
                text: label,
                children: const [
                  TextSpan(
                    text: ' *',
                    style: TextStyle(color: AppColors.kDanger),
                  ),
                ],
              ),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.kTextMuted,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _numberField(
                      controller.primary, primaryHint, _validatePrimary),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Tooltip(
                    message: controller.canAdd
                        ? 'Add alternate number'
                        : 'Up to ${PhoneNumbersController.maxNumbers} numbers',
                    child: OutlinedButton(
                      onPressed: controller.canAdd ? controller.add : null,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: AppColors.kTextDark,
                        side: const BorderSide(color: AppColors.kBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Icon(Icons.add, size: 22),
                    ),
                  ),
                ),
              ],
            ),
            for (var i = 0; i < controller.alternates.length; i++) ...[
              const SizedBox(height: 12),
              Row(
                key: ObjectKey(controller.alternates[i]),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _numberField(
                      controller.alternates[i],
                      'Alternate number ${i + 1}',
                      (v) => _validateAlternate(i, v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      tooltip: 'Remove number',
                      icon: const Icon(Icons.delete_outline,
                          color: AppColors.kDanger),
                      onPressed: () => controller.removeAt(i),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
