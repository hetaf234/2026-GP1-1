import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../widgets/app_header.dart';

import '../widgets/matched_allergen_card.dart';

import '../theme/app_colors.dart';
import '../features/dish_scan/dish_widgets.dart';
import '../models/scan_result.dart';
import '../services/allergen_scanner_service.dart';
import '../services/allergy_service.dart';
import 'image_capture_screen.dart';

class ScanResultScreen extends StatelessWidget {
  final ScanResult result;
  final Uint8List imageBytes;
  final List<String> userAllergens;
  final String? userId;
  final AllergenScannerService scannerService;

  static const MethodChannel _channel = MethodChannel(
    'com.example.misbar/image_capture',
  );

  const ScanResultScreen({
    super.key,
    required this.result,
    required this.imageBytes,
    required this.userAllergens,
    this.userId,
    required this.scannerService,
  });

  static String capitalize(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed[0].toUpperCase() + trimmed.substring(1);
  }

  Future<void> _scanAnother(BuildContext context) async {
    final activeAllergens = AllergyService().currentAllergies ?? userAllergens;

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

  @override
  Widget build(BuildContext context) {
    final detections = result.allergensDetected
        .where((e) => e.isUserAllergen)
        .toList();
    final hasMatches = detections.isNotEmpty;
    final comparisonComplete =
        result.success &&
        result.status == 'completed' &&
        userAllergens.isNotEmpty &&
        userAllergens.every(
          (value) =>
              AllergenDetection.categories.any((item) => item.name == value),
        ) &&
        result.allergensDetected.every(
          (value) => AllergenDetection.categories.any(
            (item) => item.name == value.allergen,
          ),
        ) &&
        detections.every((value) => userAllergens.contains(value.allergen)) &&
        result.isSafe == !hasMatches;
    final statusColor = !comparisonComplete || hasMatches
        ? AppColors.alertRed
        : AppColors.primaryGreen;
    final statusBackground = !comparisonComplete || hasMatches
        ? AppColors.alertBg
        : AppColors.sageBg;

    // Group returned links for display only; keep the response/evidence intact.
    final allergens = <String, Set<String>>{};
    for (final detection in detections) {
      allergens
          .putIfAbsent(detection.allergen, () => <String>{})
          .addAll(detection.matchedIngredients);
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your Label Result',
                          style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark,
                          ),
                        ),
                        const SizedBox(height: 18),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: SizedBox(
                            width: double.infinity,
                            height: 160,
                            child: imageBytes.isNotEmpty
                                ? Image.memory(
                                    imageBytes,
                                    fit: BoxFit.cover,
                                    cacheWidth: 960,
                                    semanticLabel: 'Your selected label photo',
                                    errorBuilder: (_, error, stack) =>
                                        _labelPlaceholder(),
                                  )
                                : _labelPlaceholder(),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: statusBackground,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                !comparisonComplete || hasMatches
                                    ? Icons.error_outline
                                    : Icons.info_outline,
                                color: statusColor,
                                size: 25,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      !comparisonComplete
                                          ? 'Analysis Incomplete'
                                          : hasMatches
                                          ? 'Matching Allergens Found'
                                          : 'No Matching Allergens',
                                      style: TextStyle(
                                        color: statusColor,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      !comparisonComplete
                                          ? 'Could not confirm the allergen comparison. Please try again.'
                                          : !hasMatches
                                          ? 'No allergens matching your registered allergies were identified.'
                                          : '${allergens.length} allergen${allergens.length == 1 ? '' : 's'} match${allergens.length == 1 ? 'es' : ''} your registered allergies.',
                                      style: TextStyle(
                                        color: statusColor,
                                        fontSize: 14,
                                        height: 1.6,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (comparisonComplete && allergens.isNotEmpty) ...[
                          const SizedBox(height: 28),
                          const Text(
                            'Ingredients Matching Your Allergies',
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDark,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...allergens.entries.map(
                            (entry) => MatchedAllergenCard(
                              key: ValueKey('label-allergen-${entry.key}'),
                              allergen: entry.key,
                              ingredients: entry.value.map(capitalize).toList(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        const SizedBox(
                          width: double.infinity,
                          child: Text(
                            'Misbar can make mistakes. Verify before eating.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        DishPrimaryButton(
                          label: 'Scan Another Label',
                          icon: Icons.photo_camera_outlined,
                          onPressed: () => _scanAnother(context),
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: TextButton(
                            onPressed: () => returnToScanHome(context),
                            child: const Text(
                              'Back to Home',
                              style: TextStyle(color: AppColors.primaryGreen),
                            ),
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

  Widget _labelPlaceholder() => const ColoredBox(
    color: AppColors.sageBg,
    child: Center(
      child: Icon(
        Icons.local_offer_outlined,
        size: 52,
        color: AppColors.primaryGreen,
      ),
    ),
  );
}
