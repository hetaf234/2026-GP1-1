import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/features/dish_scan/dish_home_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_result.dart';
import 'package:misbar_app/features/dish_scan/dish_result_screen.dart';
import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';
import 'package:misbar_app/screens/allergy_selection_screen.dart';
import 'package:misbar_app/screens/login_screen.dart';
import 'package:misbar_app/screens/scan_result_screen.dart';
import 'package:misbar_app/screens/scanning_screen.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';
import 'package:misbar_app/services/allergy_service.dart';
import 'package:misbar_app/services/api_service.dart';
import 'package:misbar_app/theme/app_colors.dart';
import 'package:misbar_app/widgets/matched_allergen_card.dart';

import 'support/http_lifecycle_doubles.dart';

void main() {
  late TestAuth auth;
  late LifecycleHttpClient client;
  late ApiService api;

  setUpAll(() async {
    auth = await initializeTestAuth();
    client = LifecycleHttpClient();
    api = http.runWithClient(ApiService.new, () => client);
  });

  setUp(() {
    auth.signedIn = true;
    auth.pendingToken = null;
    client.requests.clear();
    client.savedAllergies = ['Milk'];
    client.allergyResponse = null;
    client.pendingAllergies = null;
    client.pendingSave = null;
    client.nextStatus = null;
    client.pendingScan = null;
    AllergyService().clearSession();
  });

  tearDownAll(() => api.dispose());

  Future<void> phone(WidgetTester tester, {double width = 390}) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'Successful login reads saved allergies and bypasses onboarding',
    (tester) async {
      await phone(tester);
      auth.signedIn = false;
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'test@example.invalid',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'Example1!');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Log In'));
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(find.text('Select Your Allergies'), findsNothing);
      expect(find.text('My Allergies'), findsOneWidget);
      expect(client.savedAllergies, ['Milk']);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.request.method, 'GET');
      expect(
        client.requests.single.request.headers['Authorization'],
        'Bearer local-test-token',
      );
      await Navigator.of(tester.element(find.byType(DishHomeScreen)))
          .maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(find.text('Select Your Allergies'), findsNothing);
    },
  );

  testWidgets('Entry loading never flashes selection or modifies preferences', (
    tester,
  ) async {
    await phone(tester);
    final pending = Completer<http.StreamedResponse>();
    client.pendingAllergies = pending;
    await tester.pumpWidget(
      const MaterialApp(home: AllergySelectionScreen(skipSavedSelection: true)),
    );
    await tester.pump();
    expect(find.text('Loading your saved allergies...'), findsOneWidget);
    expect(find.text('Select Your Allergies'), findsNothing);
    expect(find.byType(DishHomeScreen), findsNothing);
    pending.complete(
      LifecycleHttpClient.response({
        'allergies': ['Egg'],
        'allergy_selection_saved': true,
      }),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<DishHomeScreen>(find.byType(DishHomeScreen)).userAllergens,
      ['Egg'],
    );
    expect(client.requests.every((r) => r.request.method == 'GET'), isTrue);
  });

  testWidgets('New users have no defaults and need a confirmed nonempty save', (
    tester,
  ) async {
    await phone(tester);
    client.savedAllergies = [];
    await tester.pumpWidget(
      const MaterialApp(home: AllergySelectionScreen(skipSavedSelection: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Select Your Allergies'), findsOneWidget);
    for (final category in AllergenDetection.categories) {
      expect(
        tester
            .widget<Text>(
              find.text(AllergenDetection.displayName(category.name)),
            )
            .style!
            .color,
        isNot(Colors.white),
      );
    }
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      find.text('Select at least one allergen to continue.'),
      findsOneWidget,
    );
    expect(find.byType(DishHomeScreen), findsNothing);
    expect(client.requests.every((r) => r.request.method == 'GET'), isTrue);
    await tester.ensureVisible(find.text('Milk'));
    await tester.tap(find.text('Milk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(DishHomeScreen), findsOneWidget);
    expect(client.savedAllergies, ['Milk']);
    expect(
      client.requests.where((r) => r.request.method == 'PUT'),
      hasLength(1),
    );
  });

  for (final failure in ['unavailable', 'invalid', 'inconsistent', 'missing']) {
    testWidgets('Entry $failure stays retryable without redirect or writes', (
      tester,
    ) async {
      await phone(tester);
      switch (failure) {
        case 'unavailable':
          client.nextStatus = 503;
        case 'invalid':
          client.allergyResponse = {
            'allergies': ['Dairy'],
          };
        case 'inconsistent':
          client.allergyResponse = {
            'allergies': ['Milk'],
            'allergy_selection_saved': false,
          };
        case 'missing':
          client.allergyResponse = {'allergy_selection_saved': true};
      }
      await tester.pumpWidget(
        const MaterialApp(
          home: AllergySelectionScreen(skipSavedSelection: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Select Your Allergies'), findsNothing);
      expect(find.byType(DishHomeScreen), findsNothing);
      expect(AllergyService().lastCommittedAllergies, isNull);
      client.allergyResponse = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(client.requests.every((r) => r.request.method == 'GET'), isTrue);
      expect(client.savedAllergies, ['Milk']);
    });
  }

  testWidgets('Onboarding Logout is at top left inside SafeArea with tooltip', (
    tester,
  ) async {
    await phone(tester);
    client.savedAllergies = [];
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(padding: EdgeInsets.only(top: 30)),
          child: AllergySelectionScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final logout = find.byKey(const ValueKey('onboarding-logout'));
    expect(find.byTooltip('Log Out'), findsOneWidget);
    expect(tester.getTopLeft(logout).dx, 24);
    expect(tester.getTopLeft(logout).dy, greaterThanOrEqualTo(30));
    expect(tester.getSize(logout).shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(logout);
    await tester.pumpAndSettle();
    expect(
      find.text('Are you sure you want to log out of Misbar?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(auth.signedIn, isTrue);
    expect(client.requests.every((r) => r.request.method == 'GET'), isTrue);
  });

  for (final width in [320.0, 600.0]) {
    for (final dish in [true, false]) {
      testWidgets('${dish ? 'Dish' : 'Label'} disclaimer centered at $width', (
        tester,
      ) async {
        await phone(tester, width: width);
        await tester.pumpWidget(
          MaterialApp(
            home: dish
                ? DishResultScreen(
                    result: DishResult.fromJson(
                      previewDishResponse(hasMatches: false),
                    ),
                    userAllergens: const ['Milk'],
                    scanner: const PreviewDishScanService(
                      DishPreviewScenario.noMatches,
                    ),
                  )
                : ScanResultScreen(
                    result: ScanResult.fromJson(LifecycleHttpClient.scanBody),
                    imageBytes: Uint8List(0),
                    userAllergens: const ['Milk'],
                    scannerService: AllergenScannerService(),
                  ),
          ),
        );
        await tester.pumpAndSettle();
        final disclaimer = find.text(
          'Misbar can make mistakes. Verify before eating.',
        );
        final text = tester.widget<Text>(disclaimer);
        expect(text.textAlign, TextAlign.center);
        expect(text.style!.fontSize, 12);
        expect(text.style!.height, 1.6);
        expect(text.style!.color, AppColors.textMuted);
        expect(tester.getCenter(disclaimer).dx, closeTo(width / 2, 0.1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'Cards start collapsed, expand independently and retain state on rebuild',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MatchedAllergenCard(
                  key: ValueKey('a'),
                  allergen: 'Milk',
                  ingredients: ['Cream'],
                ),
                MatchedAllergenCard(
                  key: ValueKey('b'),
                  allergen: 'Egg',
                  ingredients: ['Sauce'],
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Cream'), findsNothing);
      expect(find.text('Sauce'), findsNothing);
      for (final name in ['Milk', 'Egg']) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }
      expect(find.text('Cream'), findsOneWidget);
      expect(find.text('Sauce'), findsOneWidget);
      tester.element(find.byType(Scaffold)).markNeedsBuild();
      await tester.pump();
      expect(find.text('Cream'), findsOneWidget);
      expect(find.text('Sauce'), findsOneWidget);
      await tester.tap(find.text('Milk'));
      await tester.pumpAndSettle();
      expect(find.text('Cream'), findsNothing);
      expect(find.text('Sauce'), findsOneWidget);
    },
  );

  testWidgets(
    'Label loading reflects real request state and never timed stages',
    (tester) async {
      await phone(tester, width: 320);
      final token = Completer<String?>();
      auth.pendingToken = token;
      final scanApi = _PendingScanApi();
      final scanner = AllergenScannerService(apiService: scanApi);
      await tester.pumpWidget(
        MaterialApp(
          home: ScanningScreen(
            imageBytes: Uint8List.fromList([1, 2, 3]),
            userAllergens: const ['Milk'],
            scannerService: scanner,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Analyzing Your Label'), findsOneWidget);
      expect(find.text('Pending'), findsNWidgets(4));
      expect(client.requests, isEmpty);
      token.complete('local-test-token');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Analyzing Your Label'), findsOneWidget);
      expect(scanApi.calls, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.text('✓ '), findsNothing);
      expect(find.text('Extracting text...'), findsNothing);
      expect(find.text('Analyzing Your Label'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Pending'), findsNWidgets(4));
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
      tester.element(find.byType(ScanningScreen)).markNeedsBuild();
      await tester.pump();
      expect(scanApi.calls, 1);
      scanApi.result.complete(
        ScanResult.fromJson(LifecycleHttpClient.scanBody),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScanResultScreen), findsOneWidget);
      expect(find.byType(ScanningScreen), findsNothing);
      expect(tester.takeException(), isNull);
      scanner.dispose();
    },
  );
}

class _PendingScanApi implements ApiService {
  final result = Completer<ScanResult>();
  int calls = 0;
  @override
  Future<ScanResult> scanImageWithProgress(
    Uint8List imageBytes, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) => scanImageBytes(imageBytes);

  @override
  Future<ScanResult> scanImageBytes(Uint8List imageBytes) {
    calls++;
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
