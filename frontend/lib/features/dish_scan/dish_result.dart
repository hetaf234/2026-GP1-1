import 'dart:convert';

import '../../models/scan_result.dart';

Map<String, dynamic> dishObject(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid Dish object');
  }
  return value;
}

String dishText(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Missing Dish text');
  }
  return value;
}

List<dynamic> dishList(dynamic value) {
  if (value is! List) throw const FormatException('Missing Dish list');
  return value;
}

List<String> dishStrings(dynamic value) =>
    List.unmodifiable(dishList(value).map(dishText));
Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map.unmodifiable(jsonDecode(jsonEncode(value)) as Map<String, dynamic>);

class DishAllergenLink {
  final String category;
  final String causingIngredient;
  final String originalIngredient;
  final String source;
  final num? confidence;
  final Map<String, dynamic> evidence;
  final Map<String, dynamic> causeRecord;
  DishAllergenLink({
    required this.category,
    required this.causingIngredient,
    required this.originalIngredient,
    required this.source,
    this.confidence,
    required Map<String, dynamic> evidence,
    required Map<String, dynamic> causeRecord,
  }) : evidence = _copy(evidence),
       causeRecord = _copy(causeRecord);
}

class DishIngredientMatch {
  final String name;
  final List<String> allergens;
  final List<DishAllergenLink> causes;
  DishIngredientMatch({
    required this.name,
    required List<String> allergens,
    required List<DishAllergenLink> causes,
  }) : allergens = List.unmodifiable(allergens),
       causes = List.unmodifiable(causes);
}

/// The server decides matches. Flutter only groups returned causes for display.
class DishResult {
  final String dishName;
  final String matchStatus;
  final List<DishIngredientMatch> matches;
  final List<String> selectedAllergies;
  final Map<String, dynamic> personalization;
  DishResult._(
    this.dishName,
    this.matchStatus,
    this.matches,
    this.selectedAllergies,
    this.personalization,
  );

  factory DishResult.fromJson(Map<String, dynamic> result) {
    final p = dishObject(result['personalization']);
    if (result['decision'] != 'accepted' ||
        result['semantic_normalization_performed'] != true ||
        result['user_allergy_matching_performed'] != true ||
        p['status'] != 'completed' ||
        p['safety_assessment'] != 'not_established' ||
        dishList(p['unresolved_profile_terms']).isNotEmpty) {
      throw const FormatException('Dish personalization is incomplete');
    }
    // Keep all uncertainty fields available without reinterpreting ingredient names.
    dishList(p['mapping_disagreements']);
    dishList(p['ingredients_without_identified_allergens']);
    final selected = dishStrings(p['selected_allergies']);
    if (selected.isEmpty ||
        selected.toSet().length != selected.length ||
        selected.any(
          (value) =>
              !AllergenDetection.categories.any((item) => item.name == value),
        )) {
      throw const FormatException('Invalid saved allergen category');
    }
    final entries = dishList(p['matches']);
    final status = dishText(p['match_status']);
    if ((entries.isNotEmpty && status != 'potential_matches_found') ||
        (entries.isEmpty && status != 'no_known_matches')) {
      throw const FormatException('Contradictory Dish matches');
    }
    final groups = <String, List<DishAllergenLink>>{};
    final categories = <String>{};
    for (final entry in entries) {
      final match = dishObject(entry);
      final category = dishText(match['allergen']);
      if (!AllergenDetection.categories.any((item) => item.name == category) ||
          !selected.contains(category) ||
          !categories.add(category)) {
        throw const FormatException('Duplicate allergen');
      }
      final causes = dishList(match['causes']);
      if (causes.isEmpty) throw const FormatException('Missing cause');
      for (final raw in causes) {
        final cause = dishObject(raw);
        final ingredient = dishText(cause['ingredient']);
        final sources = dishStrings(cause['sources']);
        final originals = dishList(cause['original_members']);
        final evidence = dishList(cause['evidence']);
        if (sources.isEmpty || originals.isEmpty || evidence.isEmpty) {
          throw const FormatException('Missing cause evidence');
        }
        for (final original in originals) {
          final member = dishObject(original);
          dishText(member['id']);
          dishText(member['name']);
          dishList(member['evidence']);
        }
        for (final rawEvidence in evidence) {
          final e = dishObject(rawEvidence);
          final source = dishText(e['source']);
          final confidence = e['confidence'];
          if (!sources.contains(source) ||
              !dishStrings(e['allergens']).contains(category) ||
              dishStrings(e['allergens']).any(
                (value) => !AllergenDetection.categories.any(
                  (item) => item.name == value,
                ),
              ) ||
              (confidence != null &&
                  (confidence is! num ||
                      !confidence.isFinite ||
                      confidence < 0 ||
                      confidence > 100))) {
            throw const FormatException('Invalid cause evidence');
          }
          groups
              .putIfAbsent(ingredient, () => [])
              .add(
                DishAllergenLink(
                  category: category,
                  causingIngredient: ingredient,
                  originalIngredient: dishText(e['original_name']),
                  source: source,
                  confidence: confidence as num?,
                  evidence: e,
                  causeRecord: cause,
                ),
              );
        }
      }
    }
    return DishResult._(
      dishText(result['final_dish_display_name_en']),
      status,
      List.unmodifiable(
        groups.entries.map(
          (g) => DishIngredientMatch(
            name: g.key,
            allergens: g.value.map((c) => c.category).toSet().toList(),
            causes: g.value,
          ),
        ),
      ),
      selected,
      _copy(p),
    );
  }
}
