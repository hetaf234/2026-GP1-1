import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:misbar_app/features/dish_scan/dish_capture_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_error_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_home_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_result.dart';
import 'package:misbar_app/features/dish_scan/dish_result_screen.dart';
import 'package:misbar_app/features/dish_scan/dish_scan_service.dart';
import 'package:misbar_app/features/dish_scan/dish_http_service.dart';
import 'package:misbar_app/features/dish_scan/dish_scanning_screen.dart';
import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';
import 'package:misbar_app/theme/app_colors.dart';

import 'support/dish_response_fixtures.dart';

const shotKey = ValueKey('preview-boundary');

Widget wrap(Widget child, {double textScale = 1}) => RepaintBoundary(
  key: shotKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: Colors.white,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryGreen),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: child,
  ),
);

Future<void> screenshot(WidgetTester tester, String name) async {
  final directory = Platform.environment['DISH_PREVIEW_SCREENSHOT_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    await precacheImage(
      const AssetImage('assets/images/misbar_logo.png'),
      tester.element(find.byType(MaterialApp)),
    );
  });
  await tester.pump();
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(shotKey),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = File('$directory/$name.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUpAll(() async {
    final fontFile = Platform.environment['DISH_PREVIEW_FONT_FILE'];
    if (fontFile != null) {
      final loader = FontLoader('Roboto');
      loader.addFont(File(fontFile).readAsBytes().then(ByteData.sublistView));
      await loader.load();
      final iconFont = File(fontFile).parent.uri
          .resolve('MaterialIcons-Regular.otf')
          .toFilePath();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(File(iconFont).readAsBytes().then(ByteData.sublistView));
      await icons.load();
    }
  });
  const scanner = PreviewDishScanService(
    DishPreviewScenario.matching,
    stageDelay: Duration.zero,
  );

  testWidgets('Dish displays Gluten and preserves canonical evidence', (
    tester,
  ) async {
    await phone(tester);
    const canonical = 'Cereals containing gluten';
    final response = matchedResponse();
    final profile = response['personalization'];
    final match = profile['matches'][0];
    match['allergen'] = canonical;
    final cause = match['causes'][0];
    cause['ingredient'] = 'Wheat flour';
    cause['evidence'][0]['allergens'] = [canonical];
    cause['original_members'][0]['evidence'][0]['allergens'] = [canonical];
    profile['selected_allergies'] = [canonical];
    profile['matches'] = [match];
    final original = jsonDecode(jsonEncode(response));
    final result = DishResult.fromJson(response);
    await tester.pumpWidget(
      wrap(
        DishResultScreen(
          result: result,
          userAllergens: const [canonical],
          scanner: scanner,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Gluten'), findsOneWidget);
    expect(find.text('Wheat flour'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('dish-allergen-Cereals containing gluten')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Wheat flour'), findsOneWidget);
    expect(
      find.text('1 allergen matches your registered allergies.'),
      findsOneWidget,
    );
    expect(find.textContaining(canonical), findsNothing);
    expect(result.selectedAllergies, [canonical]);
    expect(result.matches.single.allergens, [canonical]);
    expect(result.matches.single.causes.single.evidence['allergens'], [
      canonical,
    ]);
    expect(result.matches.single.causes.single.confidence, 25);
    expect(result.personalization['safety_assessment'], 'not_established');
    expect(response, original);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Dish groups duplicate and shared ingredient causes by matched allergen without changing evidence',
    (tester) async {
      await phone(tester);
      final response =
          jsonDecode(jsonEncode(previewDishResponse())) as Map<String, dynamic>;
      final profile = response['personalization'];
      profile['matches'].removeLast();
      profile['selected_allergies'] = ['Egg', 'Milk', 'Fish'];
      for (final match in profile['matches']) {
        final bread =
            jsonDecode(jsonEncode(match['causes'][0])) as Map<String, dynamic>;
        bread['ingredient'] = 'Bread';
        bread['evidence'][0]['original_name'] = 'Bread evidence';
        bread['original_members'][0]['id'] = 'bread-evidence';
        bread['original_members'][0]['name'] = 'Bread evidence';
        match['causes'].add(bread);
        if (match['allergen'] == 'Egg') {
          match['causes'].add(jsonDecode(jsonEncode(bread)));
        } else {
          match['causes'][0]['evidence'][0]['confidence'] = null;
        }
      }
      profile['mapping_disagreements'] = [
        {
          'ingredient': 'Bread',
          'source_allergens': {
            'Dataset': ['Milk'],
            'Claude': ['Egg'],
          },
        },
      ];
      profile['ingredients_without_identified_allergens'] = [
        {'name': 'Garnish', 'members': []},
      ];
      final before = jsonDecode(jsonEncode(response));
      final result = DishResult.fromJson(response);
      final evidenceBefore = jsonEncode([
        for (final match in result.matches)
          [
            for (final cause in match.causes)
              {
                'evidence': cause.evidence,
                'cause': cause.causeRecord,
                'confidence': cause.confidence,
              },
          ],
      ]);
      await tester.pumpWidget(
        wrap(
          DishResultScreen(
            result: result,
            userAllergens: const ['Egg', 'Milk', 'Fish'],
            scanner: scanner,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('2 allergens match your registered allergies.'),
        findsOneWidget,
      );
      for (final allergen in ['Egg', 'Milk']) {
        final card = find.byKey(ValueKey('dish-allergen-$allergen'));
        await tester.ensureVisible(card);
        await tester.tap(
          find.descendant(of: card, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.text(allergen)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('Sauce')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('Bread')),
          findsOneWidget,
        );
      }
      expect(find.byKey(const ValueKey('dish-allergen-Fish')), findsNothing);
      expect(find.byKey(const ValueKey('dish-allergen-Soybean')), findsNothing);
      expect(find.text('Sauce'), findsNWidgets(2));
      expect(find.text('Bread'), findsNWidgets(2));
      await tester.ensureVisible(
        find.byKey(const ValueKey('dish-allergen-Egg')),
      );
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const ValueKey('dish-allergen-Egg')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Bread'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('dish-allergen-Milk')),
          matching: find.text('Bread'),
        ),
        findsOneWidget,
      );
      expect(
        result.matches.singleWhere((m) => m.name == 'Bread').causes,
        hasLength(3),
      );
      expect(result.matches.first.causes.first.confidence, 25);
      expect(result.matches.first.causes.last.confidence, isNull);
      expect(result.personalization, profile);
      expect(result.personalization['safety_assessment'], 'not_established');
      expect(
        jsonEncode([
          for (final match in result.matches)
            [
              for (final cause in match.causes)
                {
                  'evidence': cause.evidence,
                  'cause': cause.causeRecord,
                  'confidence': cause.confidence,
                },
            ],
        ]),
        evidenceBefore,
      );
      expect(response, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Home opens dish capture and preserves label callback', (
    tester,
  ) async {
    await phone(tester);
    var labelOpened = false;
    await tester.pumpWidget(
      wrap(
        DishHomeScreen(
          displayName: 'Noof',
          userAllergens: const ['Egg'],
          onManageAllergies: () {},
          onScanLabel: () => labelOpened = true,
          scanner: scanner,
          preview: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await screenshot(tester, '01-home');
    await tester.tap(find.text('Scan Packaged Food Label'));
    expect(labelOpened, true);
    await tester.tap(find.text('Scan Dish'));
    await tester.pumpAndSettle();
    expect(find.byType(DishCaptureScreen), findsOneWidget);
    await screenshot(tester, '02-capture');
    await tester.ensureVisible(find.text('Preview Sample Result'));
    await tester.tap(find.text('Preview Sample Result'));
    await tester.pumpAndSettle();
    expect(find.byType(DishResultScreen), findsOneWidget);
    for (final allergen in ['Egg', 'Milk', 'Soybean']) {
      final card = find.byKey(ValueKey('dish-allergen-$allergen'));
      await tester.ensureVisible(card);
      await tester.tap(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text(allergen)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Sauce')),
        findsOneWidget,
      );
    }
    expect(find.text('Linked to Gluten'), findsNothing);
    expect(find.text('Flour mixture'), findsNothing);
    expect(find.text('Water'), findsNothing);
    await tester.ensureVisible(find.text('Back to Home'));
    await tester.tap(find.text('Back to Home'));
    await tester.pumpAndSettle();
    expect(find.byType(DishHomeScreen), findsOneWidget);
  });

  testWidgets('Regular home hides preview tools and keeps existing callbacks', (
    tester,
  ) async {
    await phone(tester);
    var labelOpens = 0;
    var profileOpens = 0;
    await tester.pumpWidget(
      wrap(
        DishHomeScreen(
          displayName: 'Noof',
          userAllergens: const ['Egg'],
          onManageAllergies: () => profileOpens++,
          onScanLabel: () => labelOpens++,
          // Even accidentally supplied preview tools must stay off the real UI.
          previewControls: const Text('Preview Settings · Sample outcome'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hi, Noof!'), findsOneWidget);
    expect(find.textContaining('Preview Settings'), findsNothing);
    expect(find.textContaining('Sample outcome'), findsNothing);
    expect(find.textContaining('Sample results'), findsNothing);
    await tester.tap(find.text('My Allergies'));
    expect(profileOpens, 1);
    await tester.tap(find.text('Scan Packaged Food Label'));
    expect(labelOpens, 1);
    await tester.tap(find.text('Scan Dish'));
    await tester.pumpAndSettle();
    final capture = tester.widget<DishCaptureScreen>(
      find.byType(DishCaptureScreen),
    );
    expect(capture.userAllergens, ['Egg']);
    expect(capture.preview, false);
    expect(capture.scanner, isA<HttpDishScanService>());
    expect(find.text('Preview Sample Result'), findsNothing);
  });

  testWidgets(
    'Matching result shows ingredients while keeping extra evidence off the UI',
    (tester) async {
      await phone(tester);
      final payload = previewDishResponse();
      payload['personalization']['mapping_disagreements'] = [
        {'ingredient': 'Sauce'},
      ];
      payload['personalization']['ingredients_without_identified_allergens'] = [
        {'name': 'Unknown garnish'},
      ];
      final result = DishResult.fromJson(payload);
      await tester.pumpWidget(
        wrap(
          DishResultScreen(
            result: result,
            userAllergens: const ['Egg'],
            scanner: scanner,
            preview: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await screenshot(tester, '03-egg-matches');
      expect(find.text('Matching Allergens Found'), findsOneWidget);
      expect(
        find.text('3 allergens match your registered allergies.'),
        findsOneWidget,
      );
      expect(find.text('Flour mixture'), findsNothing);
      expect(find.textContaining('Cereals containing gluten'), findsNothing);
      expect(find.text('Why this matches'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.textContaining('Original ingredient:'), findsNothing);
      expect(find.textContaining('Source:'), findsNothing);
      expect(find.textContaining('Confidence:'), findsNothing);
      expect(
        find.textContaining('Some ingredients have unidentified'),
        findsNothing,
      );
      expect(
        find.text('Misbar can make mistakes. Verify before eating.'),
        findsOneWidget,
      );
      expect(find.text('Sauce'), findsNothing);
      for (final allergen in ['Egg', 'Milk', 'Soybean']) {
        final card = find.byKey(ValueKey('dish-allergen-$allergen'));
        await tester.ensureVisible(card);
        await tester.tap(
          find.descendant(of: card, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('Sauce'), findsNWidgets(3));
      expect(
        result.matches.single.causes.first.originalIngredient,
        'Special sauce',
      );
      expect(result.matches.single.causes.first.confidence, 25);
      expect(result.personalization['mapping_disagreements'], isNotEmpty);
      expect(
        result.personalization['ingredients_without_identified_allergens'],
        isNotEmpty,
      );
      expect(find.textContaining('Flour coating'), findsNothing);
    },
  );

  testWidgets(
    'No-match result does not show full ingredient list or safety claim',
    (tester) async {
      await phone(tester);
      final result = DishResult.fromJson(
        previewDishResponse(hasMatches: false),
      );
      await tester.pumpWidget(
        wrap(
          DishResultScreen(
            result: result,
            userAllergens: const ['Fish'],
            scanner: scanner,
            preview: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No Matching Allergens'), findsOneWidget);
      expect(find.text('Ingredients Matching Your Allergies'), findsNothing);
      expect(find.text('Water'), findsNothing);
      expect(find.text('Safe for You!'), findsNothing);
      expect(
        find.text('Misbar can make mistakes. Verify before eating.'),
        findsOneWidget,
      );
      await screenshot(tester, '04-no-matches');
    },
  );

  testWidgets('Obsolete empty-profile response reaches the error screen', (
    tester,
  ) async {
    await phone(tester);
    final payload = previewDishResponse(hasMatches: false);
    payload['personalization']['selected_allergies'] = <String>[];
    payload['personalization']['match_status'] = 'no_allergies_selected';
    var requests = 0;
    final scanner = HttpDishScanService(
      baseUrl: 'https://local.invalid',
      identityProvider: () async =>
          const DishIdentity('local-test-user', 'local-test-token'),
      clientFactory: () => MockClient((_) async {
        requests++;
        return http.Response(
          '${progressFrames().join()}${outcomeFrame(payload)}',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await tester.pumpWidget(
      wrap(
        DishScanningScreen(
          imageBytes: Uint8List.fromList([1, 2, 3]),
          userAllergens: const ['Egg'],
          scanner: scanner,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DishErrorScreen), findsOneWidget);
    expect(find.byType(DishResultScreen), findsNothing);
    expect(find.text('No Matching Allergens'), findsNothing);
    expect(
      find.text('No allergies are registered in this analysis.'),
      findsNothing,
    );
    expect(find.text('Connection Error'), findsOneWidget);
    expect(requests, 1);
  });

  for (final code in [404, 500, 503]) {
    for (final streamed in [false, true]) {
      testWidgets(
        'Dish $code ${streamed ? 'SSE' : 'HTTP'} failure stays private and retries only on tap',
        (tester) async {
          await phone(tester);
          final image = Uint8List.fromList(utf8.encode('MOCK_DISH_IMAGE'));
          final bodies = <String>[];
          const details = 'PRIVATE_BACKEND_DIAGNOSTIC';
          final scanner = HttpDishScanService(
            baseUrl: 'https://local.invalid',
            identityProvider: () async =>
                const DishIdentity('local-test-user', 'local-test-token'),
            clientFactory: () => MockClient((request) async {
              bodies.add(request.body);
              if (!streamed) {
                return http.Response(
                  jsonEncode({'detail': details}),
                  code,
                  headers: {'content-type': 'application/json'},
                );
              }
              final result = {
                'decision': 'error',
                'stopped_at': 'user_allergy_matching',
                'message': details,
                'personalization': {
                  'status': 'error',
                  'error_code': 'profile_unavailable',
                  'safety_assessment': 'not_established',
                },
              };
              final wire =
                  '${progressFrames().take(5).join()}${event('progress', {'scan_id': 'test-scan', 'sequence': 6, 'stage': 'checking_allergens', 'status': 'error'})}${outcomeFrame(result, status: code)}';
              return http.Response(
                wire,
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }),
          );
          await tester.pumpWidget(
            wrap(
              DishScanningScreen(
                imageBytes: image,
                userAllergens: const ['Egg'],
                scanner: scanner,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(DishErrorScreen), findsOneWidget);
          expect(find.byType(DishResultScreen), findsNothing);
          expect(find.text('Connection Error'), findsOneWidget);
          expect(
            find.text(
              'Unable to complete the scan. Please check your connection and try again.',
            ),
            findsOneWidget,
          );
          expect(find.text('Try Again'), findsOneWidget);
          expect(find.textContaining(details), findsNothing);
          expect(find.textContaining('$code'), findsNothing);
          expect(find.text('No Matching Allergens'), findsNothing);
          expect(
            identical(
              tester
                  .widget<DishErrorScreen>(find.byType(DishErrorScreen))
                  .imageBytes,
              image,
            ),
            isTrue,
          );
          expect(bodies, hasLength(1));
          await tester.pump(const Duration(seconds: 3));
          expect(bodies, hasLength(1));
          await tester.ensureVisible(find.text('Try Again'));
          await tester.tap(find.text('Try Again'));
          await tester.pumpAndSettle();
          expect(bodies, hasLength(2));
          expect(
            bodies.every((body) => body.contains('MOCK_DISH_IMAGE')),
            isTrue,
          );
          expect(find.byType(DishErrorScreen), findsOneWidget);
          expect(find.byType(DishResultScreen), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Progress checkmarks require explicit backend confirmation', (
    tester,
  ) async {
    await phone(tester);
    final scanner = _ControlledScanner();
    await tester.pumpWidget(
      wrap(
        DishScanningScreen(
          imageBytes: Uint8List.fromList([1]),
          userAllergens: const ['Egg'],
          scanner: scanner,
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.check), findsNothing);
    for (var i = 0; i < DishScanStage.values.length; i++) {
      scanner.update(
        DishProgressUpdate(DishScanStage.values[i], DishStageStatus.running),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check), findsNWidgets(i));
      scanner.update(
        DishProgressUpdate(DishScanStage.values[i], DishStageStatus.completed),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check), findsNWidgets(i + 1));
    }
    scanner.pending.complete(DishResult.fromJson(previewDishResponse()));
    await tester.pumpAndSettle();
    expect(find.byType(DishResultScreen), findsOneWidget);
  });

  for (final failure in DishScanFailure.values) {
    testWidgets(
      'Failure ${failure.name} shows an error, never a completed result',
      (tester) async {
        await phone(tester);
        await tester.pumpWidget(
          wrap(
            DishScanningScreen(
              imageBytes: null,
              userAllergens: const ['Egg'],
              scanner: _FailureScanner(failure),
              preview: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DishErrorScreen), findsOneWidget);
        expect(find.byType(DishResultScreen), findsNothing);
        expect(find.text('No Matching Allergens'), findsNothing);
        expect(
          find.text(switch (failure) {
            DishScanFailure.lowQuality =>
              'Image quality is insufficient. Please retake the photo.',
            DishScanFailure.notSingleDish =>
              'Please capture a photo that shows only one dish.',
            DishScanFailure.unsupportedDish =>
              'This dish is currently not supported.',
            DishScanFailure.connection => 'Unable to complete the scan. Please check your connection and try again.',
          }),
          findsOneWidget,
        );
        if (failure == DishScanFailure.lowQuality) {
          await screenshot(tester, '06-unclear-photo');
        }
      },
    );
  }

  testWidgets('Cancellation ignores a late result', (tester) async {
    await phone(tester);
    final pending = Completer<DishResult>();
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DishScanningScreen(
                    imageBytes: null,
                    userAllergens: const ['Egg'],
                    scanner: _PendingScanner(pending),
                  ),
                ),
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await screenshot(tester, '05-analyzing');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    pending.complete(DishResult.fromJson(previewDishResponse()));
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    expect(find.byType(DishResultScreen), findsNothing);
  });

  testWidgets('Compact screen and large text have no layout overflow', (
    tester,
  ) async {
    await phone(tester);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = await scanner.analyze(Uint8List(0), onStage: (_) {});
    for (final screen in <Widget>[
      DishHomeScreen(
        displayName: 'A very long sample name',
        userAllergens: const ['Egg', 'Cereals containing gluten'],
        onManageAllergies: () {},
        onScanLabel: () {},
      ),
      const DishCaptureScreen(
        userAllergens: ['Egg'],
        scanner: scanner,
        preview: true,
      ),
      DishResultScreen(
        result: result,
        userAllergens: const ['Egg'],
        scanner: scanner,
        preview: true,
      ),
      const DishErrorScreen(
        failure: DishScanFailure.notSingleDish,
        userAllergens: ['Egg'],
        scanner: scanner,
      ),
    ]) {
      await tester.pumpWidget(wrap(screen, textScale: 1.4));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: screen.runtimeType.toString(),
      );
    }
  });

  testWidgets(
    'Regular app never displays sample result for unavailable backend',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        wrap(
          const DishCaptureScreen(
            userAllergens: ['Egg'],
            scanner: HttpDishScanService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Preview Sample Result'), findsNothing);
      expect(find.textContaining('Sample results'), findsNothing);
      expect(find.byType(DishResultScreen), findsNothing);
    },
  );
}

class _FailureScanner implements DishScanService {
  final DishScanFailure failure;
  _FailureScanner(this.failure);
  @override
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  }) async => throw DishScanException(failure);
}

class _PendingScanner implements DishScanService {
  final Completer<DishResult> result;
  _PendingScanner(this.result);
  @override
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  }) {
    onStage(
      const DishProgressUpdate(
        DishScanStage.imageReceived,
        DishStageStatus.running,
      ),
    );
    return result.future;
  }
}

class _ControlledScanner implements DishScanService {
  final pending = Completer<DishResult>();
  late void Function(DishProgressUpdate) update;
  @override
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  }) {
    update = onStage;
    return pending.future;
  }
}
