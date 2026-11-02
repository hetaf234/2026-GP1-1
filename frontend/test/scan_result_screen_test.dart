import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/features/dish_scan/dish_widgets.dart';
import 'package:misbar_app/widgets/app_header.dart';
import 'package:misbar_app/screens/scan_result_screen.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';

void main() {
  group('ScanResultScreen Category & Ingredient Formatting', () {
    test(
      'The selection list contains exactly the approved 14 canonical names',
      () {
        expect(AllergenDetection.categories.map((item) => item.name).toSet(), {
          'Celery',
          'Cereals containing gluten',
          'Crustaceans',
          'Egg',
          'Fish',
          'Lupin',
          'Milk',
          'Molluscs',
          'Mustard',
          'Peanut',
          'Sesame',
          'Soybean',
          'Sulphur dioxide and sulphites',
          'Tree nuts',
        });
        expect(AllergenDetection.categories.length, 14);
      },
    );

    test(
      'Only the gluten display label changes; canonical names stay intact',
      () {
        for (final category in AllergenDetection.categories) {
          expect(
            AllergenDetection.displayName(category.name),
            category.name == 'Cereals containing gluten'
                ? 'Gluten'
                : category.name,
          );
        }
        expect(
          AllergenDetection.categories.any((item) => item.name == 'Gluten'),
          isFalse,
        );
      },
    );

    test(
      'capitalize handles lowercase strings and empty strings gracefully',
      () {
        expect(ScanResultScreen.capitalize('milk'), 'Milk');
        expect(ScanResultScreen.capitalize('whey powder'), 'Whey powder');
        expect(ScanResultScreen.capitalize(''), '');
        expect(ScanResultScreen.capitalize('  almonds  '), 'Almonds');
      },
    );

    testWidgets('Groups multiple ingredients in one matched allergen card', (
      WidgetTester tester,
    ) async {
      const result = ScanResult(
        success: true,
        isSafe: false,
        extractedOcrText: 'Ingredients: milk, whey, sugar',
        ingredientList: 'milk, whey, sugar',
        allergensDetected: [
          AllergenDetection(
            allergen: 'Milk',
            matchedIngredients: ['milk', 'whey', 'whey'],
            isUserAllergen: true,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ScanResultScreen(
            result: result,
            imageBytes: Uint8List(0),
            userAllergens: const ['Milk'],
            scannerService: AllergenScannerService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The status, section and shared controls follow the Dish result layout.
      expect(find.text('Matching Allergens Found'), findsOneWidget);
      expect(find.text('Your Label Result'), findsOneWidget);
      expect(find.byType(AppHeader), findsOneWidget);
      expect(find.byType(DishPrimaryButton), findsOneWidget);
      expect(
        find.text('1 allergen matches your registered allergies.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('label-allergen-Milk')), findsOneWidget);
      expect(result.allergensDetected.single.matchedIngredients, [
        'milk',
        'whey',
        'whey',
      ]);

      // Section header
      expect(find.text('Ingredients Matching Your Allergies'), findsOneWidget);

      expect(find.text('Whey'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('label-allergen-Milk')),
      );
      await tester.tap(find.byKey(const ValueKey('label-allergen-Milk')));
      await tester.pumpAndSettle();

      // Ingredients displayed with capitalized text
      expect(find.text('Milk'), findsNWidgets(2));
      expect(find.text('Whey'), findsOneWidget);

      // Canonical names are shown directly.
      expect(find.text('Dairy'), findsNothing);
    });

    testWidgets(
      'Repeated categories merge and unmatched saved allergies get no card',
      (tester) async {
        const result = ScanResult(
          success: true,
          isSafe: false,
          extractedOcrText: 'Unchanged OCR evidence',
          ingredientList: 'Unchanged ingredient evidence',
          allergensDetected: [
            AllergenDetection(
              allergen: 'Milk',
              matchedIngredients: ['whey', 'whey'],
              isUserAllergen: true,
            ),
            AllergenDetection(
              allergen: 'Milk',
              matchedIngredients: ['cream', 'whey'],
              isUserAllergen: true,
            ),
            AllergenDetection(
              allergen: 'Egg',
              matchedIngredients: ['mayonnaise'],
              isUserAllergen: false,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScanResultScreen(
              result: result,
              imageBytes: Uint8List(0),
              userAllergens: const ['Milk', 'Fish'],
              scannerService: AllergenScannerService(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('label-allergen-Milk'));
        await tester.ensureVisible(card);
        await tester.tap(
          find.descendant(of: card, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(find.byKey(const ValueKey('label-allergen-Egg')), findsNothing);
        expect(find.byKey(const ValueKey('label-allergen-Fish')), findsNothing);
        expect(
          find.text('1 allergen matches your registered allergies.'),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('Whey')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('Cream')),
          findsOneWidget,
        );
        expect(find.text('Mayonnaise'), findsNothing);
        expect(result.allergensDetected, hasLength(3));
        expect(result.allergensDetected.first.matchedIngredients, [
          'whey',
          'whey',
        ]);
        expect(result.allergensDetected[1].matchedIngredients, [
          'cream',
          'whey',
        ]);
        expect(result.extractedOcrText, 'Unchanged OCR evidence');
        expect(result.ingredientList, 'Unchanged ingredient evidence');
        expect(result.isSafe, isFalse);
      },
    );

    testWidgets(
      'A match outside the saved profile stays incomplete without cards',
      (tester) async {
        const result = ScanResult(
          success: true,
          isSafe: false,
          extractedOcrText: '',
          ingredientList: '',
          allergensDetected: [
            AllergenDetection(
              allergen: 'Egg',
              matchedIngredients: ['sauce'],
              isUserAllergen: true,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScanResultScreen(
              result: result,
              imageBytes: Uint8List(0),
              userAllergens: const ['Milk'],
              scannerService: AllergenScannerService(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Analysis Incomplete'), findsOneWidget);
        expect(find.text('No Matching Allergens'), findsNothing);
        expect(find.byKey(const ValueKey('label-allergen-Egg')), findsNothing);
        expect(result.allergensDetected.single.isUserAllergen, isTrue);
      },
    );

    testWidgets('Reports no matching allergens without claiming safety', (
      WidgetTester tester,
    ) async {
      const result = ScanResult(
        success: true,
        isSafe: true,
        extractedOcrText: 'Ingredients: sugar, water',
        ingredientList: 'sugar, water',
        allergensDetected: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ScanResultScreen(
            result: result,
            imageBytes: Uint8List(0),
            userAllergens: const ['Milk'],
            scannerService: AllergenScannerService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Matching Allergens'), findsOneWidget);
      expect(
        find.text('Misbar can make mistakes. Verify before eating.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'No allergens matching your registered allergies were identified.',
        ),
        findsOneWidget,
      );
      expect(find.text('Ingredients Matching Your Allergies'), findsNothing);
    });

    test('ScanResult correctly flags low_quality as hasContentError', () {
      final json = {
        'success': false,
        'status': 'low_quality',
        'is_safe': false,
        'extracted_ocr_text': '',
        'ingredient_list': '',
        'allergens_detected': [],
        'total_allergens_count': 0,
        'error_title': 'Image Not Clear / الصورة غير واضحة',
        'message': 'Please retake the label photo in good lighting and keep the camera steady.',
      };

      final result = ScanResult.fromJson(json);
      expect(result.success, false);
      expect(result.status, 'low_quality');
      expect(result.isLowQuality, true);
      expect(result.hasContentError, true);
      expect(result.errorTitle, 'Image Not Clear / الصورة غير واضحة');
    });

    testWidgets(
      'ScanResultScreen does not show Allergen Detected if allergensDetected is empty',
      (WidgetTester tester) async {
        // Even if a malformed result had isSafe: false with empty detections, it must not display false allergen warning or false reassurance
        const result = ScanResult(
          success: false,
          isSafe: false,
          status: 'low_quality',
          extractedOcrText: '',
          ingredientList: '',
          allergensDetected: [],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: ScanResultScreen(
              result: result,
              imageBytes: Uint8List(0),
              userAllergens: const ['Milk'],
              scannerService: AllergenScannerService(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Matching Allergens Found'), findsNothing);
        expect(
          find.text('Contains allergens matching your profile.'),
          findsNothing,
        );
        expect(find.text('Safe for You!'), findsNothing);
        expect(find.text('Analysis Incomplete'), findsOneWidget);
      },
    );

    Map<String, dynamic> labelResponse() => {
      'success': true,
      'status': 'completed',
      'is_safe': false,
      'extracted_ocr_text': 'Unchanged OCR',
      'ingredient_list': 'Unchanged ingredients',
      'allergens_detected': [
        for (var i = 0; i < AllergenDetection.categories.length; i++)
          {
            'allergen': AllergenDetection.categories[i].name,
            'matched_ingredients': ['trigger ${i + 1}'],
            'is_user_allergen': true,
          },
      ],
      'total_allergens_count': 14,
      'ocr_engine': 'provided_text',
      'message': 'Original evidence notice',
    };

    test(
      'All 14 categories retain exact names and their triggering ingredients',
      () {
        final json = labelResponse();
        final result = ScanResult.fromJson(json);
        expect(result.extractedOcrText, 'Unchanged OCR');
        expect(result.ingredientList, 'Unchanged ingredients');
        expect(result.message, 'Original evidence notice');
        for (var i = 0; i < 14; i++) {
          final name = AllergenDetection.categories[i].name;
          expect(result.allergensDetected[i].allergen, name);
          expect(result.allergensDetected[i].matchedIngredients, [
            'trigger ${i + 1}',
          ]);
        }
      },
    );

    test('Malformed, unknown and contradictory label results are rejected', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => j.remove('allergens_detected'),
        (j) => j.remove('is_safe'),
        (j) => j.remove('success'),
        (j) => j.remove('status'),
        (j) => j['total_allergens_count'] = 0,
        (j) => j['is_safe'] = true,
        (j) => j['status'] = 'unknown',
        (j) => j['allergens_detected'][0]['allergen'] = 'Dairy allergy',
        (j) => j['allergens_detected'][0]['allergen'] = 'Gluten',
        (j) => j['allergens_detected'][0]['allergen'] = 'Milk ',
        (j) => j['allergens_detected'][0]['allergen'] = 'unknown',
        (j) => j['allergens_detected'][0]['matched_ingredients'] = [123],
        (j) => j['allergens_detected'][0].remove('is_user_allergen'),
        (j) => j['allergens_detected'][0]['is_user_allergen'] = 'true',
      ]) {
        final json = labelResponse();
        mutate(json);
        expect(() => ScanResult.fromJson(json), throwsFormatException);
      }
    });

    testWidgets('Canonical names remain distinct and long badges fit a phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final result = ScanResult.fromJson(labelResponse());
      await tester.pumpWidget(
        MaterialApp(
          home: ScanResultScreen(
            result: result,
            imageBytes: Uint8List(0),
            userAllergens: AllergenDetection.categories
                .map((item) => item.name)
                .toList(),
            scannerService: AllergenScannerService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < AllergenDetection.categories.length; i++) {
        final name = AllergenDetection.categories[i].name;
        final card = find.byKey(ValueKey('label-allergen-$name'));
        await tester.ensureVisible(card);
        await tester.tap(
          find.descendant(of: card, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: card,
            matching: find.text(AllergenDetection.displayName(name)),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.text('Trigger ${i + 1}')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      expect(find.text('Shellfish'), findsNothing);
      expect(find.text('Nuts'), findsNothing);
      expect(find.text('Gluten'), findsOneWidget);
      expect(find.textContaining('Cereals containing gluten'), findsNothing);
    });

    testWidgets(
      'A shared ingredient appears once in each matched allergen card',
      (tester) async {
        const result = ScanResult(
          success: true,
          isSafe: false,
          extractedOcrText: 'Original label text',
          ingredientList: 'Original ingredient list',
          allergensDetected: [
            AllergenDetection(
              allergen: 'Milk',
              matchedIngredients: ['sauce'],
              isUserAllergen: true,
            ),
            AllergenDetection(
              allergen: 'Egg',
              matchedIngredients: ['sauce'],
              isUserAllergen: true,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScanResultScreen(
              result: result,
              imageBytes: Uint8List(0),
              userAllergens: const ['Milk', 'Egg'],
              scannerService: AllergenScannerService(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sauce'), findsNothing);
        for (final allergen in ['Milk', 'Egg']) {
          final card = find.byKey(ValueKey('label-allergen-$allergen'));
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
        expect(find.text('Sauce'), findsNWidgets(2));
        await tester.ensureVisible(
          find.byKey(const ValueKey('label-allergen-Milk')),
        );
        await tester.tap(
          find
              .descendant(
                of: find.byKey(const ValueKey('label-allergen-Milk')),
                matching: find.byType(InkWell),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Sauce'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('label-allergen-Egg')),
            matching: find.text('Sauce'),
          ),
          findsOneWidget,
        );
        expect(
          find.text('2 allergens match your registered allergies.'),
          findsOneWidget,
        );
        expect(find.text('Why this matches'), findsNothing);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(
          find.textContaining('Original ingredient keyword:'),
          findsNothing,
        );
        expect(find.textContaining('Source:'), findsNothing);
        expect(find.textContaining('Confidence:'), findsNothing);
        expect(
          find.text('Misbar can make mistakes. Verify before eating.'),
          findsOneWidget,
        );
        expect(result.extractedOcrText, 'Original label text');
        expect(result.ingredientList, 'Original ingredient list');
        expect(result.allergensDetected[0].matchedIngredients, ['sauce']);
        expect(result.allergensDetected[1].matchedIngredients, ['sauce']);
      },
    );

    testWidgets('Composite keyword evidence is preserved as returned', (
      tester,
    ) async {
      const result = ScanResult(
        success: true,
        isSafe: false,
        extractedOcrText: '',
        ingredientList: '',
        allergensDetected: [
          AllergenDetection(
            allergen: 'Milk',
            matchedIngredients: ['milk, cream'],
            isUserAllergen: true,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScanResultScreen(
            result: result,
            imageBytes: Uint8List(0),
            userAllergens: const ['Milk'],
            scannerService: AllergenScannerService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Milk, cream'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('label-allergen-Milk')),
      );
      await tester.tap(find.byKey(const ValueKey('label-allergen-Milk')));
      await tester.pumpAndSettle();
      expect(find.text('Milk, cream'), findsOneWidget);
      expect(find.byKey(const ValueKey('label-allergen-Milk')), findsOneWidget);
      expect(find.text('Why this matches'), findsNothing);
      expect(find.textContaining('Original ingredient keyword:'), findsNothing);
      expect(result.allergensDetected.single.matchedIngredients, [
        'milk, cream',
      ]);
    });

    testWidgets(
      'Missing triggering details do not create an ingredient or an extra UI note',
      (tester) async {
        const result = ScanResult(
          success: true,
          isSafe: false,
          extractedOcrText: '',
          ingredientList: '',
          allergensDetected: [
            AllergenDetection(
              allergen: 'Milk',
              matchedIngredients: [],
              isUserAllergen: true,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ScanResultScreen(
              result: result,
              imageBytes: Uint8List(0),
              userAllergens: const ['Milk'],
              scannerService: AllergenScannerService(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Matching Allergens Found'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('label-allergen-Milk')),
          findsOneWidget,
        );
        expect(find.text('Milk'), findsOneWidget);
        expect(
          find.text(
            'No triggering ingredient details were returned for: Milk.',
          ),
          findsNothing,
        );
        expect(find.text('Milk → Milk'), findsNothing);
        expect(find.text('Why this matches'), findsNothing);
      },
    );
  });
}
