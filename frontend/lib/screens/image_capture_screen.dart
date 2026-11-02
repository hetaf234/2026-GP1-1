import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../services/allergen_scanner_service.dart';
import '../services/allergy_service.dart';
import 'scanning_screen.dart';

class ImageCaptureScreen extends StatefulWidget {
  final List<String> userAllergens;
  final String? userId;
  final AllergenScannerService scannerService;

  const ImageCaptureScreen({
    super.key,
    required this.userAllergens,
    this.userId,
    required this.scannerService,
  });

  @override
  State<ImageCaptureScreen> createState() => _ImageCaptureScreenState();
}

class _ImageCaptureScreenState extends State<ImageCaptureScreen>
    with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  bool _isFlashOn = false;
  bool _isPickingImage = false;
  late final AnimationController _scanAnimationController;
  late final Animation<double> _scanAnimation;

  @override
  void initState() {
    super.initState();
    _scanAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

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
    if (_isPickingImage) return;
    _isPickingImage = true;
    var openedScan = false;
    try {
      final XFile? photo = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );

      if (photo != null) {
        final bytes = await photo.readAsBytes();

        // Immediately delete temporary cache file for user privacy
        try {
          await File(photo.path).delete();
        } catch (_) {}

        if (!mounted) return;

        final activeAllergens =
            AllergyService().currentAllergies ?? widget.userAllergens;

        openedScan = true;
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not access image: $e')));
      }
    } finally {
      if (!openedScan) _isPickingImage = false;
    }
  }

  @override
  Widget build(BuildContext context) {
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
                                'Waiting for the label — position it in the frame, then tap Capture',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ),

                            const Spacer(flex: 3),

                            // Bottom Controls Bar (Flash, Capture, Upload Image)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: 36,
                                left: 30,
                                right: 30,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  // 1. Flash Toggle
                                  Expanded(
                                    child: _buildActionButton(
                                      icon: _isFlashOn
                                          ? Icons.flash_on
                                          : Icons.flash_off,
                                      label: 'Flash',
                                      iconColor: amberGold,
                                      onTap: () {
                                        setState(
                                          () => _isFlashOn = !_isFlashOn,
                                        );
                                      },
                                    ),
                                  ),

                                  // 2. Large Center Capture Button
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () =>
                                          _pickImage(ImageSource.camera),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 76,
                                            height: 76,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 4,
                                              ),
                                            ),
                                            child: Center(
                                              child: Container(
                                                width: 58,
                                                height: 58,
                                                decoration: const BoxDecoration(
                                                  color: AppColors.primaryGreen,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: const Icon(
                                                  Icons.camera_alt_outlined,
                                                  color: Colors.white,
                                                  size: 28,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          const Text(
                                            'Capture',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // 3. Upload Image Button (Gallery)
                                  Expanded(
                                    child: _buildActionButton(
                                      icon: Icons.image_outlined,
                                      label: 'Upload Image',
                                      iconColor: Colors.white,
                                      onTap: () =>
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

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
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
