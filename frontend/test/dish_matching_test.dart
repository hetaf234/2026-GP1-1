import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:misbar_app/features/dish_scan/dish_result.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';

Map<String, dynamic> copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
void main() {
  test(
    'Three server allergens retain Sauce, sources and original evidence',
    () {
      final input = previewDishResponse();
      final before = copy(input);
      final result = DishResult.fromJson(input);
      expect(result.matches.single.name, 'Sauce');
      expect(result.matches.single.allergens, ['Egg', 'Milk', 'Soybean']);
      expect(result.matches.single.causes.map((c) => c.category), [
        'Egg',
        'Milk',
        'Soybean',
      ]);
      for (final cause in result.matches.single.causes) {
        expect(cause.source, 'Fictional preview');
        expect(cause.confidence, 25);
        expect(cause.originalIngredient, 'Special sauce');
        expect(cause.causeRecord['original_members'], isNotEmpty);
      }
      expect(input, before);
    },
  );
  test('No-match result remains authoritative without local matching', () {
    final result = DishResult.fromJson(previewDishResponse(hasMatches: false));
    expect(result.matches, isEmpty);
    expect(result.matchStatus, 'no_known_matches');
  });
  test('Nullable confidence and disagreements remain available', () {
    final input = previewDishResponse();
    input['personalization']['matches'][0]['causes'][0]['evidence'][0]['confidence'] =
        null;
    input['personalization']['mapping_disagreements'] = [
      {
        'ingredient': 'Sauce',
        'source_allergens': {
          'Dataset': ['Milk'],
          'Claude': ['Egg'],
        },
      },
    ];
    input['personalization']['ingredients_without_identified_allergens'] = [
      {'name': 'Garnish', 'members': []},
    ];
    final result = DishResult.fromJson(input);
    expect(result.matches.single.causes.first.confidence, isNull);
    expect(result.personalization['mapping_disagreements'], isNotEmpty);
    expect(
      result.personalization['ingredients_without_identified_allergens'],
      isNotEmpty,
    );
  });
  test('One allergen can retain multiple separate ingredient causes', () {
    final input = copy(previewDishResponse());
    final other = copy(input['personalization']['matches'][0]['causes'][0]);
    other['ingredient'] = 'Bread';
    input['personalization']['matches'][0]['causes'].add(other);
    final result = DishResult.fromJson(input);
    expect(result.matches.map((m) => m.name), ['Sauce', 'Bread']);
    expect(result.matches.last.allergens, ['Egg']);
  });
  test('Incomplete, contradictory and malformed results never become success', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (r) => r['personalization']['status'] = 'incomplete',
      (r) => r['personalization']['unresolved_profile_terms'] = ['unknown'],
      (r) => r['personalization']['safety_assessment'] = 'safe',
      (r) => r['personalization']['match_status'] = 'no_known_matches',
      (r) => r['personalization']['matches'][0]['causes'] = [],
      (r) => r['personalization']['matches'][0]['causes'][0]['evidence'] = [],
      (r) =>
          r['personalization']['matches'][0]['causes'][0]['evidence'][0]['allergens'] =
              [],
      (r) => r['user_allergy_matching_performed'] = false,
      (r) => r.remove('personalization'),
    ]) {
      final input = previewDishResponse();
      mutate(input);
      expect(() => DishResult.fromJson(input), throwsFormatException);
    }
  });
  test('Obsolete, missing and inconsistent outcomes never become success', () {
    for (final status in ['no_allergies_selected', 'unexpected', null]) {
      for (final selected in [
        <String>[],
        ['Egg'],
      ]) {
        final input = copy(previewDishResponse(hasMatches: false));
        input['personalization']['selected_allergies'] = selected;
        input['personalization']['match_status'] = status;
        final before = copy(input);
        expect(() => DishResult.fromJson(input), throwsFormatException);
        expect(input, before);
      }
    }
    final missing = previewDishResponse(hasMatches: false);
    missing['personalization'].remove('match_status');
    expect(() => DishResult.fromJson(missing), throwsFormatException);
    final emptySelected = previewDishResponse();
    emptySelected['personalization']['selected_allergies'] = <String>[];
    expect(() => DishResult.fromJson(emptySelected), throwsFormatException);
  });
  test('Every canonical category preserves its exact structured cause and uncertainty', () {
    for (final category in AllergenDetection.categories) {
      final input = previewDishResponse();
      final p = input['personalization'];
      final match = copy(p['matches'][0]);
      match['allergen'] = category.name;
      final cause = match['causes'][0];
      cause['evidence'][0]['allergens'] = [category.name];
      cause['original_members'][0]['evidence'][0]['allergens'] = [
        category.name,
      ];
      p['selected_allergies'] = [category.name];
      p['matches'] = [match];
      final before = copy(input);
      final result = DishResult.fromJson(input);
      expect(result.selectedAllergies, [category.name]);
      expect(result.matches.single.allergens, [category.name]);
      expect(result.matches.single.causes.single.causeRecord, cause);
      expect(result.matches.single.causes.single.confidence, 25);
      expect(result.personalization['safety_assessment'], 'not_established');
      expect(input, before);
    }
  });

  test('Legacy and unknown profile, result and evidence categories are rejected', () {
    for (final value in [
      'Gluten',
      'Dairy allergy',
      'milk',
      'Milk ',
      'Shellfish',
      'unknown',
    ]) {
      final profile = previewDishResponse();
      profile['personalization']['selected_allergies'] = [value];
      expect(() => DishResult.fromJson(profile), throwsFormatException);
      final result = previewDishResponse();
      result['personalization']['matches'][0]['allergen'] = value;
      expect(() => DishResult.fromJson(result), throwsFormatException);
      final evidence = previewDishResponse();
      evidence['personalization']['matches'][0]['causes'][0]['evidence'][0]['allergens']
          .add(value);
      expect(() => DishResult.fromJson(evidence), throwsFormatException);
    }
  });
}
