import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

const scanHomeRoute = '/scan-home';

class DishPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  const DishPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20),
            const SizedBox(width: 10),
          ],
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ],
      ),
    ),
  );
}

class DishPreviewNotice extends StatelessWidget {
  final bool preview;
  const DishPreviewNotice({super.key, required this.preview});
  @override
  Widget build(BuildContext context) => preview
      ? Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          color: AppColors.tagBeigeBg,
          child: const Text(
            'Design preview · Sample results, not photo analysis',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textDark,
              height: 1.4,
            ),
          ),
        )
      : const SizedBox.shrink();
}

void returnToScanHome(BuildContext context) {
  Navigator.of(
    context,
  ).popUntil((route) => route.settings.name == scanHomeRoute || route.isFirst);
}
