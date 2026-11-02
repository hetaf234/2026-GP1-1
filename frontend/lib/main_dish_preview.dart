// TEMPORARY, USER-APPROVED OFFLINE PHONE PREVIEW. Restore the saved original
// after visual review. No production screen, API implementation or data changes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Temporary debug mock: reuse an installed test dependency without changing pubspec.
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
// Temporary debug mock: reuse an installed test dependency without changing pubspec.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart' show MisbarApp;
import 'features/dish_scan/dish_error_screen.dart';
import 'features/dish_scan/dish_home_screen.dart';
import 'features/dish_scan/dish_result.dart';
import 'features/dish_scan/dish_result_screen.dart';
import 'features/dish_scan/dish_scan_service.dart';
import 'features/dish_scan/dish_widgets.dart';
import 'features/dish_scan/preview/dish_preview_service.dart';
import 'models/scan_result.dart';
import 'screens/allergy_selection_screen.dart';
import 'screens/error_screen.dart';
import 'screens/scan_result_screen.dart';
import 'services/allergen_scanner_service.dart';
import 'services/api_service.dart';
import 'theme/app_colors.dart';

const _previewAddress = 'https://misbar-ui.invalid';

/// Uses the unchanged real application, with memory-only identity and HTTP.
/// The existing Android preview flag skips google-services configuration and
/// assigns the separate .dishpreview package. Never use the normal entry point.
void main() {
  if (!kDebugMode ||
      !const bool.fromEnvironment('MISBAR_DISH_PREVIEW') ||
      (ApiService.configuredBaseUrl.isNotEmpty &&
          ApiService.configuredBaseUrl != _previewAddress)) {
    throw StateError('Use the debug offline preview with no live API address.');
  }
  HttpOverrides.global = _NoNetwork();
  const gallery = bool.fromEnvironment('MISBAR_RESULTS_GALLERY');
  final data = _MemoryPreview();
  if (gallery) data.allergies = List.of(_galleryAllergies);
  http.runWithClient(() {
    WidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _MemoryFirebase();
    FirebaseAuthPlatform.instance = _MemoryAuth();
    ApiService().baseUrl = _previewAddress;
    debugPrint(
      'Offline UI preview: memory-only identity, selections and results.',
    );
    runApp(gallery ? const OfflineScanResultsPreview() : const MisbarApp());
  }, () => _MemoryClient(data));
}

// Temporary offline gallery only. The real application never imports this file.
const _galleryAllergies = ['Milk', 'Egg', 'Cereals containing gluten'];

enum OfflineScanPreviewCase {
  dishMatches('Dish · Matching allergens'),
  dishNoMatches('Dish · No matching allergens'),
  dishLowQuality('Dish · Low image quality'),
  dishNotSingle('Dish · Not a single dish'),
  dishUnsupported('Dish · Unsupported dish'),
  dishConnection('Dish · Connection error'),
  labelMatches('Label · Matching allergens'),
  labelNoMatches('Label · No matching allergens'),
  labelMissingDetails('Label · Matches without ingredient details'),
  labelIncomplete('Label · Analysis incomplete'),
  labelLowQuality('Label · Image not clear'),
  labelNoText('Label · No readable text'),
  labelNoIngredients('Label · No ingredient list'),
  labelConnection('Label · Connection error');

  final String label;
  const OfflineScanPreviewCase(this.label);
}

/// Reuses the actual screens with fictional, memory-only results.
class OfflineScanResultsPreview extends StatelessWidget {
  const OfflineScanResultsPreview({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryGreen),
      useMaterial3: true,
    ),
    initialRoute: scanHomeRoute,
    routes: {scanHomeRoute: (_) => const _OfflineResultsHome()},
  );
}

class _OfflineResultsHome extends StatefulWidget {
  const _OfflineResultsHome();

  @override
  State<_OfflineResultsHome> createState() => _OfflineResultsHomeState();
}

class _OfflineResultsHomeState extends State<_OfflineResultsHome> {
  final _fixtures = _MemoryPreview()..allergies = List.of(_galleryAllergies);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCases();
    });
  }

  void _showCases() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.88,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'All 14 scan outcomes\nOffline samples · No real analysis',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final sample in OfflineScanPreviewCase.values)
                      ListTile(
                        key: ValueKey('offline-case-${sample.name}'),
                        leading: CircleAvatar(
                          child: Text('${sample.index + 1}'),
                        ),
                        title: Text(sample.label),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          Navigator.of(context).push<void>(
                            MaterialPageRoute(builder: (_) => _screen(sample)),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _screen(OfflineScanPreviewCase sample) {
    final failure = switch (sample) {
      OfflineScanPreviewCase.dishLowQuality => DishScanFailure.lowQuality,
      OfflineScanPreviewCase.dishNotSingle => DishScanFailure.notSingleDish,
      OfflineScanPreviewCase.dishUnsupported => DishScanFailure.unsupportedDish,
      OfflineScanPreviewCase.dishConnection => DishScanFailure.connection,
      _ => null,
    };
    if (failure != null) {
      return DishErrorScreen(
        failure: failure,
        userAllergens: _galleryAllergies,
        scanner: const PreviewDishScanService(DishPreviewScenario.matching),
        preview: true,
      );
    }
    if (sample == OfflineScanPreviewCase.dishMatches ||
        sample == OfflineScanPreviewCase.dishNoMatches) {
      final response = _fixtures.dishResult();
      if (sample == OfflineScanPreviewCase.dishNoMatches) {
        response['personalization']['matches'] = <dynamic>[];
        response['personalization']['match_status'] = 'no_known_matches';
      }
      return DishResultScreen(
        result: DishResult.fromJson(response),
        userAllergens: _galleryAllergies,
        scanner: const PreviewDishScanService(DishPreviewScenario.matching),
        preview: true,
      );
    }
    final labelError = switch (sample) {
      OfflineScanPreviewCase.labelLowQuality => ErrorType.imageBlurry,
      OfflineScanPreviewCase.labelNoText ||
      OfflineScanPreviewCase.labelNoIngredients => ErrorType.labelUnreadable,
      OfflineScanPreviewCase.labelConnection => ErrorType.connectionError,
      _ => null,
    };
    if (labelError != null) {
      return ErrorScreen(
        type: labelError,
        imageBytes: Uint8List(0),
        userAllergens: _galleryAllergies,
        scannerService: AllergenScannerService(),
      );
    }
    final response = _fixtures.labelResult();
    if (sample == OfflineScanPreviewCase.labelNoMatches) {
      response['is_safe'] = true;
      response['allergens_detected'] = <dynamic>[];
      response['total_allergens_count'] = 0;
    } else if (sample == OfflineScanPreviewCase.labelMissingDetails) {
      for (final detection in response['allergens_detected']) {
        detection['matched_ingredients'] = <String>[];
      }
    }
    // This is the screen's defensive fallback, not a valid successful API reply.
    final result = sample == OfflineScanPreviewCase.labelIncomplete
        ? const ScanResult(
            success: false,
            isSafe: false,
            extractedOcrText: '',
            ingredientList: '',
            allergensDetected: [],
          )
        : ScanResult.fromJson(response);
    return ScanResultScreen(
      result: result,
      imageBytes: Uint8List(0),
      userAllergens: _galleryAllergies,
      scannerService: AllergenScannerService(),
    );
  }

  @override
  Widget build(BuildContext context) => DishHomeScreen(
    displayName: 'UI Preview',
    userAllergens: _galleryAllergies,
    onScanLabel: _showCases,
    onManageAllergies: () => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const AllergySelectionScreen(manageAllergies: true),
      ),
    ),
    scanner: const PreviewDishScanService(DishPreviewScenario.matching),
    preview: true,
    previewControls: DishPrimaryButton(
      label: 'View all 14 scan results',
      icon: Icons.view_list_outlined,
      onPressed: _showCases,
    ),
  );
}

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw StateError('Network disabled in the offline UI preview.');
  }
}

/// No native Firebase initialization, configuration, account or token lookup.
class _MemoryFirebase extends FirebasePlatform {
  final _app = FirebaseAppPlatform(
    '[DEFAULT]',
    const FirebaseOptions(
      apiKey: 'offline-not-a-key',
      appId: 'offline-ui-preview',
      messagingSenderId: 'offline',
      projectId: 'misbar-offline-ui-only',
    ),
  );

  @override
  List<FirebaseAppPlatform> get apps => [_app];

  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) {
    if (name != _app.name) {
      throw StateError('Only the offline identity exists.');
    }
    return _app;
  }

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    throw StateError('Firebase initialization is disabled in this preview.');
  }
}

class _MemoryAuth extends FirebaseAuthPlatform {
  final _changes = StreamController<UserPlatform?>.broadcast();
  late UserPlatform? _user = _MemoryUser(this);

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseAuthPlatform setInitialValues({
    PigeonUserDetails? currentUser,
    String? languageCode,
  }) => this;

  @override
  UserPlatform? get currentUser => _user;

  @override
  Stream<UserPlatform?> authStateChanges() async* {
    yield _user;
    yield* _changes.stream;
  }

  // Phone UI review only: exercise the existing error banners without signing
  // into Firebase or creating an account. Restart the preview to return to the
  // initial local allergy-selection session after signing out.
  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    throw FirebaseAuthException(code: 'invalid-credential');
  }

  @override
  Future<UserCredentialPlatform> createUserWithEmailAndPassword(
    String email,
    String password,
  ) async {
    throw FirebaseAuthException(code: 'email-already-in-use');
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _changes.add(null);
  }
}

class _MemoryUser extends UserPlatform {
  _MemoryUser(_MemoryAuth auth)
    : super(
        auth,
        _MemoryMultiFactor(auth),
        PigeonUserDetails(
          userInfo: PigeonUserInfo(
            uid: 'offline-ui-user',
            displayName: 'UI Preview',
            isAnonymous: false,
            isEmailVerified: true,
          ),
          providerData: [],
        ),
      );

  @override
  Future<String?> getIdToken(bool forceRefresh) async => 'offline-not-a-token';
}

class _MemoryMultiFactor extends MultiFactorPlatform {
  _MemoryMultiFactor(super.auth);
}

class _MemoryPreview {
  List<String> allergies = [];

  // Fictional UI examples, not the ingredient dataset or allergen-name aliases.
  static const examples = [
    (allergen: 'Celery', ingredient: 'Celery seasoning'),
    (allergen: 'Cereals containing gluten', ingredient: 'Wheat flour'),
    (allergen: 'Crustaceans', ingredient: 'Shrimp'),
    (allergen: 'Egg', ingredient: 'Egg powder'),
    (allergen: 'Fish', ingredient: 'Fish sauce'),
    (allergen: 'Lupin', ingredient: 'Lupin flour'),
    (allergen: 'Milk', ingredient: 'Milk powder'),
    (allergen: 'Molluscs', ingredient: 'Mussel'),
    (allergen: 'Mustard', ingredient: 'Mustard seed'),
    (allergen: 'Peanut', ingredient: 'Peanut paste'),
    (allergen: 'Sesame', ingredient: 'Sesame seed'),
    (allergen: 'Soybean', ingredient: 'Soybean flour'),
    (
      allergen: 'Sulphur dioxide and sulphites',
      ingredient: 'Sodium metabisulphite',
    ),
    (allergen: 'Tree nuts', ingredient: 'Almond'),
  ];

  Map<String, dynamic> labelResult() => {
    'success': true,
    'status': 'completed',
    'is_safe': !examples.any((e) => allergies.contains(e.allergen)),
    'extracted_ocr_text':
        'Fictional label for UI review only. No OCR performed.',
    'ingredient_list': examples.map((e) => e.ingredient).join(', '),
    'allergens_detected': [
      for (final e in examples)
        {
          'allergen': e.allergen,
          'matched_ingredients': [e.ingredient],
          'is_user_allergen': allergies.contains(e.allergen),
        },
    ],
    'total_allergens_count': examples.length,
    'ocr_engine': 'offline_ui_fixture',
    'message':
        'Fictional UI data only. No image processing or safety assessment.',
  };

  Map<String, dynamic> dishResult() {
    final matches = <Map<String, dynamic>>[];
    for (final e in examples.where((e) => allergies.contains(e.allergen))) {
      final evidence = {
        'source': 'Fictional UI fixture',
        'original_name': e.ingredient,
        'confidence': 25,
        'allergens': [e.allergen],
        'mapping_evidence': ['Fictional link for display testing only'],
      };
      matches.add({
        'allergen': e.allergen,
        'causes': [
          {
            'ingredient': e.ingredient,
            'sources': ['Fictional UI fixture'],
            'evidence': [evidence],
            'original_members': [
              {
                'id': 'offline-${matches.length}',
                'name': e.ingredient,
                'evidence': [evidence],
              },
            ],
          },
        ],
      });
    }
    return {
      'decision': 'accepted',
      'final_dish_display_name_en': 'Mock dish - UI test only',
      'semantic_normalization_performed': true,
      'user_allergy_matching_performed': true,
      'personalization': {
        'status': 'completed',
        'method': 'offline_ui_fixture',
        'profile_source': 'memory_only',
        'selected_allergies': List<String>.from(allergies),
        'unresolved_profile_terms': [],
        'match_status': matches.isNotEmpty
            ? 'potential_matches_found'
            : 'no_allergies_selected',
        'matches': matches,
        'mapping_disagreements': [],
        'ingredients_without_identified_allergens': [
          {'name': 'Unidentified garnish (fictional)', 'members': []},
        ],
        'safety_assessment': 'not_established',
        'notice':
            'Fictional UI fixture. No real analysis or safety conclusion.',
      },
    };
  }
}

/// Every client owns its lifetime but shares only this preview's memory state.
/// Unknown hosts, paths and methods fail instead of falling back to real HTTP.
class _MemoryClient extends http.BaseClient {
  final _MemoryPreview data;
  bool _closed = false;
  _MemoryClient(this.data);

  http.StreamedResponse _json(Object value, {int status = 200}) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(value))),
        status,
        headers: {'content-type': 'application/json'},
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed ||
        request.url.origin != _previewAddress ||
        request.headers['Authorization'] != 'Bearer offline-not-a-token') {
      throw StateError('Only local mock requests are allowed.');
    }
    // Image bytes are consumed in memory and immediately discarded, never sent.
    final body = await request.finalize().toBytes();
    switch ((request.method, request.url.path)) {
      case ('GET', '/users/me/allergies'):
        return _json({'allergies': List<String>.from(data.allergies)});
      case ('PUT', '/users/me/allergies'):
        final values = (jsonDecode(
          utf8.decode(body),
        ) as Map<String, dynamic>)['allergies'];
        if (values is! List ||
            values.isEmpty ||
            values.toSet().length != values.length ||
            values.any(
              (v) => !AllergenDetection.categories.any((c) => c.name == v),
            )) {
          return _json({
            'detail': 'Select at least one canonical allergen.',
          }, status: 422);
        }
        data.allergies = List<String>.from(values);
        return _json({'allergies': List<String>.from(data.allergies)});
      case ('POST', '/scan/image'):
      case ('POST', '/scan/text'):
        if (data.allergies.isEmpty) {
          return _json({'detail': 'Select an allergen first.'}, status: 422);
        }
        return _json(data.labelResult());
      case ('POST', '/scan/dish'):
        if (data.allergies.isEmpty) {
          return _json({'detail': 'Select an allergen first.'}, status: 422);
        }
        var sequence = 0;
        String event(String kind, Map<String, dynamic> value) =>
            'event: $kind\ndata: ${jsonEncode({'scan_id': 'offline-ui-scan', 'sequence': ++sequence, ...value})}\n\n';
        Stream<List<int>> frames() async* {
          for (final stage in [
            'image_received',
            'identifying_ingredients',
            'checking_allergens',
          ]) {
            for (final status in ['running', 'completed']) {
              yield utf8.encode(
                event('progress', {'stage': stage, 'status': status}),
              );
              await Future<void>.delayed(const Duration(milliseconds: 180));
            }
          }
          yield utf8.encode(
            event('outcome', {'http_status': 200, 'result': data.dishResult()}),
          );
        }
        return http.StreamedResponse(
          frames(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      default:
        throw StateError('This action is unavailable in the offline preview.');
    }
  }

  @override
  void close() => _closed = true;
}
