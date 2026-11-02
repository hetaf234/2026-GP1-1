import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../widgets/app_header.dart';

import '../../widgets/matched_allergen_card.dart';

import '../../theme/app_colors.dart';
import 'dish_capture_screen.dart';
import 'dish_result.dart';
import 'dish_scan_service.dart';
import 'dish_widgets.dart';

class DishResultScreen extends StatelessWidget {
  final DishResult result;
  final Uint8List? imageBytes;
  final List<String> userAllergens;
  final DishScanService scanner;
  final bool preview;
  const DishResultScreen({
    super.key,
    required this.result,
    required this.userAllergens,
    required this.scanner,
    this.imageBytes,
    this.preview = false,
  });

  @override
  Widget build(BuildContext context) {
    // This is a display projection; all original causes stay in result.matches.
    final allergens = <String, Set<String>>{};
    for (final match in result.matches) {
      for (final allergen in match.allergens) {
        allergens.putIfAbsent(allergen, () => <String>{}).add(match.name);
      }
    }
    final hasMatches = allergens.isNotEmpty;
    final statusColor = hasMatches
        ? AppColors.alertRed
        : AppColors.primaryGreen;
    final statusBackground = hasMatches ? AppColors.alertBg : AppColors.sageBg;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: () => returnToScanHome(context)),
            DishPreviewNotice(preview: preview),
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
                          'Your Dish Result',
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
                            child: imageBytes != null
                                ? Image.memory(
                                    imageBytes!,
                                    fit: BoxFit.cover,
                                    cacheWidth: 960,
                                    semanticLabel: 'Your selected dish photo',
                                    errorBuilder: (_, error, stack) =>
                                        _dishPlaceholder(),
                                  )
                                : _dishPlaceholder(),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          result.dishName,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark,
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
                                hasMatches
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
                                      hasMatches
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
                                      hasMatches
                                          ? '${allergens.length} allergen${allergens.length == 1 ? '' : 's'} match${allergens.length == 1 ? 'es' : ''} your registered allergies.'
                                          : 'No allergens matching your registered allergies were identified.',
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
                        if (hasMatches) ...[
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
                              key: ValueKey('dish-allergen-${entry.key}'),
                              allergen: entry.key,
                              ingredients: entry.value.toList(),
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
                          label: 'Scan Another Dish',
                          icon: Icons.photo_camera_outlined,
                          onPressed: () =>
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute<void>(
                                  builder: (_) => DishCaptureScreen(
                                    userAllergens: userAllergens,
                                    scanner: scanner,
                                    preview: preview,
                                  ),
                                ),
                              ),
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

  Widget _dishPlaceholder() => const ColoredBox(
    color: AppColors.sageBg,
    child: Center(
      child: Icon(
        Icons.restaurant_outlined,
        size: 52,
        color: AppColors.primaryGreen,
      ),
    ),
  );
}
