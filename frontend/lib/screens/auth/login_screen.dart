import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../models/app_user.dart';
import '../../models/user_role.dart';
import '../../routes/app_routes.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../../services/auth_api_service.dart';
import '../../services/api_client.dart' hide ApiException;
import '../../services/branding_service.dart';
import 'forgot_password_screen.dart';

/// Maps the backend's `role` string (Profile.role column) onto the app's
/// UserRole enum. Adjust the string values on the left if your DB stores
/// the role differently (e.g. 'super_admin' instead of 'owner').

UserRole _roleFromString(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'owner':
      return UserRole.owner;
    case 'admin':
      return UserRole.admin;
    case 'agent':
      return UserRole.agent;
    case 'customer':
      return UserRole.customer;
    default:
      return UserRole.agent;
  }
}

String _homeRouteForRole(UserRole role) {
  return AppRoutes.dashboard;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _identifierController = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _identifierController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // AuthApiService.login() saves the token and profile securely. We also
      // translate the profile into your AppUser model
      // and push it into SessionService, so the _guarded() role checks
      // in main.dart work exactly like they did with the static demo users.
      final data = await AuthApiService.instance.login(
        identifier: _identifierController.text.trim(),
        password: _passwordController.text,
      );
      final profile = data['profile'] as Map<String, dynamic>? ?? {};
      final role = _roleFromString(profile['role'] as String?);
      SessionService.instance.login(
        AppUser(
          userId: (profile['id'] ?? '').toString(),
          customerId: profile['customer_id']?.toString(),
          name: (profile['full_name'] as String?)?.trim().isNotEmpty == true
              ? profile['full_name'] as String
              : (profile['email'] ?? 'User').toString(),
          role: role,
          avatarUrl: profile['avatar_url']?.toString(),
        ),
        token: data['token']?.toString(),
      );
      ApiClient.instance.authToken = data['token']?.toString();
      await BrandingService.instance.refreshFromServer();
      if (!mounted) return;
      // main.dart's onGenerateRoute -> _guarded() decides what's actually
      // shown based on this role. Everyone lands on the dashboard first.
      Navigator.of(context).pushNamedAndRemoveUntil(
        _homeRouteForRole(role),
        (route) => false,
      );
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
    // Login reads like a native iPhone screen on iOS/macOS — San Francisco
    // instead of the app's usual brand font. No-op on every other platform.
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
          child: Center(
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
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Header Circle & Title
                            ValueListenableBuilder<AppBranding>(
                              valueListenable: BrandingService.instance.branding,
                              builder: (context, branding, _) => Column(
                                children: [
                                  const _LoginBrandLogo(),
                                  const SizedBox(height: 20),
                                  const Text(
                                    'Welcome Back',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.kTextDark,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    branding.companyName.isNotEmpty
                                        ? branding.companyName
                                        : 'Sign in to continue',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: AppColors.kTextMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 32),

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
                              const SizedBox(height: 20),
                            ],

                            // Identifier Field (Email / Mobile)
                            TextFormField(
                              controller: _identifierController,
                              keyboardType: TextInputType.text,
                              autofillHints: const [AutofillHints.username],
                              style: const TextStyle(
                                fontSize: 15,
                                color: AppColors.kTextDark,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Email',
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
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 54,
                                ),
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.85),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 18,
                                ),
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
                                  borderSide: const BorderSide(
                                    color: AppColors.kDanger,
                                    width: 1,
                                  ),
                                ),
                                focusedErrorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: const BorderSide(
                                    color: AppColors.kDanger,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                              validator: (v) {
                                final value = (v ?? '').trim();
                                if (value.isEmpty) {
                                  return 'Email or mobile number is required';
                                }

                                final isEmail = value.contains('@');
                                if (isEmail) {
                                  final emailRegex =
                                      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
                                  if (!emailRegex.hasMatch(value)) {
                                    return 'Enter a valid email';
                                  }
                                  return null;
                                }

                                final digitsOnly =
                                    value.replaceAll(RegExp(r'\D'), '');
                                if (digitsOnly.length < 10) {
                                  return 'Enter a valid email or 10-digit mobile number';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),

                            // Password Field
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscure,
                              autofillHints: const [AutofillHints.password],
                              style: const TextStyle(
                                fontSize: 15,
                                color: AppColors.kTextDark,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Password',
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
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 54,
                                ),
                                suffixIcon: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: IconButton(
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      color: AppColors.gold600,
                                      size: 22,
                                    ),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.85),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 18,
                                ),
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
                                  borderSide: const BorderSide(
                                    color: AppColors.kDanger,
                                    width: 1,
                                  ),
                                ),
                                focusedErrorBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: const BorderSide(
                                    color: AppColors.kDanger,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                              validator: (v) => (v == null || v.isEmpty)
                                  ? 'Password is required'
                                  : null,
                              onFieldSubmitted: (_) =>
                                  _loading ? null : _submit(),
                            ),
                            const SizedBox(height: 12),

                            // Forgot Password Link
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _loading
                                    ? null
                                    : () => Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const ForgotPasswordScreen(),
                                          ),
                                        ),
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text(
                                  'Forgot password?',
                                  style: TextStyle(
                                    color: AppColors.gold700,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 28),

                            // LOGIN Button
                            SizedBox(
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _loading ? null : _submit,
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
                                        'LOGIN',
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
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginBrandLogo extends StatelessWidget {
  const _LoginBrandLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width:88,
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
            width: 100, // Adjust width and height if needed based on your logo's aspect ratio
            height: 100,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.lock_person_rounded,
              color: AppColors.gold600,
              size: 38,
            ),
          ),
        ),
      ),
    );
  }
}
