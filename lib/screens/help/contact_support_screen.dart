import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../theme/confirm_dialog.dart';
import '../../services/NotificationService.dart';

class ContactSupportScreen extends StatefulWidget {
  const ContactSupportScreen({super.key});

  @override
  State<ContactSupportScreen> createState() => _ContactSupportScreenState();
}

class _ContactSupportScreenState extends State<ContactSupportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _subjectCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  String _selectedCategory = 'General Inquiry';
  bool _submitting = false;

  final String _supportPhone = '8825829445';
  final String _supportEmail = 'ramragul197@gmail.com';

  final List<String> _categories = [
    'General Inquiry',
    'Loan & EMI Issue',
    'Collection Agent Support',
    'Chit Fund Setup',
    'Technical / Bug Report',
  ];

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitForm() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _submitting = true);
    try {
      // Lands in every admin's notifications screen.
      await NotificationService.sendSupportRequest(
        category: _selectedCategory,
        subject: _subjectCtrl.text.trim(),
        message: _messageCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Support ticket sent to the admin team!'),
          backgroundColor: AppColors.kGold,
        ),
      );
      Navigator.of(context).pop();
    } on NotificationApiException catch (e) {
      // Customer logins are not allowed to write a notification, so their
      // ticket reaches support by email instead.
      if (e.statusCode == 403 && await _sendByEmailInstead()) return;
      _showSendError(e.message);
    } catch (e) {
      _showSendError(e.toString());
    }
  }

  /// Hands the filled-in form to the device's mail app, pre-addressed to
  /// support. Returns false if no mail app could be opened.
  Future<bool> _sendByEmailInstead() async {
    final launchUri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      query: [
        'subject=${Uri.encodeComponent('[$_selectedCategory] ${_subjectCtrl.text.trim()}')}',
        'body=${Uri.encodeComponent(_messageCtrl.text.trim())}',
      ].join('&'),
    );

    try {
      if (!await launchUrl(launchUri)) return false;
    } catch (_) {
      return false;
    }

    if (!mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Opening your email app to send this to support…'),
        backgroundColor: AppColors.kGold,
      ),
    );
    Navigator.of(context).pop();
    return true;
  }

  void _showSendError(String message) {
    if (!mounted) return;
    setState(() => _submitting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not send your message: $message'),
        backgroundColor: AppColors.kDanger,
      ),
    );
  }

  Future<void> _handlePhoneTap() async {
    final confirm = await AppConfirmDialog.show(
      context: context,
      title: 'Call Support',
      message: 'Do you want to dial +91 $_supportPhone?',
      confirmLabel: 'Call',
      confirmButtonColor: const Color(0xFF4CAF50),
    );

    if (confirm == true) {
      final Uri launchUri = Uri(scheme: 'tel', path: _supportPhone);
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not launch dialer')),
          );
        }
      }
    }
  }

  Future<void> _handleEmailTap() async {
    final confirm = await AppConfirmDialog.show(
      context: context,
      title: 'Email Support',
      message: 'Do you want to send an email to $_supportEmail?',
      confirmLabel: 'Email',
      confirmButtonColor: const Color(0xFF2196F3),
    );

    if (confirm == true) {
      final Uri launchUri = Uri(scheme: 'mailto', path: _supportEmail);
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not launch email app')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      currentRoute: AppRoutes.profile,
      title: 'Contact Support',
      showBackButton: true,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        physics: const BouncingScrollPhysics(),
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 2),
            child: Text(
              'RR Groups · Help Center',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.kTextMuted,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 20),
            child: Text(
              'Contact Support',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.kTextDark,
              ),
            ),
          ),

          // Quick Contact Options Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.kSurface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.kBorder.withOpacity(0.5)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildContactTile(
                    icon: Icons.phone_in_talk_rounded,
                    title: 'Call Us',
                    subtitle: '+91 $_supportPhone',
                    color: const Color(0xFF4CAF50),
                    onTap: _handlePhoneTap,
                  ),
                ),
                Container(
                  height: 40,
                  width: 1,
                  color: AppColors.kBorder.withOpacity(0.5),
                ),
                Expanded(
                  child: _buildContactTile(
                    icon: Icons.email_rounded,
                    title: 'Email',
                    subtitle: _supportEmail,
                    color: const Color(0xFF2196F3),
                    onTap: _handleEmailTap,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Contact Form Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.kSurface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.kBorder.withOpacity(0.5)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Send us a message',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.kTextDark,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Category Dropdown
                  DropdownButtonFormField<String>(
                    initialValue: _selectedCategory,
                    decoration: InputDecoration(
                      labelText: 'Category',
                      labelStyle: const TextStyle(color: AppColors.kTextMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.kBorder.withOpacity(0.6),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.kBorder.withOpacity(0.6),
                        ),
                      ),
                    ),
                    items: _categories.map((cat) {
                      return DropdownMenuItem(
                        value: cat,
                        child: Text(cat, style: const TextStyle(fontSize: 14)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedCategory = val);
                    },
                  ),

                  const SizedBox(height: 16),

                  // Subject Field
                  TextFormField(
                    controller: _subjectCtrl,
                    style: const TextStyle(color: AppColors.kTextDark, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Subject',
                      labelStyle: const TextStyle(color: AppColors.kTextMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.kBorder.withOpacity(0.6),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.kBorder.withOpacity(0.6),
                        ),
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Please enter a subject' : null,
                  ),

                  const SizedBox(height: 16),

                  // Message Field
                  TextFormField(
                    controller: _messageCtrl,
                    maxLines: 4,
                    style: const TextStyle(color: AppColors.kTextDark, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Message',
                      alignLabelWithHint: true,
                      labelStyle: const TextStyle(color: AppColors.kTextMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.kBorder.withOpacity(0.6),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: AppColors.kBorder.withOpacity(0.6),
                        ),
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Please enter your message' : null,
                  ),

                  const SizedBox(height: 20),

                  // Submit Button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _submitForm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.kGold,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppColors.kGold.withOpacity(0.6),
                        disabledForegroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Text(
                              'Submit Ticket',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.kTextDark,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.kTextMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}