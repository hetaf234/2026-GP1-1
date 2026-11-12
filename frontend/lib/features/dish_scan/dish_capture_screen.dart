import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../widgets/app_header.dart';

import 'package:image_picker/image_picker.dart';

import '../../theme/app_colors.dart';
import 'dish_scan_service.dart';
import 'dish_scanning_screen.dart';
import 'dish_widgets.dart';

class DishCaptureScreen extends StatefulWidget {
  final List<String> userAllergens;
  final DishScanService scanner;
  final bool preview;
  const DishCaptureScreen({
    super.key,
    required this.userAllergens,
    required this.scanner,
    this.preview = false,
  });
  @override
  State<DishCaptureScreen> createState() => _DishCaptureScreenState();
}

class _DishCaptureScreenState extends State<DishCaptureScreen> {
  Uint8List? _image;
  bool _picking = false;

  Future<void> _pick(ImageSource source) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final photo = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
        requestFullMetadata: false,
      );
      if (photo == null || !mounted) return;
      final bytes = await photo.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
        _showMessage('Choose a photo smaller than 4 MB.');
        return;
      }
      setState(() => _image = bytes);
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not open the camera or photo library. Check photo permissions and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _analyze({bool sample = false}) {
    final image = _image;
    if (!sample && image == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DishScanningScreen(
          imageBytes: image,
          userAllergens: widget.userAllergens,
          scanner: widget.scanner,
          preview: widget.preview,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            DishPreviewNotice(preview: widget.preview),
            Expanded(
              child: ColoredBox(
                color: AppColors.darkGreen,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight - 50,
                        ),
                        child: IntrinsicHeight(
                          child: Column(
                            children: [
                              const Text(
                                'Scan Your Dish',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'One main dish. A clear photo.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFFD0DED3),
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 32),
                              Expanded(
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 440,
                                    ),
                                    child: AspectRatio(
                                      aspectRatio: 1.15,
                                      child: image == null
                                          ? CustomPaint(
                                              painter: _DishFramePainter(),
                                              child: const Center(
                                                child: DishPlateIcon(
                                                  size: 64,
                                                  color: Color(0xFFE5B869),
                                                ),
                                              ),
                                            )
                                          : ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              child: Image.memory(
                                                image,
                                                fit: BoxFit.cover,
                                                cacheWidth: 960,
                                                semanticLabel:
                                                    'Selected dish photo',
                                                errorBuilder:
                                                    (
                                                      _,
                                                      error,
                                                      stack,
                                                    ) => const Center(
                                                      child: Text(
                                                        'This photo cannot be displayed.\nPlease choose another.',
                                                        textAlign:
                                                            TextAlign.center,
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 28),
                              Text(
                                image == null
                                    ? 'Keep the whole dish in the frame.\nTake a photo or choose one from your gallery.'
                                    : 'Ready to check this dish against your allergies?',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  height: 1.7,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 28),
                              if (image != null) ...[
                                DishPrimaryButton(
                                  label: 'Analyze Dish',
                                  icon: Icons.search,
                                  onPressed: _picking ? null : _analyze,
                                ),
                                const SizedBox(height: 12),
                              ],
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  Expanded(
                                    child: _PhotoButton(
                                      icon: Icons.photo_camera_outlined,
                                      label: image == null
                                          ? 'Take Photo'
                                          : 'Retake Photo',
                                      onPressed: _picking
                                          ? null
                                          : () => _pick(ImageSource.camera),
                                      primary: image == null,
                                    ),
                                  ),
                                  Expanded(
                                    child: _PhotoButton(
                                      icon: Icons.photo_library_outlined,
                                      label: 'Upload Image',
                                      onPressed: _picking
                                          ? null
                                          : () => _pick(ImageSource.gallery),
                                    ),
                                  ),
                                ],
                              ),
                              if (_picking)
                                const Padding(
                                  padding: EdgeInsets.only(top: 16),
                                  child: LinearProgressIndicator(
                                    color: Color(0xFFE5B869),
                                  ),
                                ),
                              if (widget.preview) ...[
                                const SizedBox(height: 18),
                                TextButton(
                                  onPressed: _picking
                                      ? null
                                      : () => _analyze(sample: true),
                                  child: const Text(
                                    'Preview Sample Result',
                                    style: TextStyle(
                                      color: Color(0xFFE5B869),
                                      decoration: TextDecoration.underline,
                                      decorationColor: Color(0xFFE5B869),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  const _PhotoButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.primary = false,
  });
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon, size: primary ? 31 : 25),
        style: IconButton.styleFrom(
          backgroundColor: primary
              ? AppColors.primaryGreen
              : Colors.white.withValues(alpha: 0.09),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white54,
          minimumSize: Size.square(primary ? 72 : 56),
          side: primary
              ? const BorderSide(color: Colors.white, width: 4)
              : BorderSide.none,
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
    ],
  );
}

class _DishFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE5B869)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const inset = 12.0;
    const corner = 28.0;
    for (final offset in [
      const Offset(inset, inset),
      Offset(size.width - inset, inset),
      Offset(inset, size.height - inset),
      Offset(size.width - inset, size.height - inset),
    ]) {
      final dx = offset.dx < size.width / 2 ? corner : -corner;
      final dy = offset.dy < size.height / 2 ? corner : -corner;
      canvas.drawPath(
        Path()
          ..moveTo(offset.dx + dx, offset.dy)
          ..lineTo(offset.dx, offset.dy)
          ..lineTo(offset.dx, offset.dy + dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
