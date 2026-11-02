import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../widgets/app_header.dart';
import '../../theme/app_colors.dart';
import 'dish_capture_screen.dart';
import 'dish_scan_service.dart';
import 'dish_scanning_screen.dart';
import 'dish_widgets.dart';

class DishErrorScreen extends StatelessWidget {
  final DishScanFailure failure;
  final Uint8List? imageBytes;
  final List<String> userAllergens;
  final DishScanService scanner;
  final bool preview;
  const DishErrorScreen({
    super.key,
    required this.failure,
    required this.userAllergens,
    required this.scanner,
    this.imageBytes,
    this.preview = false,
  });

  @override
  Widget build(BuildContext context) {
    final (title, message, icon) = switch (failure) {
      DishScanFailure.lowQuality => (
        'Low Image Quality',
        'Image quality is insufficient. Please retake the photo.',
        Icons.blur_on,
      ),
      DishScanFailure.notSingleDish => (
        'Not a Single Dish',
        'Please capture one food dish only.',
        Icons.restaurant_outlined,
      ),
      DishScanFailure.unsupportedDish => (
        'Unsupported Dish',
        'This dish is currently not supported.',
        Icons.search_off,
      ),
      DishScanFailure.connection => (
        'Connection Error',
        'Unable to complete the scan. Please check your connection and try again.',
        Icons.wifi_off_rounded,
      ),
    };
    final retrySame = failure == DishScanFailure.connection;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => returnToScanHome(context)),
            DishPreviewNotice(preview: preview),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 56,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: const BoxDecoration(
                            color: AppColors.tagBeigeBg,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            icon,
                            color: AppColors.tagOrange,
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 26),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textDark,
                            fontWeight: FontWeight.w700,
                            fontSize: 24,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Text(
                            message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.8,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        DishPrimaryButton(
                          label: retrySame
                              ? 'Try Again'
                              : 'Choose Another Photo',
                          onPressed: () =>
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute<void>(
                                  builder: (_) => retrySame
                                      ? DishScanningScreen(
                                          imageBytes: imageBytes,
                                          userAllergens: userAllergens,
                                          scanner: scanner,
                                          preview: preview,
                                        )
                                      : DishCaptureScreen(
                                          userAllergens: userAllergens,
                                          scanner: scanner,
                                          preview: preview,
                                        ),
                                ),
                              ),
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () => returnToScanHome(context),
                          child: const Text(
                            'Back to Home',
                            style: TextStyle(color: AppColors.primaryGreen),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
