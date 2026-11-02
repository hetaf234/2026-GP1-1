import 'dart:typed_data';

import 'dish_result.dart';
import 'dish_progress.dart';
export 'dish_progress.dart';

enum DishScanFailure { lowQuality, notSingleDish, unsupportedDish, connection }

class DishScanException implements Exception {
  final DishScanFailure reason;
  // Internal diagnostics only. Error screens display the fixed text for reason.
  // SSE can carry an error status inside a successful HTTP stream. Keep both.
  final int? statusCode;
  final int? transportStatusCode;
  final Object? diagnosticDetails;
  final StackTrace? diagnosticStackTrace;
  const DishScanException(
    this.reason, {
    this.statusCode,
    this.transportStatusCode,
    this.diagnosticDetails,
    this.diagnosticStackTrace,
  });
}

class DishScanCancelled implements Exception {
  const DishScanCancelled();
}

abstract interface class DishScanService {
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  });
}
