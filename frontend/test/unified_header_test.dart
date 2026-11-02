import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/features/dish_scan/dish_capture_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_error_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_home_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_result.dart';
import 'package:misbar_app/features/dish_scan/dish_result_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_scan_service.dart';
import 'package:misbar_app/features/dish_scan/dish_scanning_screen.dart';
import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/screens/allergy_selection_screen.dart';
import 'package:misbar_app/screens/create_account_screen.dart';
import 'package:misbar_app/screens/error_screen.dart';
import 'package:misbar_app/screens/image_capture_screen.dart';
import 'package:misbar_app/screens/login_screen.dart';
import 'package:misbar_app/screens/scan_result_screen.dart';
import 'package:misbar_app/screens/scanning_screen.dart';
import 'package:misbar_app/screens/welcome_screen.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';
import 'package:misbar_app/services/allergy_service.dart';
import 'package:misbar_app/services/api_service.dart';
import 'package:misbar_app/theme/app_colors.dart';
import 'package:misbar_app/widgets/app_header.dart';

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
    client.requests.clear();
    client.savedAllergies = ['Milk'];
    AllergyService().clearSession();
  });
  tearDownAll(() => api.dispose());

  final screens = <String, Widget Function()>{
    'Home': () => DishHomeScreen(
      displayName: 'Test User',
      userAllergens: const ['Milk'],
      onScanLabel: () {},
      onManageAllergies: () {},
      onLogout: () {},
    ),
    'Welcome': () => const WelcomeScreen(),
    'Login': () => const LoginScreen(),
    'Create Account': () => const CreateAccountScreen(),
    'Allergy Selection': () => const AllergySelectionScreen(),
    'My Allergies': () => const AllergySelectionScreen(manageAllergies: true),
    'Dish Capture': () => DishCaptureScreen(
      userAllergens: const ['Milk'],
      scanner: _PendingDish(),
    ),
    'Dish Loading': () => DishScanningScreen(
      imageBytes: Uint8List(0),
      userAllergens: const ['Milk'],
      scanner: _PendingDish(),
    ),
    'Dish Result': () => DishResultScreen(
      result: DishResult.fromJson(previewDishResponse()),
      userAllergens: const ['Milk'],
      scanner: _PendingDish(),
    ),
    'Dish Error': () => DishErrorScreen(
      failure: DishScanFailure.connection,
      userAllergens: const ['Milk'],
      scanner: _PendingDish(),
    ),
    'Label Capture': () => ImageCaptureScreen(
      userAllergens: const ['Milk'],
      scannerService: AllergenScannerService(apiService: _PendingLabelApi()),
    ),
    'Label Loading': () => ScanningScreen(
      imageBytes: Uint8List(0),
      userAllergens: const ['Milk'],
      scannerService: AllergenScannerService(apiService: _PendingLabelApi()),
    ),
    'Label Result': () => ScanResultScreen(
      result: ScanResult.fromJson(LifecycleHttpClient.scanBody),
      imageBytes: Uint8List(0),
      userAllergens: const ['Milk'],
      scannerService: AllergenScannerService(apiService: _PendingLabelApi()),
    ),
    'Label Error': () => ErrorScreen(
      type: ErrorType.connectionError,
      imageBytes: Uint8List(0),
      userAllergens: const ['Milk'],
      scannerService: AllergenScannerService(apiService: _PendingLabelApi()),
    ),
  };

  for (final width in [320.0, 600.0]) {
    for (final textScale in [1.0, 1.6]) {
      for (final entry in screens.entries) {
        testWidgets(
          '${entry.key}: same header at width $width and text $textScale',
          (tester) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  fontFamily: 'Roboto',
                  useMaterial3: true,
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: AppColors.primaryGreen,
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    padding: const EdgeInsets.only(top: 30, bottom: 20),
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: child!,
                ),
                home: entry.value(),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            final header = find.byType(AppHeader);
            expect(header, findsOneWidget);
            final rect = tester.getRect(header);
            expect(rect.left, 0);
            expect(rect.top, 30);
            expect(rect.width, width);
            expect(rect.height, closeTo(28 + 99 * textScale, 0.01));
            final logo = find.byKey(const ValueKey('app-header-logo'));
            expect(logo, findsOneWidget);
            final logoRect = tester.getRect(logo);
            expect(logoRect.width, closeTo(94, 0.01));
            expect(logoRect.height, closeTo(72, 0.01));
            expect(logoRect.right, width - 24);
            expect(
              logoRect.center.dy,
              closeTo(30 + 12 + 99 * textScale / 2, 0.01),
            );
            final image = tester.widget<Image>(
              find.descendant(of: header, matching: find.byType(Image)),
            );
            expect(image.width, 94);
            expect(image.height, 72);
            expect(image.fit, BoxFit.none);
            final background = tester.widget<ColoredBox>(
              find
                  .descendant(of: header, matching: find.byType(ColoredBox))
                  .first,
            );
            expect(background.color, Colors.white);
            // Native capture must receive geometry from the rendered header,
            // including the same accessibility text scaling as every route.
            final native = AppHeader.nativeAppearance(tester.element(header));
            expect(
              (native['contentHeight'] as double) +
                  (native['paddingTop'] as double) +
                  (native['paddingBottom'] as double),
              closeTo(rect.height, 0.01),
            );
            expect(native['logoWidth'], closeTo(logoRect.width, 0.01));
            expect(native['logoHeight'], closeTo(logoRect.height, 0.01));
            expect(
              native['paddingRight'],
              closeTo(rect.right - logoRect.right, 0.01),
            );
            expect(native['backgroundColor'], background.color.toARGB32());
            if (['Welcome', 'Login', 'Create Account'].contains(entry.key)) {
              expect(
                find.descendant(
                  of: header,
                  matching: find.textContaining('Hi,'),
                ),
                findsNothing,
              );
              expect(
                find.descendant(of: header, matching: find.text('Log Out')),
                findsNothing,
              );
              expect(
                find.descendant(
                  of: header,
                  matching: find.byIcon(Icons.logout_rounded),
                ),
                findsNothing,
              );
            }
            expect(
              client.requests.every((r) => r.request.method == 'GET'),
              isTrue,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          },
        );
      }
    }
  }

  testWidgets(
    'Shared Back and Logout actions keep their callbacks and aligned targets',
    (tester) async {
      var backs = 0;
      var logouts = 0;
      Rect? expected;
      for (final logout in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: AppHeader(
                  onBack: () => backs++,
                  onLogout: logout ? () => logouts++ : null,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byTooltip(logout ? 'Log Out' : 'Back');
        final bounds = tester.getRect(button);
        expect(bounds.size, const Size(48, 48));
        expect(bounds.left, 24);
        if (expected != null) expect(bounds, expected);
        expected = bounds;
        await tester.tap(button);
      }
      expect(backs, 1);
      expect(logouts, 1);
    },
  );

  testWidgets('Logo actually paints after the saved-allergy loading rebuild', (
    tester,
  ) async {
    final pending = Completer<http.StreamedResponse>();
    client.pendingAllergies = pending;
    addTearDown(() => client.pendingAllergies = null);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: const MaterialApp(
          home: AllergySelectionScreen(manageAllergies: true),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/images/misbar_logo.png'),
        tester.element(find.byType(AppHeader)),
      ),
    );
    pending.complete(
      LifecycleHttpClient.response({
        'allergies': ['Milk'],
      }),
    );
    await tester.pumpAndSettle();
    final logoRect = tester.getRect(
      find.byKey(const ValueKey('app-header-logo')),
    );
    final paintedPixels = await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var count = 0;
      for (var y = logoRect.top.ceil(); y < logoRect.bottom.floor(); y++) {
        for (var x = logoRect.left.ceil(); x < logoRect.right.floor(); x++) {
          final offset = (y * image.width + x) * 4;
          if (bytes.getUint8(offset) < 230 ||
              bytes.getUint8(offset + 1) < 230 ||
              bytes.getUint8(offset + 2) < 230) {
            count++;
          }
        }
      }
      image.dispose();
      return count;
    });
    expect(paintedPixels, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Signed-out allergy screen never adds a name or Logout to the header',
    (tester) async {
      auth.signedIn = false;
      await tester.pumpWidget(
        const MaterialApp(home: AllergySelectionScreen()),
      );
      await tester.pumpAndSettle();
      final header = find.byType(AppHeader);
      expect(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.logout_rounded),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: header, matching: find.textContaining('Hi,')),
        findsNothing,
      );
      expect(client.requests, isEmpty);
    },
  );
}

class _PendingDish implements DishScanService {
  @override
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  }) => Completer<DishResult>().future;
}

class _PendingLabelApi implements ApiService {
  @override
  Future<ScanResult> scanImageWithProgress(
    Uint8List imageBytes, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) => scanImageBytes(imageBytes);

  @override
  Future<ScanResult> scanImageBytes(Uint8List imageBytes) =>
      Completer<ScanResult>().future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
