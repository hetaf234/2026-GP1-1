import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../widgets/scan_error_page.dart';
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
      DishScanFailure.lowQuality => lowImageQualityError,
      DishScanFailure.notSingleDish => (
        'Not a Single Dish',
        'Please capture a photo that shows only one dish.',
        const DishPlateIcon(size: 40, color: AppColors.tagOrange),
      ),
      DishScanFailure.unsupportedDish => (
        'Unsupported Dish',
        'This dish is currently not supported.',
        const Icon(Icons.search_off),
      ),
      DishScanFailure.connection => (
        'Connection Error',
        'Unable to complete the scan. Please check your connection and try again.',
        const Icon(Icons.wifi_off_rounded),
      ),
    };
    final retrySame = failure == DishScanFailure.connection;
    return ScanErrorPage(
      title: title,
      message: message,
      icon: icon,
      actionLabel: retrySame ? 'Try Again' : 'Try Another Photo',
      onAction: () => Navigator.of(context).pushReplacement(
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
      onBack: () => returnToScanHome(context),
      notice: DishPreviewNotice(preview: preview),
    );
  }
}
