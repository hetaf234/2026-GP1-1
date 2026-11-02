import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// All application screens use the signed-in Home header's geometry and art.
/// Screens own their SafeArea and callbacks; this widget never reads auth state.
class AppHeader extends StatelessWidget {
  static const padding = EdgeInsets.fromLTRB(24, 12, 24, 16);
  static const contentHeight = 99.0;
  static const logoSize = Size(94, 72);
  static const logoArtworkSize = 280.0;
  static const logoDecodeSize = 840;
  static const gap = 12.0;
  static const actionSize = 48.0;
  static const actionIconSize = 26.0;
  static const actionRadius = 16.0;
  static const logoAsset = 'assets/images/misbar_logo.png';

  static double _contentScale(BuildContext context) =>
      math.max(1.0, MediaQuery.textScalerOf(context).scale(20) / 20);

  /// The Android capture view renders this same design, without its own sizes.
  static Map<String, Object> nativeAppearance(BuildContext context) => {
    'contentHeight': contentHeight * _contentScale(context),
    'paddingLeft': padding.left,
    'paddingTop': padding.top,
    'paddingRight': padding.right,
    'paddingBottom': padding.bottom,
    'logoWidth': logoSize.width,
    'logoHeight': logoSize.height,
    'logoArtworkSize': logoArtworkSize,
    'logoDecodeSize': logoDecodeSize,
    'logoAsset': logoAsset,
    'actionSize': actionSize,
    'actionIconSize': actionIconSize,
    'actionRadius': actionRadius,
    'backgroundColor': Colors.white.toARGB32(),
    'actionBackgroundColor': AppColors.chipUnselectedBg.toARGB32(),
    'foregroundColor': AppColors.primaryGreen.toARGB32(),
    'rightToLeft': Directionality.of(context) == TextDirection.rtl,
  };

  final VoidCallback? onBack;
  final bool showBack;
  final Widget? leading;
  final VoidCallback? onLogout;
  final Key? logoutKey;

  const AppHeader({
    super.key,
    this.onBack,
    this.showBack = true,
    this.leading,
    this.onLogout,
    this.logoutKey,
  });

  @override
  Widget build(BuildContext context) {
    // Reserve the same left-hand space on every screen. At larger text sizes,
    // grow every header equally so Home's greeting/actions remain accessible.
    final scale = _contentScale(context);
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: padding,
        child: SizedBox(
          height: contentHeight * scale,
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child:
                      leading ??
                      (onLogout != null
                          ? _action(
                              key: logoutKey,
                              tooltip: 'Log Out',
                              icon: Icons.logout_rounded,
                              onPressed: onLogout!,
                            )
                          : showBack
                          ? _action(
                              tooltip: 'Back',
                              icon: Icons.chevron_left,
                              onPressed:
                                  onBack ??
                                  () => Navigator.of(context).maybePop(),
                            )
                          : const SizedBox.shrink()),
                ),
              ),
              const SizedBox(width: gap),
              const _HeaderLogo(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action({
    Key? key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton.filledTonal(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: AppColors.chipUnselectedBg,
      foregroundColor: AppColors.primaryGreen,
      minimumSize: const Size(actionSize, actionSize),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(actionRadius),
      ),
    ),
    icon: Icon(icon, size: actionIconSize),
  );
}

class _HeaderLogo extends StatelessWidget {
  const _HeaderLogo();

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('app-header-logo'),
    width: AppHeader.logoSize.width,
    height: AppHeader.logoSize.height,
    // Draw the same central crop directly into its viewport. Avoid painting an
    // oversized child outside its layout bounds during route transitions.
    child: Image.asset(
      AppHeader.logoAsset,
      width: AppHeader.logoSize.width,
      height: AppHeader.logoSize.height,
      scale: AppHeader.logoDecodeSize / AppHeader.logoArtworkSize,
      cacheWidth: AppHeader.logoDecodeSize,
      cacheHeight: AppHeader.logoDecodeSize,
      fit: BoxFit.none,
      alignment: Alignment.center,
      semanticLabel: 'Misbar',
      errorBuilder: (_, error, stack) => const Text(
        'Misbar',
        style: TextStyle(
          color: AppColors.primaryGreen,
          fontWeight: FontWeight.w800,
          fontSize: 24,
        ),
      ),
    ),
  );
}
