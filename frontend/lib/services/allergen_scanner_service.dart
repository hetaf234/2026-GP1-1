import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/scan_result.dart';
import 'api_service.dart';
export 'label_scan_progress.dart';

class ScanCancelledException implements Exception {
  final String message;
  ScanCancelledException([
    this.message = 'Scan was cancelled because newer preferences were applied.',
  ]);
  @override
  String toString() => message;
}

/// AllergenScannerService manages image and text scanning.
/// All user allergy preferences are retrieved strictly from Firestore by the backend.
/// Tracks active scan generations to cancel/discard obsolete in-flight scans.
class AllergenScannerService {
  // Borrowed from the application (or an injecting caller), never owned here.
  final ApiService _apiService;
  int _activeScanId = 0;
  bool _disposed = false;
  LabelScanCancellation? _activeImageCancellation;

  String get baseUrl => _apiService.baseUrl;
  set baseUrl(String url) => _apiService.baseUrl = url;

  AllergenScannerService({
    String? baseUrl,
    http.Client? client,
    ApiService? apiService,
  }) : _apiService = apiService ?? ApiService() {
    if (baseUrl != null) {
      _apiService.baseUrl = baseUrl;
    }
  }

  /// Invalidate/cancel any in-flight scan requests so their responses are discarded.
  void cancelCurrentScan() {
    _activeScanId++;
    _activeImageCancellation?.cancel();
    _activeImageCancellation = null;
  }

  Future<ScanResult> scanImageBytes(
    Uint8List imageBytes, {
    String? userId,
    String? authToken,
    void Function(LabelProgressUpdate)? onProgress,
  }) async {
    if (onProgress == null) {
      return _scan(() => _apiService.scanImageBytes(imageBytes));
    }
    return _scan(() {
      final id = _activeScanId;
      final cancellation = LabelScanCancellation();
      _activeImageCancellation = cancellation;
      return _apiService.scanImageWithProgress(
        imageBytes,
        cancellation: cancellation,
        onProgress: (update) {
          if (!_disposed && id == _activeScanId && !cancellation.isCancelled) {
            onProgress(update);
          }
        },
      );
    });
  }

  Future<ScanResult> scanText(String text) async {
    return _scan(() => _apiService.scanText(text));
  }

  Future<ScanResult> _scan(Future<ScanResult> Function() request) async {
    if (_disposed) throw ScanCancelledException();
    _activeImageCancellation?.cancel();
    _activeImageCancellation = null;
    final currentId = ++_activeScanId;
    try {
      final result = await request();
      _checkActive(currentId);
      return result;
    } catch (_) {
      _checkActive(currentId);
      rethrow;
    } finally {
      if (currentId == _activeScanId) {
        _activeImageCancellation?.cancel();
        _activeImageCancellation = null;
      }
    }
  }

  void _checkActive(int scanId) {
    if (_disposed || scanId != _activeScanId) {
      throw ScanCancelledException();
    }
  }

  /// Ends this scanner's lifetime and discards its pending results/errors.
  /// The shared API connection remains available to other services and screens.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelCurrentScan();
  }
}
