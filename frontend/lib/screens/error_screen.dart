import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../widgets/scan_error_page.dart';
import '../services/allergen_scanner_service.dart';
import '../services/allergy_service.dart';
import '../features/dish_scan/dish_widgets.dart';
import 'scanning_screen.dart';
import 'image_capture_screen.dart';

enum ErrorType { labelUnreadable, connectionError, imageBlurry }

class ErrorScreen extends StatelessWidget {
  final ErrorType type;
  final Uint8List imageBytes;
  final List<String> userAllergens;
  final String? userId;
  final AllergenScannerService scannerService;

  static const MethodChannel _channel = MethodChannel(
    'com.example.misbar/image_capture',
  );

  const ErrorScreen({
    super.key,
    required this.type,
    required this.imageBytes,
    required this.userAllergens,
    this.userId,
    required this.scannerService,
  });

  Future<void> _handleRetry(BuildContext context) async {
    final activeAllergens = AllergyService().currentAllergies ?? userAllergens;

    if (type == ErrorType.connectionError) {
      // Re-send the same in-memory image without retaking
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ScanningScreen(
            imageBytes: imageBytes,
            userId: userId,
            userAllergens: activeAllergens,
            scannerService: scannerService,
          ),
        ),
      );
    } else {
      // Re-open camera to take a clearer picture
      try {
        final String? tempPath = await _channel.invokeMethod<String>(
          'openImageCapture',
          {'header': AppHeader.nativeAppearance(context)},
        );

        if (tempPath != null && tempPath.isNotEmpty) {
          final file = File(tempPath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            try {
              await file.delete();
            } catch (_) {}

            if (!context.mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => ImageCaptureScreen(
                  initialImageBytes: bytes,
                  useNativeCapture: true,
                  userId: userId,
                  userAllergens: activeAllergens,
                  scannerService: scannerService,
                ),
              ),
            );
            return;
          }
        }
      } catch (_) {}

      if (!context.mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ImageCaptureScreen(
            userId: userId,
            userAllergens: activeAllergens,
            scannerService: scannerService,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (type == ErrorType.imageBlurry) {
      final (title, message, icon) = lowImageQualityError;
      return ScanErrorPage(
        title: title,
        message: message,
        icon: icon,
        actionLabel: 'Try Another Photo',
        onAction: () => _handleRetry(context),
        onBack: () => Navigator.of(context).pop(),
      );
    }

    final isUnreadable = type == ErrorType.labelUnreadable;
    final iconData = isUnreadable ? Icons.local_offer_outlined : Icons.wifi_off;
    final badgeBg = isUnreadable ? AppColors.tagBeigeBg : AppColors.alertBg;
    final iconColor = isUnreadable
        ? AppColors.tagOrange
        : AppColors.alertSoftRed;
    final titleText = isUnreadable
        ? 'Label Could Not Be Read'
        : 'Connection Error';
    final subtitleText = isUnreadable
        ? 'Ensure even lighting, move closer to the text and keep your camera steady.'
        : 'Unable to complete the scan. Please check your connection and try again.';

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          const Spacer(),

                          // Centered Circular Icon Badge
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: badgeBg,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(iconData, size: 36, color: iconColor),
                          ),
                          const SizedBox(height: 24),

                          // Title
                          Text(
                            titleText,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textDark,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Subtitle
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: Text(
                              subtitleText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),

                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton(
                                onPressed: () => _handleRetry(context),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primaryGreen,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  isUnreadable
                                      ? 'Try Another Photo'
                                      : 'Try Again',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Back to Home
                          TextButton(
                            onPressed: () => returnToScanHome(context),
                            child: const Text(
                              'Back to Home',
                              style: TextStyle(
                                color: AppColors.primaryGreen,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),

                          const Spacer(),
                        ],
                      ),
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
