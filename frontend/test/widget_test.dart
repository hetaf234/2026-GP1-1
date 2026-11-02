import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/main_dish_preview.dart' as preview;
import 'package:misbar_app/features/dish_scan/dish_home_screen.dart';
import 'package:misbar_app/screens/welcome_screen.dart';
import 'package:misbar_app/screens/login_screen.dart';
import 'package:misbar_app/screens/create_account_screen.dart';
import 'package:misbar_app/screens/allergy_selection_screen.dart';
import 'package:misbar_app/services/api_service.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/theme/app_colors.dart';

import 'support/http_lifecycle_doubles.dart';

class _ErrorAuth extends TestAuth {
  int signInCalls = 0;
  int signUpCalls = 0;

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    signInCalls++;
    throw FirebaseAuthException(code: 'invalid-credential');
  }

  @override
  Future<UserCredentialPlatform> createUserWithEmailAndPassword(
    String email,
    String password,
  ) async {
    signUpCalls++;
    throw FirebaseAuthException(code: 'email-already-in-use');
  }
}

void main() {
  late _ErrorAuth auth;
  late LifecycleHttpClient client;
  late ApiService api;

  setUpAll(() async {
    await initializeTestAuth();
    auth = _ErrorAuth();
    FirebaseAuthPlatform.instance = auth;
    client = LifecycleHttpClient();
    api = http.runWithClient(ApiService.new, () => client);
  });

  setUp(() {
    auth.signInCalls = 0;
    auth.signUpCalls = 0;
    client.requests.clear();
    client.nextStatus = null;
    client.savedAllergies = [];
  });

  tearDownAll(() => api.dispose());

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  test('Offline entrypoint refuses a normal non-preview build', () {
    expect(preview.main, throwsStateError);
  });

  for (final (sample, expectedTitle) in const [
    (preview.OfflineScanPreviewCase.dishMatches, 'Matching Allergens Found'),
    (preview.OfflineScanPreviewCase.dishNoMatches, 'No Matching Allergens'),
    (preview.OfflineScanPreviewCase.dishLowQuality, 'Low Image Quality'),
    (preview.OfflineScanPreviewCase.dishNotSingle, 'Not a Single Dish'),
    (preview.OfflineScanPreviewCase.dishUnsupported, 'Unsupported Dish'),
    (preview.OfflineScanPreviewCase.dishConnection, 'Connection Error'),
    (preview.OfflineScanPreviewCase.labelMatches, 'Matching Allergens Found'),
    (preview.OfflineScanPreviewCase.labelNoMatches, 'No Matching Allergens'),
    (
      preview.OfflineScanPreviewCase.labelMissingDetails,
      'Matching Allergens Found',
    ),
    (preview.OfflineScanPreviewCase.labelIncomplete, 'Analysis Incomplete'),
    (preview.OfflineScanPreviewCase.labelLowQuality, 'Image Not Clear'),
    (preview.OfflineScanPreviewCase.labelNoText, 'Label Could Not Be Read'),
    (
      preview.OfflineScanPreviewCase.labelNoIngredients,
      'Label Could Not Be Read',
    ),
    (preview.OfflineScanPreviewCase.labelConnection, 'Connection Error'),
  ]) {
    testWidgets(
      'Offline gallery ${sample.name} opens and returns to same home',
      (tester) async {
        await phone(tester);
        await tester.pumpWidget(const preview.OfflineScanResultsPreview());
        await tester.pumpAndSettle();
        final home = tester.element(find.byType(DishHomeScreen));
        final choice = find.byKey(ValueKey('offline-case-${sample.name}'));
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(find.text(expectedTitle), findsOneWidget);
        expect(find.text('Safe for You!'), findsNothing);
        expect(find.textContaining('Cereals containing gluten'), findsNothing);
        if (sample == preview.OfflineScanPreviewCase.dishMatches ||
            sample == preview.OfflineScanPreviewCase.labelMatches) {
          expect(find.text('Gluten'), findsOneWidget);
          expect(find.text('Wheat flour'), findsNothing);
          await tester.ensureVisible(find.text('Gluten'));
          await tester.tap(find.text('Gluten'));
          await tester.pumpAndSettle();
          expect(find.text('Wheat flour'), findsOneWidget);
        }
        if (sample == preview.OfflineScanPreviewCase.labelMissingDetails) {
          expect(
            find.byKey(const ValueKey('label-allergen-Milk')),
            findsOneWidget,
          );
        }
        expect(client.requests, isEmpty);
        await tester.ensureVisible(find.text('Back to Home'));
        await tester.tap(find.text('Back to Home'));
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(DishHomeScreen)), same(home));
        expect(
          find.byType(DishHomeScreen, skipOffstage: false),
          findsOneWidget,
        );
        expect(
          ModalRoute.of(tester.element(find.byType(DishHomeScreen)))!
              .settings
              .name,
          '/scan-home',
        );
        expect(client.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('App loads initial welcome screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
    for (final allergen in AllergenDetection.categories) {
      expect(
        find.text(AllergenDetection.displayName(allergen.name)),
        findsOneWidget,
      );
    }
    expect(find.text('Gluten'), findsOneWidget);
    expect(find.textContaining('Cereals containing gluten'), findsNothing);
    for (final oldName in ['Dairy', 'Nuts', 'Shellfish']) {
      expect(find.text(oldName), findsNothing);
    }
    await tester.ensureVisible(
      find.text(AllergenDetection.categories.last.name),
    );
    await tester.pumpAndSettle();
    final strip = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(strip.position.axis, Axis.horizontal);
    expect(strip.position.pixels, greaterThan(0));
    expect(client.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  ({EdgeInsetsGeometry? padding, Decoration? decoration, TextStyle? textStyle})
  bannerStyle(WidgetTester tester, String message) {
    final text = find.text(message);
    expect(text, findsOneWidget);
    final banner = find
        .ancestor(of: text, matching: find.byType(Container))
        .first;
    final container = tester.widget<Container>(banner);
    expect(
      find.descendant(of: banner, matching: find.byIcon(Icons.error_outline)),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    return (
      padding: container.padding,
      decoration: container.decoration,
      textStyle: tester.widget<Text>(text).style,
    );
  }

  testWidgets(
    'Login, new account and allergy errors have identical presentation and unchanged wording',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'demo@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'Example1!');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Log In'));
      await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
      await tester.pumpAndSettle();
      final loginStyle = bannerStyle(tester, 'Invalid email or password.');
      expect(auth.signInCalls, 1);
      expect(client.requests, isEmpty);

      await tester.pumpWidget(const MaterialApp(home: CreateAccountScreen()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'UI Demo');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'demo@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(2), 'Example1!');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Continue'));
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(
        bannerStyle(
          tester,
          'An account already exists for this email address.',
        ),
        loginStyle,
      );
      expect(auth.signUpCalls, 1);
      expect(client.requests, isEmpty);

      client.nextStatus = 503;
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      expect(
        bannerStyle(
          tester,
          'Could not load your saved allergies. Please retry before continuing.',
        ),
        loginStyle,
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        bannerStyle(tester, 'Select at least one allergen to continue.'),
        loginStyle,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'All five password checks update while typing, pasting and deleting',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(const MaterialApp(home: CreateAccountScreen()));
      await tester.pumpAndSettle();
      final password = find.byType(TextFormField).at(2);
      const examples = <String, int>{
        '': 0,
        'A': 1,
        'Ab': 2,
        'Ab1': 3,
        'Ab1!': 4,
        'Abcdef1!': 5,
        'abcdef1!': 4,
        'ABCDEF1!': 4,
        'Abcdefg!': 4,
        'Abcdef12': 4,
        'Abcdef1 ': 4,
        'Abcdef1ع': 4,
        'Abcdef1_': 5,
        'Abcdef1-': 5,
      };
      for (final example in examples.entries) {
        await tester.enterText(password, example.key);
        await tester.pump();
        expect(
          find.byIcon(Icons.check_circle_rounded),
          findsNWidgets(example.value),
          reason: example.key,
        );
        expect(
          find.byIcon(Icons.radio_button_unchecked),
          findsNWidgets(5 - example.value),
          reason: example.key,
        );
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: password, matching: find.byType(TextField)),
              )
              .obscureText,
          isTrue,
        );
      }
      await tester.enterText(password, '');
      await tester.pump();
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      expect(auth.signUpCalls, 0);
      expect(client.requests, isEmpty);
    },
  );

  testWidgets('Each unmet password requirement prevents account creation', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(const MaterialApp(home: CreateAccountScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'UI Demo');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'demo@example.com',
    );
    for (final password in [
      'Ab1!',
      'abcdef1!',
      'ABCDEF1!',
      'Abcdefg!',
      'Abcdef12',
    ]) {
      await tester.enterText(find.byType(TextFormField).at(2), password);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Continue'));
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(auth.signUpCalls, 0);
      expect(
        find.text(
          'Please ensure password meets all requirements (8+ characters, uppercase, lowercase, number, special character).',
        ),
        findsOneWidget,
      );
    }
    await tester.enterText(find.byType(TextFormField).at(2), 'Abcdef1!');
    await tester.pump();
    expect(
      find.text(
        'Please ensure password meets all requirements (8+ characters, uppercase, lowercase, number, special character).',
      ),
      findsNothing,
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Continue'));
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(auth.signUpCalls, 1);
    expect(client.requests, isEmpty);
  });

  testWidgets(
    'A combined emoji is one character and a symbol; spaces are not symbols',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(const MaterialApp(home: CreateAccountScreen()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'Aa1!👨‍👩‍👧‍👦',
      );
      await tester.pump();
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(4));
      expect(
        tester.widget<Text>(find.text('8 or more characters')).style!.color,
        AppColors.textMuted,
      );
      await tester.enterText(find.byType(TextFormField).at(2), 'Abcdef1 ');
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.text('At least one special character'))
            .style!
            .color,
        AppColors.textMuted,
      );
    },
  );
  testWidgets('Password feedback remains usable above the phone keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(const MaterialApp(home: CreateAccountScreen()));
    await tester.pumpAndSettle();
    final password = find.byType(TextFormField).at(2);
    await tester.showKeyboard(password);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.enterText(password, 'Abcdef1!');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(5));
    expect(
      tester.getBottomLeft(find.text('At least one special character')).dy,
      lessThanOrEqualTo(520),
    );
    expect(tester.takeException(), isNull);
    expect(auth.signUpCalls, 0);
  });
}
