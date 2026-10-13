import 'dart:ui';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../services/auth_api_service.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  // step 1
  final _step1Key = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _mobileController = TextEditingController();

  // step 2
  final _step2Key = GlobalKey<FormState>();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  int _step = 1; // 1 = request otp, 2 = enter otp + new password
  bool _loading = false;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  String? _error;
  String? _info; // e.g. "Code sent to •••••1234" or demo OTP notice

  @override
  void dispose() {
    _emailController.dispose();
    _mobileController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    if (!_step1Key.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      final res = await AuthApiService.instance.requestOtp(
        email: _emailController.text.trim(),
        mobile: _mobileController.text.trim(),
      );
      setState(() {
        _step = 2;
        final sentTo = res['sent_to'];
        final emailMasked = res['email_masked'];
        _info = 'Code sent to ${sentTo ?? emailMasked ?? 'your registered contact'}.';
        if (res['demo_otp'] != null) {
          _info = '${_info!}\nDemo OTP (no SMS/email provider configured): ${res['demo_otp']}';
        }
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resetPassword() async {
    if (!_step2Key.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthApiService.instance.resetPassword(
        email: _emailController.text.trim(),
        mobile: _mobileController.text.trim(),
        otp: _otpController.text.trim(),
        newPassword: _newPasswordController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. Please sign in.')),
      );
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reads like a native iPhone screen on iOS/macOS — San Francisco instead
    // of the app's usual brand font. No-op on every other platform.
    return AppTheme.withAppleFont(context, _buildScaffold(context));
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.gold100,
              Color(0xFFFCFCFC),
              Colors.white,
              AppColors.gold50,
              AppColors.gold200,
            ],
            stops: [0.0, 0.3, 0.5, 0.8, 1.0],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // iOS-Style Back Button
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: AppColors.kTextDark,
                    size: 20,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),

              // Glass Container Body
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 390),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(36),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(36),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.9),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 30,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Top Lock Badge Icon
                              // Top Logo
Center(
  child: Container(
    width: 88,
    height: 88,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white,
      border: Border.all(color: AppColors.gold100, width: 1.5),
    ),
    child: Center(
      child: ClipOval(
        child: Image.asset(
          'assets/images/logo_app_icon.png',
          fit: BoxFit.cover,
          width: 100,
          height: 100,
          errorBuilder: (context, error, stackTrace) => const Icon(
            Icons.lock_reset_rounded,
            color: AppColors.gold600,
            size: 38,
          ),
        ),
      ),
    ),
  ),
),
                              const SizedBox(height: 20),

                              // Error Banner
                              if (_error != null) ...[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: AppColors.kDanger.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: AppColors.kDanger.withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.error_outline_rounded,
                                        color: AppColors.kDanger,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _error!,
                                          style: const TextStyle(
                                            color: AppColors.kDanger,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],

                              // Info / OTP Banner
                              if (_info != null) ...[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: AppColors.gold100.withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: AppColors.gold400.withValues(alpha: 0.4),
                                    ),
                                  ),
                                  child: Text(
                                    _info!,
                                    style: const TextStyle(
                                      color: AppColors.kTextDark,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],

                              if (_step == 1) _buildStep1() else _buildStep2(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep1() {
    return Form(
      key: _step1Key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Reset Password',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.kTextDark,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter your registered email and mobile number to receive an OTP.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.kTextMuted,
            ),
          ),
          const SizedBox(height: 28),

          // Email Field
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.kTextDark,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: 'Email address',
              hintStyle: TextStyle(
                color: AppColors.kTextMuted.withValues(alpha: 0.6),
                fontSize: 15,
                fontWeight: FontWeight.w400,
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Icon(
                  Icons.mail_outline_rounded,
                  color: AppColors.gold600,
                  size: 22,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 54),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.85),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(
                  color: Colors.black.withValues(alpha: 0.04),
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(
                  color: AppColors.gold500,
                  width: 1.5,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1.5),
              ),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty || !v.contains('@')) ? 'Enter a valid email' : null,
          ),
          const SizedBox(height: 16),

          // Mobile Field
          TextFormField(
            controller: _mobileController,
            keyboardType: TextInputType.phone,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.kTextDark,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: 'Registered mobile number',
              hintStyle: TextStyle(
                color: AppColors.kTextMuted.withValues(alpha: 0.6),
                fontSize: 15,
                fontWeight: FontWeight.w400,
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Icon(
                  Icons.phone_outlined,
                  color: AppColors.gold600,
                  size: 22,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 54),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.85),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(
                  color: Colors.black.withValues(alpha: 0.04),
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(
                  color: AppColors.gold500,
                  width: 1.5,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1.5),
              ),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Mobile number is required' : null,
          ),
          const SizedBox(height: 28),

          // Send OTP Button
          SizedBox(
            height: 54,
            child: ElevatedButton(
              onPressed: _loading ? null : _requestOtp,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold600,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      'SEND OTP',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return Form(
      key: _step2Key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Enter Code',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.kTextDark,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter the 6-digit code sent to your contact.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.kTextMuted,
            ),
          ),
          const SizedBox(height: 28),

          // OTP Field
          TextFormField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              color: AppColors.kTextDark,
              fontWeight: FontWeight.bold,
              letterSpacing: 6.0,
            ),
            decoration: InputDecoration(
              hintText: '000000',
              hintStyle: TextStyle(
                color: AppColors.kTextMuted.withValues(alpha: 0.4),
                fontSize: 20,
                fontWeight: FontWeight.normal,
                letterSpacing: 6.0,
              ),
              counterText: '',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.85),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(
                  color: Colors.black.withValues(alpha: 0.04),
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(
                  color: AppColors.gold500,
                  width: 1.5,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1.5),
              ),
            ),
            validator: (v) =>
                (v == null || v.trim().length != 6) ? 'Enter the 6-digit code' : null,
          ),
          const SizedBox(height: 16),

          // New Password Field
          TextFormField(
            controller: _newPasswordController,
            obscureText: _obscureNew,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.kTextDark,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: 'New password',
              hintStyle: TextStyle(
                color: AppColors.kTextMuted.withValues(alpha: 0.6),
                fontSize: 15,
                fontWeight: FontWeight.w400,
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Icon(
                  Icons.lock_outline_rounded,
                  color: AppColors.gold600,
                  size: 22,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 54),
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  icon: Icon(
                    _obscureNew
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: AppColors.gold600,
                    size: 22,
                  ),
                  onPressed: () => setState(() => _obscureNew = !_obscureNew),
                ),
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.85),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(
                  color: Colors.black.withValues(alpha: 0.04),
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(
                  color: AppColors.gold500,
                  width: 1.5,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1.5),
              ),
            ),
            validator: (v) => (v == null || v.length < 6) ? 'Minimum 6 characters' : null,
          ),
          const SizedBox(height: 16),

          // Confirm Password Field
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: _obscureConfirm,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.kTextDark,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: 'Confirm new password',
              hintStyle: TextStyle(
                color: AppColors.kTextMuted.withValues(alpha: 0.6),
                fontSize: 15,
                fontWeight: FontWeight.w400,
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Icon(
                  Icons.lock_outline_rounded,
                  color: AppColors.gold600,
                  size: 22,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 54),
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  icon: Icon(
                    _obscureConfirm
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: AppColors.gold600,
                    size: 22,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.85),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(
                  color: Colors.black.withValues(alpha: 0.04),
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(
                  color: AppColors.gold500,
                  width: 1.5,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: AppColors.kDanger, width: 1.5),
              ),
            ),
            validator: (v) =>
                (v != _newPasswordController.text) ? 'Passwords do not match' : null,
          ),
          const SizedBox(height: 28),

          // Reset Password Button
          SizedBox(
            height: 54,
            child: ElevatedButton(
              onPressed: _loading ? null : _resetPassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gold600,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      'RESET PASSWORD',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),

          // Back to Step 1
          TextButton(
            onPressed: _loading
                ? null
                : () => setState(() {
                      _step = 1;
                      _error = null;
                      _info = null;
                    }),
            child: const Text(
              'Change email or mobile number',
              style: TextStyle(
                color: AppColors.gold700,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}