import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_toast.dart';

class AppUpload {
  static final ImagePicker _picker = ImagePicker();

  /// Opens the modal sheet and returns the selected [XFile] (or null if canceled).
  static Future<XFile?> showImagePickerModal(
    BuildContext context, {
    String title = 'Update Profile Picture',
  }) async {
    final XFile? selectedFile = await showModalBottomSheet<XFile?>(
      context: context,
      backgroundColor: AppColors.kSurface,
      isScrollControlled: true, // 1. Added this to allow dynamic sizing based on content
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 24.0,
              right: 24.0,
              top: 24.0,
              // 2. Added bottom padding to account for system navigation if SafeArea isn't enough
              bottom: MediaQuery.of(context).viewInsets.bottom + 24.0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min, // 3. Ensures it only takes the required height
              children: [
                // Drag Handle
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: AppColors.kBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.kTextDark,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 24),
                
                // Camera Option
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.kGold.withValues(alpha: 0.15),
                    child: const Icon(Icons.photo_camera_rounded, color: AppColors.kGoldDark),
                  ),
                  title: const Text(
                    'Open Camera',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.kTextDark),
                  ),
                  subtitle: const Text(
                    'Take a new picture',
                    style: TextStyle(fontSize: 13, color: AppColors.kTextMuted),
                  ),
                  onTap: () async {
                    try {
                      final XFile? image = await _picker.pickImage(
                        source: ImageSource.camera,
                        imageQuality: 85,
                      );
                      if (context.mounted) {
                        Navigator.pop(context, image);
                      }
                    } catch (e) {
                      if (context.mounted) Navigator.pop(context);
                      ToastService.show(
                        title: 'Camera Error',
                        message: 'Could not access the camera.',
                        type: ToastType.error,
                      );
                    }
                  },
                ),
                
                const SizedBox(height: 8),

                // Gallery Option
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.kGold.withValues(alpha: 0.15),
                    child: const Icon(Icons.image_rounded, color: AppColors.kGoldDark),
                  ),
                  title: const Text(
                    'Upload Image',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.kTextDark),
                  ),
                  subtitle: const Text(
                    'Choose from your gallery',
                    style: TextStyle(fontSize: 13, color: AppColors.kTextMuted),
                  ),
                  onTap: () async {
                    try {
                      final XFile? image = await _picker.pickImage(
                        source: ImageSource.gallery,
                        imageQuality: 85,
                      );
                      if (context.mounted) {
                        Navigator.pop(context, image);
                      }
                    } catch (e) {
                      if (context.mounted) Navigator.pop(context);
                      ToastService.show(
                        title: 'Gallery Error',
                        message: 'Could not access the gallery.',
                        type: ToastType.error,
                      );
                    }
                  },
                ),
                
                const SizedBox(height: 24),
                
                // Cancel Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.kTextMuted,
                      side: BorderSide(color: AppColors.kBorder.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('Cancel', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selectedFile != null) {
      ToastService.show(
        title: 'Image Selected',
        message: 'Profile picture updated successfully.',
        type: ToastType.success,
      );
    }

    return selectedFile;
  }
}