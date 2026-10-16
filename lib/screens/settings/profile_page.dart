import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_toast.dart';
import '../../widgets/page_header.dart';
import '../../services/auth_api_service.dart';
import '../../widgets/app_upload.dart'; 

class ProfilePage extends StatefulWidget {
  final bool showScaffold;

  const ProfilePage({super.key, this.showScaffold = true});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _nameCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _occupationCtrl = TextEditingController();
  final _aadhaarCtrl = TextEditingController();
  final _panCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  Uint8List? _avatarImageBytes; 
  Uint8List? _storedAvatarBytes; 

  String _email = '';
  String _role = '';
  String _customerId = '';
  String? _memberSince;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _mobileCtrl.dispose();
    _occupationCtrl.dispose();
    _aadhaarCtrl.dispose();
    _panCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final profile = await AuthApiService.instance.getStoredProfile();

      if (profile == null) {
        setState(() {
          _loading = false;
          _loadError = 'No profile found. Please log in again.';
        });
        return;
      }

      _applyProfile(profile);
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError = 'Could not load profile.';
      });
    }
  }

  void _applyProfile(Map<String, dynamic> profile) {
    _nameCtrl.text = (profile['full_name'] ?? '').toString();
    _mobileCtrl.text = (profile['mobile'] ?? '').toString();
    _occupationCtrl.text = (profile['occupation'] ?? '').toString();
    _aadhaarCtrl.text = (profile['aadhaar'] ?? '').toString();
    _panCtrl.text = (profile['pan'] ?? '').toString();
    _addressCtrl.text = (profile['address'] ?? '').toString();

    _email = (profile['email'] ?? '').toString();
    _role = (profile['role'] ?? '').toString();
    _customerId = (profile['customer_id'] ?? '').toString();
    _memberSince = _formatMemberSince(profile['created_at']?.toString());
    _storedAvatarBytes = _decodeAvatar(profile['avatar_url']?.toString());

    setState(() => _loading = false);
  }

  Uint8List? _decodeAvatar(String? avatarUrl) {
    if (avatarUrl == null || avatarUrl.isEmpty) return null;
    final commaIndex = avatarUrl.indexOf(',');
    final base64Part =
        commaIndex == -1 ? avatarUrl : avatarUrl.substring(commaIndex + 1);
    try {
      return base64Decode(base64Part);
    } catch (_) {
      return null;
    }
  }

  String? _formatMemberSince(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return null;
    try {
      final date = DateTime.parse(createdAt);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return 'Member since ${months[date.month - 1]} ${date.year}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _onSave() async {
    setState(() => _saving = true);

    try {
      String? avatarBase64;
      if (_avatarImageBytes != null) {
        avatarBase64 =
            'data:image/jpeg;base64,${base64Encode(_avatarImageBytes!)}';
      }

      final updated = await AuthApiService.instance.updateProfile(
        fullName: _nameCtrl.text.trim(),
        mobile: _mobileCtrl.text.trim(),
        occupation: _occupationCtrl.text.trim(),
        aadhaar: _aadhaarCtrl.text.trim(),
        pan: _panCtrl.text.trim(),
        address: _addressCtrl.text.trim(),
        avatarBase64: avatarBase64, 
      );

      if (!mounted) return;
      _applyProfile(updated);
      _avatarImageBytes = null; 

      ToastService.show(
        title: 'Success',
        message: 'Profile updated successfully',
        type: ToastType.success,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ToastService.show(title: 'Error', message: e.message, type: ToastType.error);
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        title: 'Error',
        message: 'Could not update profile. Try again.',
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // UPDATED: Now uses your AppUpload class instead of building the modal manually
  Future<void> _onPickAvatar() async {
    final pickedFile = await AppUpload.showImagePickerModal(context);
    
    // If user canceled the modal, pickedFile will be null
    if (pickedFile == null || !mounted) return;

    final imageBytes = await pickedFile.readAsBytes();
    if (!mounted) return;

    setState(() => _avatarImageBytes = imageBytes);
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (_loading) {
      content = const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: AppColors.kGoldDark),
        ),
      );
    } else if (_loadError != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
              const SizedBox(height: 16),
              Text(_loadError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.kTextMuted, fontSize: 16)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.kGoldDark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else {
      content = SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 40, top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.showScaffold)
                const PageHeader(
                  title: 'My Profile',
                  subtitle: 'Manage your account details and security',
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ProfileHeaderCard(
                      name: _nameCtrl.text.isEmpty ? 'User' : _nameCtrl.text,
                      email: _email,
                      role: _role.toUpperCase(),
                      memberSince: _memberSince,
                      avatarImageBytes: _avatarImageBytes ?? _storedAvatarBytes,
                      onPickAvatar: _onPickAvatar,
                    ),
                    const SizedBox(height: 24),
                    _ProfileDetailsCard(
                      nameCtrl: _nameCtrl,
                      mobileCtrl: _mobileCtrl,
                      occupationCtrl: _occupationCtrl,
                      aadhaarCtrl: _aadhaarCtrl,
                      panCtrl: _panCtrl,
                      addressCtrl: _addressCtrl,
                      saving: _saving,
                      onSave: _onSave,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!widget.showScaffold) {
      return content;
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: IconButton(
            icon: const Icon(Icons.diamond, color: AppColors.kGoldDark, size: 28),
            tooltip: 'App Logo',
            onPressed: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ),
        title: const Text(
          'My Profile',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.kTextDark,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: content,
    );
  }
}

/// Modern Top card with gradient ring avatar & sleek layout
class _ProfileHeaderCard extends StatelessWidget {
  final String name;
  final String email;
  final String role;
  final String? memberSince;
  final Uint8List? avatarImageBytes;
  final VoidCallback onPickAvatar;

  const _ProfileHeaderCard({
    required this.name,
    required this.email,
    required this.role,
    required this.memberSince,
    required this.avatarImageBytes,
    required this.onPickAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 400;

          final avatar = Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [AppColors.kGoldLight, AppColors.kGoldDark],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Container(
                  width: 90,
                  height: 90,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: ClipOval(
                    child: avatarImageBytes == null
                        ? const Icon(Icons.person, size: 45, color: AppColors.kBorder)
                        : Image.memory(
                            avatarImageBytes!,
                            fit: BoxFit.cover,
                            width: 90,
                            height: 90,
                          ),
                  ),
                ),
              ),
              Positioned(
                right: -4,
                bottom: 0,
                child: GestureDetector(
                  onTap: onPickAvatar,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.kGoldDark,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.kSurface, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.kGoldDark.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ],
          );

          Widget nameEmailRoleBlock({required CrossAxisAlignment align}) {
            return Column(
              crossAxisAlignment: align,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.kTextDark,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(email,
                    style: const TextStyle(fontSize: 14, color: AppColors.kTextMuted)),
                if (memberSince != null) ...[
                  const SizedBox(height: 4),
                  Text(memberSince!,
                      style: const TextStyle(fontSize: 12, color: AppColors.kTextMuted)),
                ],
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.kGoldLight.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.kGoldLight.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.verified, size: 16, color: AppColors.kGoldDark),
                      const SizedBox(width: 6),
                      Text(
                        role,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.kGoldDark,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatar,
                const SizedBox(height: 20),
                nameEmailRoleBlock(align: CrossAxisAlignment.center),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatar,
              const SizedBox(width: 24),
              Expanded(
                child: nameEmailRoleBlock(align: CrossAxisAlignment.start),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Stylish forms with filled backgrounds and floating layout
class _ProfileDetailsCard extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController mobileCtrl;
  final TextEditingController occupationCtrl;
  final TextEditingController aadhaarCtrl;
  final TextEditingController panCtrl;
  final TextEditingController addressCtrl;
  final bool saving;
  final VoidCallback onSave;

  const _ProfileDetailsCard({
    required this.nameCtrl,
    required this.mobileCtrl,
    required this.occupationCtrl,
    required this.aadhaarCtrl,
    required this.panCtrl,
    required this.addressCtrl,
    required this.saving,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 560;
          final fieldWidth =
              isNarrow ? constraints.maxWidth : (constraints.maxWidth - 20) / 2;

          Widget buildTextField({
            required String label,
            required IconData icon,
            required TextEditingController controller,
            String? hint,
            TextInputType? keyboardType,
            int maxLines = 1,
            bool fullWidth = false,
          }) {
            return SizedBox(
              width: fullWidth ? constraints.maxWidth : fieldWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.kTextMuted,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  TextField(
                    controller: controller,
                    keyboardType: keyboardType,
                    maxLines: maxLines,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.kTextDark,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.grey.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      prefixIcon: maxLines > 1
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: 40),
                              child: Icon(icon, size: 22, color: AppColors.kTextMuted),
                            )
                          : Icon(icon, size: 22, color: AppColors.kTextMuted),
                      hintText: hint,
                      hintStyle: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w400),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.1), width: 1),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: AppColors.kGoldDark, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.kGoldLight.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.manage_accounts_outlined,
                        size: 20, color: AppColors.kGoldDark),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Personal Details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.kTextDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 20,
                runSpacing: 20,
                children: [
                  buildTextField(
                    label: 'FULL NAME',
                    icon: Icons.person_outline,
                    controller: nameCtrl,
                  ),
                  buildTextField(
                    label: 'MOBILE NUMBER',
                    icon: Icons.phone_outlined,
                    controller: mobileCtrl,
                    keyboardType: TextInputType.phone,
                  ),
                  buildTextField(
                    label: 'OCCUPATION',
                    icon: Icons.work_outline,
                    controller: occupationCtrl,
                    hint: 'e.g. Manager',
                  ),
                  buildTextField(
                    label: 'AADHAAR',
                    icon: Icons.fingerprint,
                    controller: aadhaarCtrl,
                    hint: '12-digit number',
                    keyboardType: TextInputType.number,
                  ),
                  buildTextField(
                    label: 'PAN',
                    icon: Icons.credit_card_outlined,
                    controller: panCtrl,
                    hint: '10-character code',
                  ),
                  buildTextField(
                    label: 'ADDRESS',
                    icon: Icons.location_on_outlined,
                    controller: addressCtrl,
                    hint: 'House no, street, city, state, PIN code',
                    maxLines: 3,
                    fullWidth: true,
                  ),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: saving ? null : onSave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.kGoldDark,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: saving
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            ),
                            SizedBox(width: 12),
                            Text('Saving changes...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          ],
                        )
                      : const Text('Save Changes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}