import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/services/allergy_service.dart';
import 'package:misbar_app/services/api_service.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';

// Mock ApiService to test persistence synchronization, scan isolation, and payload absence
class MockApiService implements ApiService {
  @override
  String baseUrl = 'http://mock:8000';

  List<String> mockBackendAllergies = [
    'Milk',
    'Tree nuts',
    'Cereals containing gluten',
  ];
  int saveCallCount = 0;
  List<List<String>> saveHistory = [];
  Duration saveDelay = Duration.zero;
  bool shouldFailSave = false;
  int? failSaveCall;
  bool shouldFailFetch = false;
  List<String>? saveResponse;
  Completer<List<String>>? pendingFetch;
  Completer<List<String>>? pendingSave;

  Uint8List? lastScannedBytes;
  String? lastScannedText;

  @override
  Future<Map<String, dynamic>> getProfile() async => {};

  @override
  Future<Map<String, dynamic>> updateProfile({
    String? name,
    String? email,
  }) async => {};

  @override
  void dispose() {}

  @override
  Future<List<String>> getUserAllergies() async {
    if (pendingFetch != null) return pendingFetch!.future;
    if (shouldFailFetch) throw ApiException(503, 'Local retrieval failure');
    return List<String>.from(mockBackendAllergies);
  }

  @override
  Future<List<String>> saveUserAllergies(List<String> allergies) async {
    saveCallCount++;
    final call = saveCallCount;
    saveHistory.add(List<String>.from(allergies));
    if (pendingSave != null) return pendingSave!.future;

    if (saveDelay > Duration.zero) {
      await Future.delayed(saveDelay);
    }

    if (shouldFailSave || failSaveCall == call) {
      throw ApiException(500, 'Firestore write timeout / failure');
    }

    mockBackendAllergies = List<String>.from(allergies);
    return saveResponse ?? mockBackendAllergies;
  }

  @override
  Future<ScanResult> scanImageWithProgress(
    Uint8List imageBytes, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) => scanImageBytes(imageBytes);

  @override
  Future<ScanResult> scanImageBytes(Uint8List imageBytes) async {
    lastScannedBytes = imageBytes;

    // Simulate backend response derived strictly from Firestore (mockBackendAllergies)
    final detections = [
      AllergenDetection(
        allergen: 'Milk',
        matchedIngredients: const ['milk', 'whey'],
        isUserAllergen: mockBackendAllergies.contains('Milk'),
      ),
      AllergenDetection(
        allergen: 'Cereals containing gluten',
        matchedIngredients: const ['wheat flour'],
        isUserAllergen: mockBackendAllergies.contains(
          'Cereals containing gluten',
        ),
      ),
    ];

    final hasConflict = detections.any((d) => d.isUserAllergen);

    return ScanResult(
      success: true,
      status: 'completed',
      isSafe: !hasConflict,
      extractedOcrText: 'Milk, wheat flour, sugar',
      ingredientList: 'Milk, wheat flour, sugar',
      allergensDetected: detections,
    );
  }

  @override
  Future<ScanResult> scanText(String text) async {
    lastScannedText = text;
    final isDairyAllergic = mockBackendAllergies.contains('Milk');

    return ScanResult(
      success: true,
      status: 'completed',
      isSafe: !isDairyAllergic,
      extractedOcrText: text,
      ingredientList: text,
      allergensDetected: [
        AllergenDetection(
          allergen: 'Milk',
          matchedIngredients: const ['milk'],
          isUserAllergen: isDairyAllergic,
        ),
      ],
    );
  }
}

void main() {
  group('Firestore Authoritative Allergy & Scanning Tests', () {
    late MockApiService mockApi;
    late AllergyService allergyService;
    late AllergenScannerService scannerService;

    setUp(() {
      mockApi = MockApiService();
      allergyService = AllergyService(mockApi);
      allergyService.clearSession();
      scannerService = AllergenScannerService(apiService: mockApi);
      allergyService.setLocalAllergies([
        'Milk',
        'Tree nuts',
        'Cereals containing gluten',
      ]);
    });

    test(
      'Clearing a session rejects late reads without replacing new selections',
      () async {
        final pending = Completer<List<String>>();
        mockApi.pendingFetch = pending;
        final rejected = expectLater(
          allergyService.fetchUserAllergies(),
          throwsStateError,
        );
        allergyService.clearSession();
        expect(allergyService.currentAllergies, isNull);
        expect(allergyService.lastCommittedAllergies, isNull);
        allergyService.setLocalAllergies(['Fish']);
        pending.complete(['Milk']);
        await rejected;
        expect(allergyService.currentAllergies, ['Fish']);
        expect(allergyService.lastCommittedAllergies, ['Fish']);
      },
    );

    test('Logout drops queued writes and old completions cannot touch a new session', () async {
      final pending = Completer<List<String>>();
      mockApi.pendingSave = pending;
      final old = expectLater(
        allergyService.saveUserAllergies(['Milk']),
        throwsStateError,
      );
      final queued = expectLater(
        allergyService.saveUserAllergies(['Egg']),
        throwsStateError,
      );
      allergyService.clearSession();
      expect(allergyService.isSaving, isFalse);
      mockApi.pendingSave = null;
      await allergyService.saveUserAllergies(['Fish']);
      pending.complete(['Milk']);
      await old;
      await queued;
      expect(mockApi.saveHistory, [
        ['Milk'],
        ['Fish'],
      ]);
      expect(allergyService.lastCommittedAllergies, ['Fish']);
      expect(allergyService.currentAllergies, ['Fish']);
      expect(allergyService.isSaving, isFalse);
      await allergyService.ensureSaved();
    });

    test('1. Removing an allergy and continuing awaits successful Firestore persistence', () async {
      mockApi.saveDelay = const Duration(milliseconds: 60);

      // User removes 'Milk'
      final target = ['Tree nuts', 'Cereals containing gluten'];
      final saveFuture = allergyService.saveUserAllergies(target);

      expect(allergyService.isSaving, isTrue);
      // Backend has not received write yet during delay
      expect(mockApi.mockBackendAllergies.contains('Milk'), isTrue);

      // Screen awaits confirmation before proceeding
      await allergyService.ensureSaved();
      await saveFuture;

      expect(allergyService.isSaving, isFalse);
      // Write confirmed in backend
      expect(
        mockApi.mockBackendAllergies,
        equals(['Tree nuts', 'Cereals containing gluten']),
      );

      // Now scan triggers (scanImageBytes receives only bytes, no allergies)
      final scanResult = await mockApi.scanImageBytes(
        Uint8List.fromList([1, 2, 3]),
      );

      // Backend evaluated scan using its newly persisted Firestore data (Dairy removed)
      final dairyDetection = scanResult.allergensDetected.firstWhere(
        (d) => d.allergen == 'Milk',
      );
      expect(dairyDetection.isUserAllergen, isFalse);
    });

    test('2. Failed or timed-out save prevents navigation and scanning and rolls back state', () async {
      mockApi.shouldFailSave = true;

      // Initial committed state has Dairy
      await allergyService.fetchUserAllergies();
      expect(allergyService.currentAllergies, contains('Milk'));

      // Attempt to remove Dairy, but Firestore fails
      try {
        await allergyService.saveUserAllergies([
          'Tree nuts',
          'Cereals containing gluten',
        ]);
        fail('Expected ApiException on failed save');
      } catch (e) {
        expect(e, isA<ApiException>());
      }

      // State is rolled back to last confirmed state
      expect(allergyService.currentAllergies, contains('Milk'));
      expect(allergyService.isSaving, isFalse);

      // ensureSaved() will not mask errors
      await expectLater(
        allergyService.ensureSaved(),
        throwsA(isA<ApiException>()),
      );
    });

    test(
      '3 & 9. Scan requests never supply allergies (image & text endpoints)',
      () async {
        final imageBytes = Uint8List.fromList([10, 20, 30]);

        // Call scanImageBytes
        final imgResult = await mockApi.scanImageBytes(imageBytes);
        expect(mockApi.lastScannedBytes, equals(imageBytes));
        expect(imgResult.success, isTrue);

        // Call scanText
        final txtResult = await mockApi.scanText('Milk, Sugar');
        expect(mockApi.lastScannedText, equals('Milk, Sugar'));
        expect(txtResult.success, isTrue);
      },
    );

    test('4. In-flight scan cancellation when preferences change', () async {
      // Start a scan
      final scanFuture = scannerService.scanImageBytes(
        Uint8List.fromList([1, 2, 3]),
      );

      // User immediately modifies allergies while scan is in flight
      scannerService.cancelCurrentScan();

      // Scan response arrives after cancellation -> must throw ScanCancelledException
      expect(scanFuture, throwsA(isA<ScanCancelledException>()));
    });

    test('7. Rapid successive edits serialize and cannot overwrite newer selections', () async {
      mockApi.saveDelay = const Duration(milliseconds: 40);

      // Rapid successive updates
      final f1 = allergyService.saveUserAllergies([
        'Tree nuts',
        'Cereals containing gluten',
      ]);
      final f2 = allergyService.saveUserAllergies([
        'Cereals containing gluten',
      ]);

      expect(allergyService.isSaving, isTrue);

      await allergyService.ensureSaved();
      await Future.wait([f1, f2]);

      expect(allergyService.isSaving, isFalse);
      // Final backend state matches the newest selection
      expect(
        mockApi.mockBackendAllergies,
        equals(['Cereals containing gluten']),
      );
      expect(
        allergyService.currentAllergies,
        equals(['Cereals containing gluten']),
      );
    });

    test('8. Remaining selected allergies are flagged, and unselected allergens visible globally', () async {
      // Backend has only Cereals containing gluten
      mockApi.mockBackendAllergies = ['Cereals containing gluten'];

      final scanResult = await mockApi.scanImageBytes(
        Uint8List.fromList([1, 2, 3]),
      );

      // Dairy is detected globally, but not as user allergen
      final dairy = scanResult.allergensDetected.firstWhere(
        (d) => d.allergen == 'Milk',
      );
      expect(dairy.isUserAllergen, isFalse);
      expect(dairy.matchedIngredients, contains('milk'));

      // Gluten is detected and flagged as user allergen
      final gluten = scanResult.allergensDetected.firstWhere(
        (d) => d.allergen == 'Cereals containing gluten',
      );
      expect(gluten.isUserAllergen, isTrue);
      expect(gluten.matchedIngredients, contains('wheat flour'));

      // Unsafe because Gluten matched
      expect(scanResult.isSafe, isFalse);
    });

    test(
      'An empty successful read stays distinct from a failed read',
      () async {
        mockApi.mockBackendAllergies = [];
        expect(await allergyService.fetchUserAllergies(), isEmpty);
        expect(allergyService.currentAllergies, isEmpty);
        expect(allergyService.lastCommittedAllergies, isEmpty);
        await expectLater(allergyService.ensureSaved(), throwsFormatException);
        mockApi.shouldFailFetch = true;
        await expectLater(
          allergyService.fetchUserAllergies(),
          throwsA(isA<ApiException>()),
        );
        expect(allergyService.currentAllergies, isNull);
        expect(allergyService.lastCommittedAllergies, isNull);
        expect(mockApi.saveCallCount, 0);
      },
    );

    test(
      'Unknown saved categories fail without exposing cached selections',
      () async {
        mockApi.mockBackendAllergies = ['Dairy allergy'];
        await expectLater(
          allergyService.fetchUserAllergies(),
          throwsFormatException,
        );
        expect(allergyService.currentAllergies, isNull);
        expect(allergyService.lastCommittedAllergies, isNull);
      },
    );

    test(
      'Empty and noncanonical selections never enter the save queue',
      () async {
        final previous = allergyService.currentAllergies;
        for (final values in [
          <String>[],
          ['Dairy allergy'],
          ['Milk '],
          ['Milk', 'Milk'],
        ]) {
          await expectLater(
            allergyService.saveUserAllergies(values),
            throwsFormatException,
          );
        }
        await expectLater(
          allergyService.saveUserAllergies('missing-list'),
          throwsFormatException,
        );
        expect(mockApi.saveCallCount, 0);
        expect(allergyService.currentAllergies, previous);
      },
    );

    test(
      'Each canonical category saves verbatim through the existing queue',
      () async {
        for (final category in AllergenDetection.categories) {
          await allergyService.saveUserAllergies([category.name]);
          await allergyService.ensureSaved();
          expect(mockApi.saveHistory.last, [category.name]);
          expect(allergyService.lastCommittedAllergies, [category.name]);
        }
      },
    );

    test('Invalid save confirmation cannot unlock navigation; a later valid save can', () async {
      mockApi.saveResponse = [];
      await expectLater(
        allergyService.saveUserAllergies(['Egg']),
        throwsFormatException,
      );
      await expectLater(allergyService.ensureSaved(), throwsFormatException);
      expect(allergyService.currentAllergies, [
        'Milk',
        'Tree nuts',
        'Cereals containing gluten',
      ]);
      mockApi.saveResponse = null;
      await allergyService.saveUserAllergies(['Egg']);
      await allergyService.ensureSaved();
      expect(allergyService.lastCommittedAllergies, ['Egg']);
    });

    test(
      'A queued success clears an earlier failure only after it is confirmed',
      () async {
        mockApi.saveDelay = const Duration(milliseconds: 20);
        mockApi.failSaveCall = 1;
        final first = allergyService.saveUserAllergies(['Egg']);
        final firstFailure = expectLater(first, throwsA(isA<ApiException>()));
        final latest = allergyService.saveUserAllergies(['Fish']);
        await allergyService.ensureSaved();
        await firstFailure;
        await latest;
        expect(allergyService.lastCommittedAllergies, ['Fish']);
        expect(allergyService.currentAllergies, ['Fish']);
      },
    );

    test(
      'A queued failure cannot be hidden by an earlier confirmed save',
      () async {
        mockApi.saveDelay = const Duration(milliseconds: 20);
        mockApi.failSaveCall = 2;
        final first = allergyService.saveUserAllergies(['Egg']);
        final latest = allergyService.saveUserAllergies(['Fish']);
        final latestFailure = expectLater(latest, throwsA(isA<ApiException>()));
        await expectLater(
          allergyService.ensureSaved(),
          throwsA(isA<ApiException>()),
        );
        await first;
        await latestFailure;
        await expectLater(
          allergyService.ensureSaved(),
          throwsA(isA<ApiException>()),
        );
        expect(allergyService.lastCommittedAllergies, ['Egg']);
      },
    );
  });
}
