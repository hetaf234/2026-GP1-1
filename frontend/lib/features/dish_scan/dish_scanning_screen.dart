import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../widgets/app_header.dart';
import '../../theme/app_colors.dart';
import 'dish_error_screen.dart';
import 'dish_result_screen.dart';
import 'dish_scan_service.dart';
import 'dish_widgets.dart';

class DishScanningScreen extends StatefulWidget {
  final Uint8List? imageBytes;
  final List<String> userAllergens;
  final DishScanService scanner;
  final bool preview;
  const DishScanningScreen({
    super.key,
    required this.imageBytes,
    required this.userAllergens,
    required this.scanner,
    this.preview = false,
  });
  @override
  State<DishScanningScreen> createState() => _DishScanningScreenState();
}

class _DishScanningScreenState extends State<DishScanningScreen> {
  final _stages = <DishScanStage, DishStageStatus>{};
  final _cancellation = DishScanCancellation();
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  void _cancel() {
    _cancelled = true;
    _cancellation.cancel();
    returnToScanHome(context);
  }

  Future<void> _analyze() async {
    try {
      final result = await widget.scanner.analyze(
        widget.imageBytes ?? Uint8List(0),
        cancellation: _cancellation,
        onStage: (update) {
          if (mounted && !_cancelled) {
            setState(() => _stages[update.stage] = update.status);
          }
        },
      );
      if (!mounted || _cancelled) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => DishResultScreen(
            result: result,
            imageBytes: widget.imageBytes,
            userAllergens: widget.userAllergens,
            scanner: widget.scanner,
            preview: widget.preview,
          ),
        ),
      );
    } on DishScanCancelled {
      return;
    } on DishScanException catch (error) {
      _showError(error.reason);
    } catch (_) {
      _showError(DishScanFailure.connection);
    }
  }

  void _showError(DishScanFailure failure) {
    if (!mounted || _cancelled) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DishErrorScreen(
          failure: failure,
          imageBytes: widget.imageBytes,
          userAllergens: widget.userAllergens,
          scanner: widget.scanner,
          preview: widget.preview,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancelled = true;
    _cancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = [
      'Image Received',
      'Identifying Ingredients',
      'Checking Allergens',
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(onBack: _cancel),
            DishPreviewNotice(preview: widget.preview),
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
                          width: 88,
                          height: 88,
                          decoration: const BoxDecoration(
                            color: AppColors.sageBg,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.qr_code_scanner,
                            color: AppColors.primaryGreen,
                            size: 36,
                          ),
                        ),
                        const SizedBox(height: 26),
                        const Text(
                          'Analyzing Your Dish…',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark,
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Identifying ingredients and checking your allergies',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 14,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 26),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: AppColors.chipUnselectedBg,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            children: List.generate(labels.length, (index) {
                              final status =
                                  _stages[DishScanStage.values[index]];
                              final done = status == DishStageStatus.completed;
                              final active = status == DishStageStatus.running;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: done
                                          ? const Icon(
                                              Icons.check,
                                              size: 18,
                                              color: AppColors.primaryGreen,
                                            )
                                          : active
                                          ? const CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: AppColors.primaryGreen,
                                            )
                                          : const Icon(
                                              Icons.circle_outlined,
                                              size: 16,
                                              color: Color(0xFFB6C5BA),
                                            ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        labels[index],
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.4,
                                          color: done || active
                                              ? AppColors.primaryGreen
                                              : AppColors.textMuted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                        const SizedBox(height: 26),
                        TextButton(
                          onPressed: _cancel,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: AppColors.primaryGreen),
                          ),
                        ),
                        const SizedBox(height: 28),
                        const SizedBox(
                          width: 240,
                          child: LinearProgressIndicator(
                            color: AppColors.primaryGreen,
                            backgroundColor: AppColors.sageBg,
                            minHeight: 4,
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
