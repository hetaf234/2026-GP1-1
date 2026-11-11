import 'package:flutter/material.dart';

import '../features/dish_scan/dish_widgets.dart';
import '../theme/app_colors.dart';
import 'app_header.dart';

const lowImageQualityError = (
  'Low Image Quality',
  'Image quality is insufficient. Please retake the photo.',
  Icons.blur_on,
);

class ScanErrorPage extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onBack;
  final Widget? notice;

  const ScanErrorPage({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    required this.actionLabel,
    required this.onAction,
    required this.onBack,
    this.notice,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: onBack),
            if (notice != null) notice!,
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
                          label: actionLabel,
                          onPressed: onAction,
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
