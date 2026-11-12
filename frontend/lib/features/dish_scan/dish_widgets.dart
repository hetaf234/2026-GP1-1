import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

const scanHomeRoute = '/scan-home';
const _dishPlateDesignSize = 36.0;

class DishPlateIcon extends StatelessWidget {
  final double size;
  final Color color;

  const DishPlateIcon({
    super.key,
    this.size = _dishPlateDesignSize,
    this.color = AppColors.primaryGreen,
  });

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _DishPlatePainter(color));
}

class _DishPlatePainter extends CustomPainter {
  final Color color;

  const _DishPlatePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const center = Offset(_dishPlateDesignSize / 2, _dishPlateDesignSize / 2);
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    canvas.save();
    canvas.scale(size.shortestSide / _dishPlateDesignSize);
    canvas.drawCircle(center, 10, outline);
    canvas.drawCircle(center, 7.5, outline);

    final fork = Path()
      ..moveTo(2, 7)
      ..lineTo(2, 13)
      ..quadraticBezierTo(2, 15.5, 4.5, 15.5)
      ..quadraticBezierTo(7, 15.5, 7, 13)
      ..lineTo(7, 7)
      ..moveTo(4.5, 7)
      ..lineTo(4.5, 29);
    canvas.drawPath(fork, outline);

    final knife = Path()
      ..moveTo(33, 7)
      ..quadraticBezierTo(30, 7, 30, 19)
      ..lineTo(32, 19)
      ..lineTo(32, 29)
      ..quadraticBezierTo(33.5, 30.5, 35, 29)
      ..lineTo(35, 8.5)
      ..quadraticBezierTo(35, 7, 33, 7)
      ..close();
    canvas.drawPath(knife, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DishPlatePainter oldDelegate) =>
      oldDelegate.color != color;
}

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
