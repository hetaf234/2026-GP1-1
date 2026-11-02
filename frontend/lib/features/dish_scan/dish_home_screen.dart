import 'package:flutter/material.dart';

import '../../widgets/app_header.dart';
import '../../theme/app_colors.dart';
import 'dish_capture_screen.dart';
import 'dish_scan_service.dart';
import 'dish_http_service.dart';
import 'dish_widgets.dart';

class DishHomeScreen extends StatelessWidget {
  final String displayName;
  final List<String> userAllergens;
  final VoidCallback onScanLabel;
  final VoidCallback onManageAllergies;
  final VoidCallback? onLogout;
  final DishScanService scanner;
  final bool preview;
  final Widget? previewControls;

  const DishHomeScreen({
    super.key,
    required this.displayName,
    required this.userAllergens,
    required this.onScanLabel,
    required this.onManageAllergies,
    this.onLogout,
    this.scanner = const HttpDishScanService(),
    this.preview = false,
    this.previewControls,
  });

  void _openDish(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DishCaptureScreen(
          userAllergens: List.unmodifiable(userAllergens),
          scanner: scanner,
          preview: preview,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8F6),
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Welcome back',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Hi, $displayName!',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textDark,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (onLogout != null)
                    TextButton.icon(
                      onPressed: onLogout,
                      icon: const Icon(Icons.logout_rounded, size: 16),
                      label: const Text('Log Out'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryGreen,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 36),
                      ),
                    ),
                ],
              ),
            ),
            DishPreviewNotice(preview: preview),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGreen,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.restaurant_outlined,
                                color: Color(0xFFE5B869),
                                size: 28,
                              ),
                              SizedBox(height: 18),
                              Text(
                                'Eat Safely Today',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 23,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Scan your food before you eat it.',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'Choose Scan Method',
                          style: TextStyle(
                            color: AppColors.textDark,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _ScanMethodCard(
                          title: 'Scan Dish',
                          subtitle: 'Check a dish against your allergies',
                          icon: Icons.restaurant_outlined,
                          onTap: () => _openDish(context),
                        ),
                        const SizedBox(height: 14),
                        _ScanMethodCard(
                          title: 'Scan Packaged Food Label',
                          subtitle: 'Read ingredient lists on packaging',
                          icon: Icons.local_offer_outlined,
                          onTap: onScanLabel,
                        ),
                        if (preview && previewControls != null) ...[
                          const SizedBox(height: 12),
                          previewControls!,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: ColoredBox(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                const Expanded(
                  child: _HomeDestination(
                    icon: Icons.qr_code_scanner,
                    label: 'Scan',
                    selected: true,
                  ),
                ),
                Expanded(
                  child: _HomeDestination(
                    icon: Icons.person_outline,
                    label: 'My Allergies',
                    onTap: onManageAllergies,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanMethodCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  const _ScanMethodCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.sageBg,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Icon(icon, color: AppColors.primaryGreen, size: 25),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              color: AppColors.primaryGreen,
              size: 24,
            ),
          ],
        ),
      ),
    ),
  );
}

class _HomeDestination extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const _HomeDestination({
    required this.icon,
    required this.label,
    this.selected = false,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(18),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? AppColors.sageBg : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 23, color: AppColors.primaryGreen),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: AppColors.primaryGreen, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
