import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/features/dish_scan/dish_home_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_capture_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_error_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_result.dart';
import 'package:misbar_app/features/dish_scan/dish_result_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_scan_service.dart';
import 'package:misbar_app/features/dish_scan/dish_widgets.dart';
import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/main.dart' show MisbarApp;
import 'package:misbar_app/screens/allergy_selection_screen.dart';
import 'package:misbar_app/screens/error_screen.dart';
import 'package:misbar_app/screens/image_capture_screen.dart';
import 'package:misbar_app/screens/scan_result_screen.dart';
import 'package:misbar_app/screens/scanning_screen.dart';
import 'package:misbar_app/screens/welcome_screen.dart';
import 'package:misbar_app/screens/login_screen.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';
import 'package:misbar_app/services/allergy_service.dart';
import 'package:misbar_app/services/api_service.dart';

import 'support/http_lifecycle_doubles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAuth auth;
  late LifecycleHttpClient client;
  late ApiService api;

  setUpAll(() async {
    auth = await initializeTestAuth();
    client = LifecycleHttpClient();
    api = http.runWithClient(ApiService.new, () => client);
  });

  setUp(() {
    auth.pendingToken = null;
    auth.signedIn = true;
    auth.userId = 'local-test-user';
    auth.signOutCalls = 0;
    auth.failSignOut = false;
    client.nextStatus = null;
    client.failNetwork = false;
    client.allergyResponse = null;
    client.pendingAllergies = null;
    client.pendingSave = null;
    client.requests.clear();
    client.savedAllergies = ['Milk'];
    AllergyService().setLocalAllergies(['Milk']);
  });

  tearDownAll(() => api.dispose());

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'Continue, label capture, My Allergies and re-entry use team flow',
    (tester) async {
      await phone(tester);
      const captureChannel = MethodChannel('com.example.misbar/image_capture');
      var nativeCaptureCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        captureChannel,
        (call) async {
          expect(call.method, 'openImageCapture');
          final header = (call.arguments as Map)['header'] as Map;
          expect(header['logoAsset'], 'assets/images/misbar_logo.png');
          expect(header['contentHeight'], 99.0);
          expect(header['logoWidth'], 94.0);
          expect(header['logoHeight'], 72.0);
          nativeCaptureCalls++;
          return null; // Native capture cancellation follows the team's Flutter path.
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          captureChannel,
          null,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const AllergySelectionScreen(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(find.text('Hi, Test User!'), findsOneWidget);
      expect(find.textContaining('Preview Settings'), findsNothing);
      expect(find.text('No match'), findsNothing);
      expect(find.text('Error'), findsNothing);

      await tester.tap(find.text('Scan Packaged Food Label'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(nativeCaptureCalls, 1);
      expect(find.byType(ImageCaptureScreen), findsOneWidget);
      expect(find.text('Preview Sample Result'), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Allergies'));
      await tester.pumpAndSettle();
      expect(find.byType(AllergySelectionScreen), findsOneWidget);

      await tester.ensureVisible(find.text('Egg'));
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      expect(client.savedAllergies, ['Milk']);
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(
        find.text('Your allergies have been updated successfully.'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(client.savedAllergies, ['Milk', 'Egg']);
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Milk', 'Egg'],
      );

      // AuthGate removes this subtree on sign-out. Reproduce its disposal without
      // changing any real authentication state or user data, then recreate it.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(client.closeCount, 0);
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Egg'));
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      expect(client.savedAllergies, ['Milk']);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(client.closed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  Future<GlobalKey<NavigatorState>> openScanChooser(WidgetTester tester) async {
    await phone(tester);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const AllergySelectionScreen(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(DishHomeScreen), findsOneWidget);
    return navigator;
  }

  Future<void> openManagement(WidgetTester tester) async {
    await tester.tap(find.text('My Allergies'));
    await tester.pumpAndSettle();
    final screen = tester.widget<AllergySelectionScreen>(
      find.byType(AllergySelectionScreen),
    );
    expect(screen.manageAllergies, isTrue);
    expect(
      ModalRoute.of(tester.element(find.byType(AllergySelectionScreen)))!
          .settings
          .name,
      '/my-allergies',
    );
  }

  List<RecordedRequest> saves() =>
      client.requests.where((r) => r.request.method == 'PUT').toList();

  bool selected(WidgetTester tester, String name) =>
      tester
          .widget<Text>(find.text(AllergenDetection.displayName(name)))
          .style!
          .color ==
      Colors.white;

  testWidgets(
    'Cold signed-out AuthGate login reaches saved home without session invalidation',
    (tester) async {
      await phone(tester);
      final messages = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);
      auth.signedIn = false;
      await tester.pumpWidget(const MisbarApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'local@example.invalid',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'local-test-password',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Log In'));
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Select Your Allergies'), findsNothing);
      expect(AllergyService().lastCommittedAllergies, ['Milk']);
      debugPrint = previousDebugPrint;
      expect(
        messages.where((m) => m.contains('authenticated session changed')),
        isEmpty,
      );
      expect(saves(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Main Logout clears session, removes protected routes and allows another login',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(const MisbarApp());
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Log Out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Log Out'));
      await tester.pumpAndSettle();
      expect(auth.signOutCalls, 1);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(DishHomeScreen, skipOffstage: false), findsNothing);
      expect(
        find.byType(AllergySelectionScreen, skipOffstage: false),
        findsNothing,
      );
      expect(AllergyService().currentAllergies, isNull);
      expect(AllergyService().lastCommittedAllergies, isNull);
      final nav = Navigator.of(tester.element(find.byType(WelcomeScreen)));
      expect(nav.canPop(), isFalse);
      expect(await nav.maybePop(), isFalse);
      client.savedAllergies = ['Fish'];
      auth.userId = 'second-local-user';
      await tester.tap(find.text('Log In'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'local@example.invalid',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'local-test-password',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Log In'));
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Fish'],
      );
      expect(find.text('Select Your Allergies'), findsNothing);
      expect(AllergyService().lastCommittedAllergies, ['Fish']);
      expect(saves(), isEmpty);
    },
  );

  testWidgets(
    'AuthGate replacing one account loads the new UID without cached chips',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(const MisbarApp());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Milk'],
      );
      client.savedAllergies = ['Fish'];
      auth.userId = 'second-local-user';
      auth.signedIn = true;
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Fish'],
      );
      expect(find.text('Select Your Allergies'), findsNothing);
      expect(AllergyService().lastCommittedAllergies, ['Fish']);
      expect(saves(), isEmpty);
    },
  );

  for (final pendingKind in ['token', 'http']) {
    testWidgets(
      'My Allergies bounds a stalled $pendingKind and Retry ignores its late result',
      (tester) async {
        await openScanChooser(tester);
        final token = Completer<String?>();
        final response = Completer<http.StreamedResponse>();
        if (pendingKind == 'token') {
          auth.pendingToken = token;
        } else {
          client.pendingAllergies = response;
        }
        await tester.tap(find.text('My Allergies'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await tester.pump(
          ApiService.allergyReadTimeout + const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.text('Unable to load your saved allergies. Please try again.'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        auth.pendingToken = null;
        client.pendingAllergies = null;
        client.savedAllergies = ['Cereals containing gluten'];
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(selected(tester, 'Cereals containing gluten'), isTrue);
        if (pendingKind == 'token') {
          token.complete('late-local-token');
        } else {
          response.complete(
            LifecycleHttpClient.response({
              'allergies': ['Milk'],
            }),
          );
        }
        await tester.pumpAndSettle();
        expect(selected(tester, 'Milk'), isFalse);
        expect(selected(tester, 'Cereals containing gluten'), isTrue);
        expect(saves(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('A genuinely incomplete saved state has a separate message', (
    tester,
  ) async {
    await openScanChooser(tester);
    client.allergyResponse = {
      'allergies': <String>[],
      'allergy_selection_saved': false,
    };
    await openManagement(tester);
    expect(
      find.textContaining('Your account has no saved allergy selection.'),
      findsOneWidget,
    );
    expect(
      find.text('Unable to load your saved allergies. Please try again.'),
      findsNothing,
    );
    expect(saves(), isEmpty);
  });
  testWidgets('Registration selects Gluten but saves only its canonical name', (
    tester,
  ) async {
    const canonical = 'Cereals containing gluten';
    await phone(tester);
    client.savedAllergies = [];
    await tester.pumpWidget(const MaterialApp(home: AllergySelectionScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Gluten'), findsOneWidget);
    expect(find.textContaining(canonical), findsNothing);
    expect(selected(tester, canonical), isFalse);
    await tester.tap(find.text('Gluten'));
    await tester.pumpAndSettle();
    expect(selected(tester, canonical), isTrue);
    expect(client.savedAllergies, [canonical]);
    expect(jsonDecode(saves().single.body), {
      'allergies': [canonical],
    });
    expect(AllergyService().lastCommittedAllergies, [canonical]);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DishHomeScreen>(find.byType(DishHomeScreen)).userAllergens,
      [canonical],
    );
    expect(saves(), hasLength(1));
  });

  testWidgets(
    'My Allergies loads and saves canonical gluten behind its label',
    (tester) async {
      const canonical = 'Cereals containing gluten';
      client.savedAllergies = [canonical];
      await openScanChooser(tester);
      await openManagement(tester);
      expect(find.text('Gluten'), findsOneWidget);
      expect(find.textContaining(canonical), findsNothing);
      expect(selected(tester, canonical), isTrue);
      expect(saves(), isEmpty);

      // The display label must still protect the final saved selection.
      await tester.tap(find.text('Gluten'));
      await tester.pumpAndSettle();
      expect(selected(tester, canonical), isTrue);
      expect(
        find.textContaining('Select at least one allergen.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gluten'));
      await tester.pumpAndSettle();
      expect(selected(tester, canonical), isFalse);
      expect(client.savedAllergies, [canonical]);
      await tester.tap(find.text('Gluten'));
      await tester.pumpAndSettle();
      expect(saves(), isEmpty);
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(jsonDecode(saves().single.body), {
        'allergies': ['Egg', canonical],
      });
      expect(client.savedAllergies, ['Egg', canonical]);
      expect(
        find.text('Your allergies have been updated successfully.'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(AllergyService().lastCommittedAllergies, ['Egg', canonical]);
    },
  );

  testWidgets(
    'My Allergies reuses all 14 chips, loads current saved values and edits a local draft',
    (tester) async {
      final navigator = await openScanChooser(tester);
      client.savedAllergies = [
        'Egg',
        'Fish',
      ]; // Simulate another confirmed backend update.
      await openManagement(tester);
      for (final category in AllergenDetection.categories) {
        expect(
          find.text(AllergenDetection.displayName(category.name)),
          findsOneWidget,
        );
        expect(
          selected(tester, category.name),
          ['Egg', 'Fish'].contains(category.name),
        );
      }
      expect(find.text('Save Changes'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);
      expect(find.byIcon(Icons.logout_rounded), findsNothing);
      expect(
        client.requests.last.request.headers['Authorization'],
        'Bearer local-test-token',
      );
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Milk'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'Egg'), isFalse);
      expect(selected(tester, 'Fish'), isTrue);
      expect(selected(tester, 'Milk'), isTrue);
      expect(saves(), isEmpty);
      expect(client.savedAllergies, ['Egg', 'Fish']);
      expect(AllergyService().lastCommittedAllergies, ['Egg', 'Fish']);
      expect(AllergyService().currentAllergies, ['Egg', 'Fish']);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Discard Changes'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Egg', 'Fish'],
      );
    },
  );

  testWidgets(
    'Management cannot remove its last selection or send an empty save',
    (tester) async {
      await openScanChooser(tester);
      await openManagement(tester);
      await tester.tap(find.text('Milk'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'Milk'), isTrue);
      expect(
        find.textContaining('Select at least one allergen.'),
        findsOneWidget,
      );
      expect(saves(), isEmpty);
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Milk'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'Milk'), isFalse);
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(client.savedAllergies, ['Egg']);
      expect(
        find.text('Your allergies have been updated successfully.'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Save waits for persistence, prevents duplicates, and returns only after acknowledgement',
    (tester) async {
      final navigator = await openScanChooser(tester);
      final homeRoute = ModalRoute.of(
        tester.element(find.byType(DishHomeScreen)),
      );
      await openManagement(tester);
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      final pending = Completer<http.StreamedResponse>();
      client.pendingSave = pending;
      await tester.tap(find.text('Save Changes'));
      await tester.tap(
        find.text('Save Changes'),
      ); // Before the disabled button rebuilds.
      await tester.pump();
      expect(saves(), hasLength(1));
      expect(find.text('Saving...'), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Saving...'),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text('Your allergies have been updated successfully.'),
        findsNothing,
      );
      expect(AllergyService().currentAllergies, ['Milk']);
      expect(AllergyService().lastCommittedAllergies, ['Milk']);
      await navigator.currentState!.maybePop();
      await tester.pump();
      expect(find.text('Discard unsaved changes?'), findsNothing);
      expect(find.byType(DishHomeScreen), findsNothing);
      client.savedAllergies = ['Milk', 'Egg'];
      client.pendingSave = null;
      pending.complete(
        LifecycleHttpClient.response({
          'allergies': ['Milk', 'Egg'],
        }),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Your allergies have been updated successfully.'),
        findsOneWidget,
      );
      expect(find.byType(DishHomeScreen), findsNothing);
      expect(AllergyService().lastCommittedAllergies, ['Milk', 'Egg']);
      await navigator.currentState!
          .maybePop(); // Success requires explicit acknowledgement.
      await tester.pumpAndSettle();
      expect(
        find.text('Your allergies have been updated successfully.'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(
        identical(
          ModalRoute.of(tester.element(find.byType(DishHomeScreen))),
          homeRoute,
        ),
        isTrue,
      );
      expect(find.byType(DishHomeScreen, skipOffstage: false), findsOneWidget);
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Milk', 'Egg'],
      );
      expect(find.textContaining('Your allergies:'), findsNothing);
      expect(find.text('My Allergies'), findsOneWidget);
      expect(saves(), hasLength(1));
      await tester.tap(find.text('Scan Dish'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DishCaptureScreen>(find.byType(DishCaptureScreen))
            .userAllergens,
        ['Milk', 'Egg'],
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      const captureChannel = MethodChannel('com.example.misbar/image_capture');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        captureChannel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          captureChannel,
          null,
        ),
      );
      await tester.tap(find.text('Scan Packaged Food Label'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<ImageCaptureScreen>(find.byType(ImageCaptureScreen))
            .userAllergens,
        ['Milk', 'Egg'],
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        client.requests.where((r) => r.request.url.path.startsWith('/scan/')),
        isEmpty,
      );
    },
  );

  for (final invalidConfirmation in [false, true]) {
    testWidgets(
      'Failed ${invalidConfirmation ? 'confirmation' : 'save'} keeps draft and confirmed cache, and can retry',
      (tester) async {
        await openScanChooser(tester);
        await openManagement(tester);
        await tester.tap(find.text('Egg'));
        await tester.pumpAndSettle();
        if (invalidConfirmation) {
          client.pendingSave = Completer<http.StreamedResponse>()
            ..complete(LifecycleHttpClient.response({'allergies': []}));
        } else {
          client.nextStatus = 503;
        }
        await tester.tap(find.text('Save Changes'));
        await tester.pumpAndSettle();
        expect(
          find.text('Unable to save your allergies. Please try again.'),
          findsOneWidget,
        );
        expect(
          find.text('Your allergies have been updated successfully.'),
          findsNothing,
        );
        expect(find.byType(DishHomeScreen), findsNothing);
        expect(selected(tester, 'Milk'), isTrue);
        expect(selected(tester, 'Egg'), isTrue);
        expect(AllergyService().currentAllergies, ['Milk']);
        expect(AllergyService().lastCommittedAllergies, ['Milk']);
        expect(saves(), hasLength(1));
        client.pendingSave = null;
        await tester.tap(find.text('Save Changes'));
        await tester.pumpAndSettle();
        expect(saves(), hasLength(2));
        expect(client.savedAllergies, ['Milk', 'Egg']);
        expect(
          find.text('Your allergies have been updated successfully.'),
          findsOneWidget,
        );
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
      },
    );
  }

  for (final invalidData in [false, true]) {
    testWidgets(
      'Management ${invalidData ? 'invalid saved values' : 'retrieval failure'} shows Retry and blocks saving',
      (tester) async {
        await openScanChooser(tester);
        if (invalidData) {
          client.allergyResponse = {
            'allergies': ['Egg', 'Dairy allergy'],
          };
        } else {
          client.nextStatus = 503;
        }
        await openManagement(tester);
        expect(
          find.text('Unable to load your saved allergies. Please try again.'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Milk'), findsNothing);
        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Save Changes'),
              )
              .onPressed,
          isNull,
        );
        expect(AllergyService().lastCommittedAllergies, ['Milk']);
        expect(saves(), isEmpty);
        client.allergyResponse = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(selected(tester, 'Milk'), isTrue);
        expect(
          find.text('Unable to load your saved allergies. Please try again.'),
          findsNothing,
        );
        expect(saves(), isEmpty);
      },
    );
  }

  testWidgets(
    'An empty saved management profile is an error, never a new default selection',
    (tester) async {
      await openScanChooser(tester);
      client.allergyResponse = {'allergies': <String>[]};
      await openManagement(tester);
      expect(
        find.textContaining('Your account has no saved allergy selection.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Save Changes'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Milk'), findsNothing);
      expect(AllergyService().lastCommittedAllergies, ['Milk']);
      expect(saves(), isEmpty);
    },
  );

  testWidgets('Management loading blocks saves without defaults', (
    tester,
  ) async {
    await openScanChooser(tester);
    final pending = Completer<http.StreamedResponse>();
    client.pendingAllergies = pending;
    await tester.tap(find.text('My Allergies'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Milk'), findsNothing);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Save Changes'),
          )
          .onPressed,
      isNull,
    );
    expect(saves(), isEmpty);
    client.pendingAllergies = null;
    pending.complete(
      LifecycleHttpClient.response({
        'allergies': ['Fish'],
      }),
    );
    await tester.pumpAndSettle();
    expect(selected(tester, 'Fish'), isTrue);
    expect(selected(tester, 'Milk'), isFalse);
  });

  for (final exit in ['header', 'system']) {
    testWidgets(
      'Management $exit back protects unsaved changes and discards only on request',
      (tester) async {
        final navigator = await openScanChooser(tester);
        final homeRoute = ModalRoute.of(
          tester.element(find.byType(DishHomeScreen)),
        );
        await openManagement(tester);
        await tester.tap(find.text('Egg'));
        await tester.pumpAndSettle();
        if (exit == 'header') {
          await tester.tap(find.byTooltip('Back'));
        } else {
          await navigator.currentState!.maybePop();
        }
        await tester.pumpAndSettle();
        expect(find.text('Discard unsaved changes?'), findsOneWidget);
        await tester.tap(find.text('Keep Editing'));
        await tester.pumpAndSettle();
        expect(selected(tester, 'Egg'), isTrue);
        expect(find.byType(DishHomeScreen), findsNothing);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard Changes'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
        expect(
          identical(
            ModalRoute.of(tester.element(find.byType(DishHomeScreen))),
            homeRoute,
          ),
          isTrue,
        );
        expect(
          tester
              .widget<DishHomeScreen>(find.byType(DishHomeScreen))
              .userAllergens,
          ['Milk'],
        );
        expect(AllergyService().lastCommittedAllergies, ['Milk']);
        expect(saves(), isEmpty);
        await openManagement(tester);
        expect(selected(tester, 'Milk'), isTrue);
        expect(selected(tester, 'Egg'), isFalse);
      },
    );
  }

  testWidgets(
    'Unchanged draft returns normally and double My Allergies taps open one manager',
    (tester) async {
      final navigator = await openScanChooser(tester);
      final homeRoute = ModalRoute.of(
        tester.element(find.byType(DishHomeScreen)),
      );
      await tester.tap(find.text('My Allergies'));
      await tester.tap(find.text('My Allergies'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is AllergySelectionScreen && w.manageAllergies,
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        client.requests.where(
          (r) => r.request.url.path == '/users/me/allergies',
        ),
        hasLength(2),
      );
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsNothing);
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(
        identical(
          ModalRoute.of(tester.element(find.byType(DishHomeScreen))),
          homeRoute,
        ),
        isTrue,
      );
      expect(saves(), isEmpty);
    },
  );

  for (final isDish in [false, true]) {
    for (final hasMatches in [false, true]) {
      testWidgets(
        '${isDish ? 'Dish' : 'Label'} ${hasMatches ? 'matching' : 'no-match'} result Back to Home returns to the same scan chooser',
        (tester) async {
          await phone(tester);
          const channel = MethodChannel('com.example.misbar/image_capture');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (_) async => null,
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          client.savedAllergies = isDish
              ? ['Egg', 'Milk', 'Soybean']
              : ['Milk'];
          final navigator = GlobalKey<NavigatorState>();
          final observer = _NavigationObserver();
          final labelScanner = AllergenScannerService(apiService: api);
          addTearDown(labelScanner.dispose);
          const dishScanner = PreviewDishScanService(
            DishPreviewScenario.matching,
            stageDelay: Duration.zero,
          );
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigator,
              navigatorObservers: [observer],
              home: const AllergySelectionScreen(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Continue'));
          await tester.pumpAndSettle();
          final home = tester.widget<DishHomeScreen>(
            find.byType(DishHomeScreen),
          );
          final homeRoute = ModalRoute.of(
            tester.element(find.byType(DishHomeScreen)),
          )!;
          expect(homeRoute.settings.name, scanHomeRoute);
          await tester.tap(
            find.text(isDish ? 'Scan Dish' : 'Scan Packaged Food Label'),
          );
          // Label capture has a repeating viewfinder animation.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.byType(isDish ? DishCaptureScreen : ImageCaptureScreen),
            findsOneWidget,
          );
          final image = Uint8List(0);
          final labelResult = ScanResult.fromJson({
            ...LifecycleHttpClient.scanBody,
            'is_safe': !hasMatches,
            'allergens_detected': hasMatches
                ? [
                    {
                      'allergen': 'Milk',
                      'matched_ingredients': ['milk powder'],
                      'is_user_allergen': true,
                    },
                  ]
                : <Object>[],
            'total_allergens_count': hasMatches ? 1 : 0,
          });
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => isDish
                  ? DishResultScreen(
                      result: DishResult.fromJson(
                        previewDishResponse(hasMatches: hasMatches),
                      ),
                      imageBytes: image,
                      userAllergens: home.userAllergens,
                      scanner: dishScanner,
                    )
                  : ScanResultScreen(
                      result: labelResult,
                      imageBytes: image,
                      userAllergens: home.userAllergens,
                      scannerService: labelScanner,
                    ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byType(isDish ? DishResultScreen : ScanResultScreen),
            findsOneWidget,
          );
          expect(
            find.text(
              hasMatches ? 'Matching Allergens Found' : 'No Matching Allergens',
            ),
            findsOneWidget,
          );
          final pushesBeforeReturn = observer.pushes;
          await tester.ensureVisible(find.text('Back to Home'));
          await tester.tap(find.text('Back to Home'));
          await tester.pumpAndSettle();
          expect(find.byType(DishHomeScreen), findsOneWidget);
          expect(
            identical(
              tester.widget<DishHomeScreen>(find.byType(DishHomeScreen)),
              home,
            ),
            isTrue,
          );
          expect(
            identical(
              ModalRoute.of(tester.element(find.byType(DishHomeScreen))),
              homeRoute,
            ),
            isTrue,
          );
          expect(find.text('Scan Dish'), findsOneWidget);
          expect(find.text('Scan Packaged Food Label'), findsOneWidget);
          expect(find.byType(AllergySelectionScreen), findsNothing);
          expect(
            find.byType(DishCaptureScreen, skipOffstage: false),
            findsNothing,
          );
          expect(
            find.byType(ImageCaptureScreen, skipOffstage: false),
            findsNothing,
          );
          expect(
            find.byType(ScanResultScreen, skipOffstage: false),
            findsNothing,
          );
          expect(
            find.byType(DishResultScreen, skipOffstage: false),
            findsNothing,
          );
          expect(
            find.byType(DishHomeScreen, skipOffstage: false),
            findsOneWidget,
          );
          expect(observer.pushes, pushesBeforeReturn);
          expect(
            client.requests.where(
              (r) => r.request.url.path.startsWith('/scan/'),
            ),
            isEmpty,
          );
          expect(
            client.requests.where((r) => r.request.method != 'GET'),
            isEmpty,
          );
          expect(
            client.requests.where(
              (r) => r.request.url.path == '/users/me/allergies',
            ),
            hasLength(1),
          );
          await tester.tap(find.text('My Allergies'));
          await tester.pumpAndSettle();
          expect(find.byType(AllergySelectionScreen), findsOneWidget);
          expect(
            tester
                .widget<AllergySelectionScreen>(
                  find.byType(AllergySelectionScreen),
                )
                .manageAllergies,
            isTrue,
          );
          expect(observer.pushes, pushesBeforeReturn + 1);
          await tester.tap(find.byTooltip('Back'));
          await tester.pumpAndSettle();
          expect(find.byType(DishHomeScreen), findsOneWidget);
          expect(
            find.byType(DishHomeScreen, skipOffstage: false),
            findsOneWidget,
          );
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.byType(AllergySelectionScreen), findsOneWidget);
          expect(navigator.currentState!.canPop(), isFalse);
          expect(observer.pushes, pushesBeforeReturn + 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final failure in [...ErrorType.values, ...DishScanFailure.values]) {
    testWidgets(
      '$failure Back to Home returns to the same scan chooser, never selection or cameras',
      (tester) async {
        await phone(tester);
        const channel = MethodChannel('com.example.misbar/image_capture');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final navigator = GlobalKey<NavigatorState>();
        final observer = _NavigationObserver();
        final labelScanner = AllergenScannerService(apiService: api);
        addTearDown(labelScanner.dispose);
        const dishScanner = PreviewDishScanService(
          DishPreviewScenario.matching,
          stageDelay: Duration.zero,
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer],
            home: const AllergySelectionScreen(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        final home = tester.widget<DishHomeScreen>(find.byType(DishHomeScreen));
        final homeRoute = ModalRoute.of(
          tester.element(find.byType(DishHomeScreen)),
        )!;
        expect(homeRoute.settings.name, scanHomeRoute);
        final isDish = failure is DishScanFailure;
        await tester.tap(
          find.text(isDish ? 'Scan Dish' : 'Scan Packaged Food Label'),
        );
        // The label viewfinder has a repeating animation; wait only for the route.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byType(isDish ? DishCaptureScreen : ImageCaptureScreen),
          findsOneWidget,
        );
        final image = Uint8List.fromList([1, 2, 3]);
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => isDish
                ? DishErrorScreen(
                    failure: failure,
                    userAllergens: const ['Milk'],
                    scanner: dishScanner,
                    imageBytes: image,
                  )
                : ErrorScreen(
                    type: failure as ErrorType,
                    imageBytes: image,
                    userAllergens: const ['Milk'],
                    scannerService: labelScanner,
                  ),
          ),
        );
        await tester.pumpAndSettle();
        final pushesBeforeReturn = observer.pushes;
        await tester.ensureVisible(find.text('Back to Home'));
        await tester.tap(find.text('Back to Home'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
        expect(
          identical(
            tester.widget<DishHomeScreen>(find.byType(DishHomeScreen)),
            home,
          ),
          isTrue,
        );
        expect(
          identical(
            ModalRoute.of(tester.element(find.byType(DishHomeScreen))),
            homeRoute,
          ),
          isTrue,
        );
        expect(find.text('Scan Dish'), findsOneWidget);
        expect(find.text('Scan Packaged Food Label'), findsOneWidget);
        expect(find.byType(AllergySelectionScreen), findsNothing);
        expect(
          find.byType(DishCaptureScreen, skipOffstage: false),
          findsNothing,
        );
        expect(
          find.byType(ImageCaptureScreen, skipOffstage: false),
          findsNothing,
        );
        expect(find.byType(ErrorScreen, skipOffstage: false), findsNothing);
        expect(find.byType(DishErrorScreen, skipOffstage: false), findsNothing);
        expect(
          find.byType(DishHomeScreen, skipOffstage: false),
          findsOneWidget,
        );
        expect(observer.pushes, pushesBeforeReturn);
        expect(
          client.requests.where((r) => r.request.url.path.startsWith('/scan/')),
          isEmpty,
        );
        // The original selection route remains beneath the original home route.
        await tester.tap(find.text('My Allergies'));
        await tester.pumpAndSettle();
        expect(find.byType(AllergySelectionScreen), findsOneWidget);
        expect(
          tester
              .widget<AllergySelectionScreen>(
                find.byType(AllergySelectionScreen),
              )
              .manageAllergies,
          isTrue,
        );
        expect(observer.pushes, pushesBeforeReturn + 1);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
        expect(
          find.byType(DishHomeScreen, skipOffstage: false),
          findsOneWidget,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(AllergySelectionScreen), findsOneWidget);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(observer.pushes, pushesBeforeReturn + 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final code in [404, 500, 503]) {
    testWidgets(
      'Label $code error stays private, retries the same image and returns to existing scan home',
      (tester) async {
        await phone(tester);
        final navigator = GlobalKey<NavigatorState>();
        final observer = _NavigationObserver();
        final scanner = AllergenScannerService(apiService: api);
        addTearDown(scanner.dispose);
        final image = Uint8List.fromList('MOCK_LABEL_IMAGE'.codeUnits);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer],
            home: const AllergySelectionScreen(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
        client.nextStatus = code;
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => ScanningScreen(
              imageBytes: image,
              userAllergens: const ['Milk'],
              scannerService: scanner,
            ),
          ),
        );
        // Flush asynchronous response cancellation before settling animations;
        // a rejected HTTP response must not wait for the scan deadline.
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(find.byType(ErrorScreen), findsOneWidget);
        expect(find.byType(ScanResultScreen), findsNothing);
        expect(find.text('Connection Error'), findsOneWidget);
        expect(
          find.text(
            'Unable to complete the scan. Please check your connection and try again.',
          ),
          findsOneWidget,
        );
        expect(find.text('Try Again'), findsOneWidget);
        expect(find.textContaining('Test failure'), findsNothing);
        expect(find.textContaining('ApiException'), findsNothing);
        expect(find.textContaining('StackTrace'), findsNothing);
        expect(find.textContaining('$code'), findsNothing);
        expect(find.text('No Matching Allergens'), findsNothing);
        expect(
          identical(
            tester.widget<ErrorScreen>(find.byType(ErrorScreen)).imageBytes,
            image,
          ),
          isTrue,
        );
        List<RecordedRequest> scans() => client.requests
            .where((r) => r.request.url.path == '/scan/image')
            .toList();
        expect(scans(), hasLength(1));
        await tester.pump(const Duration(seconds: 3));
        expect(scans(), hasLength(1));
        client.nextStatus = code;
        await tester.tap(find.text('Try Again'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(scans(), hasLength(2));
        expect(
          scans().every((r) => r.body.contains('MOCK_LABEL_IMAGE')),
          isTrue,
        );
        expect(find.byType(ErrorScreen), findsOneWidget);
        expect(find.byType(ScanResultScreen), findsNothing);
        final pushesBeforeHome = observer.pushes;
        await tester.tap(find.text('Back to Home'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
        expect(find.byType(AllergySelectionScreen), findsNothing);
        expect(
          find.byType(DishHomeScreen, skipOffstage: false),
          findsOneWidget,
        );
        expect(observer.pushes, pushesBeforeHome);
        expect(
          client.requests.where(
            (r) =>
                r.request.method == 'GET' &&
                r.request.url.path == '/users/me/allergies',
          ),
          hasLength(1),
        );
        await tester.tap(find.text('My Allergies'));
        await tester.pumpAndSettle();
        expect(find.byType(AllergySelectionScreen), findsOneWidget);
        expect(
          tester
              .widget<AllergySelectionScreen>(
                find.byType(AllergySelectionScreen),
              )
              .manageAllergies,
          isTrue,
        );
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(DishHomeScreen), findsOneWidget);
        expect(
          find.byType(DishHomeScreen, skipOffstage: false),
          findsOneWidget,
        );
        expect(observer.pushes, pushesBeforeHome + 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Empty successful retrieval starts unselected and cannot continue until saved',
    (tester) async {
      await phone(tester);
      client.savedAllergies = [];
      // A prior local session must not create misleading defaults.
      AllergyService().setLocalAllergies(['Milk']);
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      for (final category in AllergenDetection.categories) {
        expect(
          find.text(AllergenDetection.displayName(category.name)),
          findsOneWidget,
        );
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
      expect(client.requests.where((r) => r.request.method == 'PUT'), isEmpty);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsNothing);
      expect(
        find.text('Select at least one allergen to continue.'),
        findsWidgets,
      );
      await tester.ensureVisible(find.text('Egg'));
      await tester.tap(find.text('Egg'));
      await tester.pumpAndSettle();
      expect(client.savedAllergies, ['Egg']);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
      expect(
        tester
            .widget<DishHomeScreen>(find.byType(DishHomeScreen))
            .userAllergens,
        ['Egg'],
      );
    },
  );

  testWidgets('Previously saved canonical selections are restored exactly', (
    tester,
  ) async {
    await phone(tester);
    client.savedAllergies = ['Crustaceans', 'Molluscs', 'Peanut', 'Tree nuts'];
    await tester.pumpWidget(const MaterialApp(home: AllergySelectionScreen()));
    await tester.pumpAndSettle();
    for (final name in client.savedAllergies) {
      expect(tester.widget<Text>(find.text(name)).style!.color, Colors.white);
    }
    expect(
      tester.widget<Text>(find.text('Milk')).style!.color,
      isNot(Colors.white),
    );
    expect(client.requests.where((r) => r.request.method == 'PUT'), isEmpty);
  });

  testWidgets('The last allergen cannot be removed or saved as an empty list', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(const MaterialApp(home: AllergySelectionScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Milk'));
    await tester.pumpAndSettle();
    expect(client.savedAllergies, ['Milk']);
    expect(client.requests.where((r) => r.request.method == 'PUT'), isEmpty);
    expect(tester.widget<Text>(find.text('Milk')).style!.color, Colors.white);
    expect(find.textContaining('Select at least one allergen.'), findsWidgets);
  });

  testWidgets(
    'A failed retrieval shows an error, blocks navigation and can retry',
    (tester) async {
      await phone(tester);
      client.nextStatus = 503;
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not load your saved allergies. Please retry before continuing.',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(AllergyService().currentAllergies, isNull);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsNothing);
      expect(client.requests.where((r) => r.request.method == 'PUT'), isEmpty);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('Milk')).style!.color, Colors.white);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsOneWidget);
    },
  );

  testWidgets(
    'Legacy saved names fail visibly without guessing or rewriting them',
    (tester) async {
      await phone(tester);
      client.savedAllergies = ['Dairy allergy'];
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your saved allergy selections are invalid.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsNothing);
      expect(client.savedAllergies, ['Dairy allergy']);
      expect(client.requests.where((r) => r.request.method == 'PUT'), isEmpty);
    },
  );

  testWidgets('Continue stays blocked while saved selections are loading', (
    tester,
  ) async {
    await phone(tester);
    final pending = Completer<http.StreamedResponse>();
    client.pendingAllergies = pending;
    await tester.pumpWidget(const MaterialApp(home: AllergySelectionScreen()));
    await tester.pump();
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Continue'),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Milk'), findsNothing);
    pending.complete(
      LifecycleHttpClient.response({
        'allergies': ['Egg'],
      }),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('Egg')).style!.color, Colors.white);
    expect(client.requests.where((r) => r.request.method == 'PUT'), isEmpty);
  });

  testWidgets(
    'Continue waits for a nonempty save and blocks a failed confirmation',
    (tester) async {
      await phone(tester);
      client.savedAllergies = [];
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      final pending = Completer<http.StreamedResponse>();
      client.pendingSave = pending;
      await tester.tap(find.text('Milk'));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.byType(DishHomeScreen), findsNothing);
      pending.complete(LifecycleHttpClient.response({'allergies': []}));
      await tester.pumpAndSettle();
      expect(find.byType(DishHomeScreen), findsNothing);
      expect(
        find.textContaining('Could not confirm your saved allergies.'),
        findsOneWidget,
      );
      expect(client.requests.where((r) => r.request.method == 'PUT').length, 1);
    },
  );

  for (final exit in ['cancel', 'header', 'system', 'dispose']) {
    for (final fail in [false, true]) {
      testWidgets('$exit ignores a late label ${fail ? 'error' : 'result'}', (
        tester,
      ) async {
        await phone(tester);
        final pending = _PendingApi();
        final scanner = AllergenScannerService(apiService: pending);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ScanningScreen(
                        imageBytes: Uint8List.fromList([1, 2, 3]),
                        userAllergens: const ['Milk'],
                        scannerService: scanner,
                      ),
                    ),
                  ),
                  child: const Text('Start label scan'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start label scan'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(pending.imageCalls, 1);
        switch (exit) {
          case 'cancel':
            await tester.tap(find.text('Cancel'));
          case 'header':
            await tester.tap(find.byTooltip('Back'));
          case 'system':
            await navigator.currentState!.maybePop();
          case 'dispose':
            await tester.pumpWidget(const MaterialApp(home: Text('Closed')));
        }
        await tester.pumpAndSettle();
        if (fail) {
          pending.result.completeError(ApiException(503, 'Local test error'));
        } else {
          pending.result.complete(
            ScanResult.fromJson(LifecycleHttpClient.scanBody),
          );
        }
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(ScanResultScreen), findsNothing);
        expect(find.byType(ErrorScreen), findsNothing);
        expect(tester.takeException(), isNull);
        // Leaving a scan cancels that request; the screen's scanner is reusable.
        expect((await scanner.scanText('New scan')).success, isTrue);
        scanner.dispose();
      });
    }
  }

  testWidgets('Leaving while Firebase token is pending never starts a scan', (
    tester,
  ) async {
    await phone(tester);
    final pending = _PendingApi();
    final scanner = AllergenScannerService(apiService: pending);
    final token = Completer<String?>();
    auth.pendingToken = token;
    await tester.pumpWidget(
      MaterialApp(
        home: ScanningScreen(
          imageBytes: Uint8List(0),
          userAllergens: const ['Milk'],
          scannerService: scanner,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    token.complete('local-test-token');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(pending.imageCalls, 0);
    expect(tester.takeException(), isNull);
    scanner.dispose();
  });
}

class _PendingApi implements ApiService {
  final result = Completer<ScanResult>();
  int imageCalls = 0;

  @override
  Future<ScanResult> scanImageWithProgress(
    Uint8List imageBytes, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) => scanImageBytes(imageBytes);

  @override
  Future<ScanResult> scanImageBytes(Uint8List imageBytes) {
    imageCalls++;
    return result.future;
  }

  @override
  Future<ScanResult> scanText(String text) async =>
      ScanResult.fromJson(LifecycleHttpClient.scanBody);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NavigationObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}
