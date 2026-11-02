import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../services/allergen_scanner_service.dart';
import 'scan_result_screen.dart';
import 'error_screen.dart';

class ScanningScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final List<String> userAllergens;
  final String? userId;
  final AllergenScannerService scannerService;

  const ScanningScreen({
    super.key,
    required this.imageBytes,
    required this.userAllergens,
    this.userId,
    required this.scannerService,
  });

  @override
  State<ScanningScreen> createState() => _ScanningScreenState();
}

class _ScanningScreenState extends State<ScanningScreen> {
  bool _scanStarted = false;
  final _stages = <LabelScanStage, LabelStageStatus>{};
  bool _cancelled = false;
  bool _scanFinished = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    if (_scanStarted) return;
    _scanStarted = true;

    try {
      final user = FirebaseAuth.instance.currentUser;
      final initialUid = user?.uid;
      final uid = widget.userId ?? initialUid;
      final token = await user?.getIdToken(true);

      if (!mounted || _cancelled) return;
      if (FirebaseAuth.instance.currentUser?.uid != initialUid) {
        throw ScanCancelledException();
      }

      final result = await widget.scannerService.scanImageBytes(
        widget.imageBytes,
        userId: uid,
        authToken: token,
        onProgress: (update) {
          if (mounted && !_cancelled) {
            setState(() => _stages[update.stage] = update.status);
          }
        },
      );

      if (!mounted || _cancelled) return;

      if (result.hasContentError) {
        final ErrorType errorType = result.isLowQuality
            ? ErrorType.imageBlurry
            : ErrorType.labelUnreadable;

        String? title;
        if (result.isLowQuality && result.errorTitle != null) {
          title = result.errorTitle!.split('/')[0].trim();
        }

        String? message;
        if (result.isLowQuality && result.message != null) {
          message = result.message!.split('/')[0].trim();
        }

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ErrorScreen(
              type: errorType,
              imageBytes: widget.imageBytes,
              userId: widget.userId,
              userAllergens: widget.userAllergens,
              scannerService: widget.scannerService,
              customTitle: title,
              customMessage: message,
            ),
          ),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ScanResultScreen(
              result: result,
              imageBytes: widget.imageBytes,
              userId: widget.userId,
              userAllergens: widget.userAllergens,
              scannerService: widget.scannerService,
            ),
          ),
        );
      }
    } on LabelScanException catch (error) {
      if (!mounted || _cancelled) return;
      final lowQuality = error.code == 'low_quality';
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ErrorScreen(
            type: lowQuality
                ? ErrorType.imageBlurry
                : error.isContentError
                ? ErrorType.labelUnreadable
                : ErrorType.connectionError,
            imageBytes: widget.imageBytes,
            userId: widget.userId,
            userAllergens: widget.userAllergens,
            scannerService: widget.scannerService,
            customTitle: lowQuality ? 'Image Not Clear' : null,
            customMessage: lowQuality
                ? 'Please retake the label photo in good lighting and keep the camera steady.'
                : null,
          ),
        ),
      );
    } on ScanCancelledException {
      debugPrint(
        '[ScanningScreen] Active scan result cancelled due to preference mutation.',
      );
      return;
    } catch (_) {
      debugPrint('[ScanningScreen] Label scan could not complete.');
      if (!mounted || _cancelled) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ErrorScreen(
            type: ErrorType.connectionError,
            imageBytes: widget.imageBytes,
            userId: widget.userId,
            userAllergens: widget.userAllergens,
            scannerService: widget.scannerService,
          ),
        ),
      );
    } finally {
      _scanFinished = true;
    }
  }

  void _cancelScan() {
    _cancelled = true;
    widget.scannerService.cancelCurrentScan();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _cancelled = true;
    if (!_scanFinished) widget.scannerService.cancelCurrentScan();
    super.dispose();
  }

  Widget _buildStage(LabelScanStage stage) {
    final status = _stages[stage] ?? LabelStageStatus.pending;
    final text = switch (status) {
      LabelStageStatus.pending => 'Pending',
      LabelStageStatus.started => 'Processing',
      LabelStageStatus.completed => 'Completed',
    };
    final color = status == LabelStageStatus.pending
        ? AppColors.textMuted
        : AppColors.primaryGreen;
    return Semantics(
      key: ValueKey('label-stage-${stage.id}'),
      liveRegion: true,
      label: '${stage.label}, $text',
      child: ExcludeSemantics(
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: status == LabelStageStatus.started
                  ? SizedBox(
                      key: ValueKey('${stage.id}-started'),
                      width: 20,
                      height: 20,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: AppColors.primaryGreen,
                      ),
                    )
                  : Icon(
                      status == LabelStageStatus.completed
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked,
                      key: ValueKey('${stage.id}-${status.name}'),
                      size: 20,
                      color: color,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stage.label,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(text, style: TextStyle(fontSize: 12, color: color)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: _cancelScan),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        Container(
                          width: 100,
                          height: 100,
                          decoration: const BoxDecoration(
                            color: AppColors.sageBg,
                            shape: BoxShape.circle,
                          ),
                          child: const Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.document_scanner_outlined,
                                size: 38,
                                color: AppColors.primaryGreen,
                              ),
                              SizedBox(
                                width: 86,
                                height: 86,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: AppColors.primaryGreen,
                                  semanticsLabel: 'Label scan in progress',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'Analyzing Your Label',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textDark,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Checking image quality, reading ingredients and comparing them with your saved allergies.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: AppColors.chipUnselectedBg,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              for (final stage in LabelScanStage.values) ...[
                                if (stage.index > 0) const SizedBox(height: 18),
                                _buildStage(stage),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextButton(
                          onPressed: _cancelScan,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: AppColors.textDark,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
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
}
