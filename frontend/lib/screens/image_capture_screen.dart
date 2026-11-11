import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../features/dish_scan/dish_widgets.dart';
import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../services/allergen_scanner_service.dart';
import '../services/allergy_service.dart';
import 'scanning_screen.dart';

class ImageCaptureScreen extends StatefulWidget {
  final List<String> userAllergens;
  final String? userId;
  final AllergenScannerService scannerService;
  final Uint8List? initialImageBytes;
  final bool useNativeCapture;

  const ImageCaptureScreen({
    super.key,
    required this.userAllergens,
    this.userId,
    required this.scannerService,
    this.initialImageBytes,
    this.useNativeCapture = false,
  });

  @override
  State<ImageCaptureScreen> createState() => _ImageCaptureScreenState();
}

class _ImageCaptureScreenState extends State<ImageCaptureScreen>
    with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  bool _isPickingImage = false;
  bool _isStartingScan = false;
  Uint8List? _imageBytes;
  static const _channel = MethodChannel('com.example.misbar/image_capture');
  late final AnimationController _scanAnimationController;
  late final Animation<double> _scanAnimation;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.initialImageBytes;
    _scanAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (_imageBytes == null) _scanAnimationController.repeat(reverse: true);

    _scanAnimation = Tween<double>(begin: 0.12, end: 0.88).animate(
      CurvedAnimation(
        parent: _scanAnimationController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _scanAnimationController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_isPickingImage || _isStartingScan) return;
    setState(() => _isPickingImage = true);
    try {
      final XFile? photo = await _picker.pickImage(
        source: source,
        // Keep original label data for OCR; previewing never transforms it.
      );

      if (photo != null) {
        final bytes = await photo.readAsBytes();

        // Immediately delete temporary cache file for user privacy
        try {
          await File(photo.path).delete();
        } catch (_) {}

        if (!mounted) return;

        _showPreview(bytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not access image: $e')));
      }
    } finally {
      if (mounted) setState(() => _isPickingImage = false);
    }
  }

  void _showPreview(Uint8List bytes) {
    _scanAnimationController.stop();
    setState(() => _imageBytes = bytes);
  }

  Future<void> _pickNativeImage(ImageSource source) async {
    if (_isPickingImage || _isStartingScan) return;
    setState(() => _isPickingImage = true);
    try {
      final path = await _channel.invokeMethod<String>('openImageCapture', {
        'header': AppHeader.nativeAppearance(context),
        'source': source.name,
      });
      if (path == null || path.isEmpty) return;
      final file = File(path);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      if (!mounted) return;
      _showPreview(bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not access image. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPickingImage = false);
    }
  }

  Future<void> _replaceImage(ImageSource source) =>
      widget.useNativeCapture ? _pickNativeImage(source) : _pickImage(source);

  void _analyze() {
    final bytes = _imageBytes;
    if (bytes == null ||
        _isPickingImage ||
        _isStartingScan ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() => _isStartingScan = true);
    final activeAllergens =
        AllergyService().currentAllergies ?? widget.userAllergens;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ScanningScreen(
          imageBytes: bytes,
          userId: widget.userId,
          userAllergens: activeAllergens,
          scannerService: widget.scannerService,
        ),
      ),
    );
  }

  Widget _buildPreview(Uint8List bytes) {
    final busy = _isPickingImage || _isStartingScan;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const AppHeader(),
            Expanded(
              child: ColoredBox(
                color: AppColors.darkGreen,
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 50,
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          children: [
                            const Text(
                              'Scan Your Label',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'One label. A clear photo.',
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
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: Image.memory(
                                        bytes,
                                        // Match the dish's display crop only;
                                        // upload still uses the original bytes.
                                        fit: BoxFit.cover,
                                        semanticLabel: 'Selected label photo',
                                        errorBuilder: (_, error, stack) =>
                                            const Center(
                                              child: Text(
                                                'This photo cannot be displayed.\nPlease choose another.',
                                                textAlign: TextAlign.center,
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
                            const Text(
                              'Ready to check this label against your allergies?',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                height: 1.7,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 28),
                            DishPrimaryButton(
                              label: 'Analyze Label',
                              icon: Icons.search,
                              onPressed: busy ? null : _analyze,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                Expanded(
                                  child: _LabelPhotoButton(
                                    icon: Icons.photo_camera_outlined,
                                    label: 'Retake Photo',
                                    onPressed: busy
                                        ? null
                                        : () =>
                                              _replaceImage(ImageSource.camera),
                                  ),
                                ),
                                Expanded(
                                  child: _LabelPhotoButton(
                                    icon: Icons.photo_library_outlined,
                                    label: 'Upload Image',
                                    onPressed: busy
                                        ? null
                                        : () => _replaceImage(
                                            ImageSource.gallery,
                                          ),
                                  ),
                                ),
                              ],
                            ),
                            if (_isPickingImage)
                              const Padding(
                                padding: EdgeInsets.only(top: 16),
                                child: LinearProgressIndicator(
                                  color: Color(0xFFE5B869),
                                ),
                              ),
                            const SizedBox(height: 12),
                          ],
                        ),
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

  @override
  Widget build(BuildContext context) {
    final image = _imageBytes;
    if (image != null) return _buildPreview(image);
    const Color darkGreenBg = Color(0xFF1E3526);
    const Color amberGold = Color(0xFFE5B869);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Top White Header with Back button & Misbar logo
            AppHeader(onBack: () => Navigator.of(context).pop()),

            // Main Dark Green Camera Viewfinder Body
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Container(
                        width: double.infinity,
                        decoration: const BoxDecoration(color: darkGreenBg),
                        child: Column(
                          children: [
                            const SizedBox(height: 18),

                            // Title
                            const Text(
                              'Scan Packed Label',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),

                            const Spacer(flex: 2),

                            // Viewfinder Box
                            Center(
                              child: SizedBox(
                                width: 260,
                                height: 200,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    // Custom Corner Brackets
                                    CustomPaint(
                                      size: const Size(260, 200),
                                      painter: _ViewfinderPainter(
                                        color: amberGold,
                                      ),
                                    ),

                                    // Center Tag Icon
                                    const Icon(
                                      Icons.local_offer_outlined,
                                      color: amberGold,
                                      size: 52,
                                    ),

                                    // Animated Laser Scanning Line
                                    AnimatedBuilder(
                                      animation: _scanAnimation,
                                      builder: (context, child) {
                                        return Positioned(
                                          top: 200 * _scanAnimation.value,
                                          left: 12,
                                          right: 12,
                                          child: Container(
                                            height: 3,
                                            decoration: BoxDecoration(
                                              color: amberGold,
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: amberGold.withValues(
                                                    alpha: 0.7,
                                                  ),
                                                  blurRadius: 8,
                                                  spreadRadius: 2,
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(height: 24),

                            // Instruction Subtitle
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 40),
                              child: Text(
                                'Waiting for the label — position it in the frame, then tap Take Photo',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ),

                            const Spacer(flex: 3),

                            // Match the Dish Scan's camera and gallery actions.
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: 36,
                                left: 24,
                                right: 24,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  Expanded(
                                    child: _LabelPhotoButton(
                                      icon: Icons.photo_camera_outlined,
                                      label: 'Take Photo',
                                      primary: true,
                                      onPressed: _isPickingImage
                                          ? null
                                          : () =>
                                                _pickImage(ImageSource.camera),
                                    ),
                                  ),
                                  Expanded(
                                    child: _LabelPhotoButton(
                                      icon: Icons.photo_library_outlined,
                                      label: 'Upload Image',
                                      onPressed: _isPickingImage
                                          ? null
                                          : () =>
                                                _pickImage(ImageSource.gallery),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
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

// Same photo-action geometry as the dish preview, with label-only callbacks.
class _LabelPhotoButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  const _LabelPhotoButton({
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

/// Custom painter for the 4 golden viewfinder corner brackets
class _ViewfinderPainter extends CustomPainter {
  final Color color;

  _ViewfinderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerLength = 32.0;

    // Top-Left corner
    canvas.drawLine(const Offset(0, 0), const Offset(cornerLength, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(0, cornerLength), paint);

    // Top-Right corner
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width - cornerLength, 0),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, cornerLength),
      paint,
    );

    // Bottom-Left corner
    canvas.drawLine(
      Offset(0, size.height),
      Offset(cornerLength, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(0, size.height - cornerLength),
      paint,
    );

    // Bottom-Right corner
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - cornerLength, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - cornerLength),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
