import 'dart:typed_data';

import '../dish_result.dart';
import '../dish_scan_service.dart';

enum DishPreviewScenario {
  matching,
  noMatches,
  lowQuality,
  notSingleDish,
  unsupportedDish,
  connectionError,
}

extension DishPreviewScenarioLabel on DishPreviewScenario {
  String get label => switch (this) {
    DishPreviewScenario.matching => 'Allergy matches',
    DishPreviewScenario.noMatches => 'No matches',
    DishPreviewScenario.lowQuality => 'Unclear photo',
    DishPreviewScenario.notSingleDish => 'Not a single dish',
    DishPreviewScenario.unsupportedDish => 'Unsupported dish',
    DishPreviewScenario.connectionError => 'Connection error',
  };
}

/// Fictional pre-matched evidence for the separate preview application only.
/// Preview profile chips do not recompute or override these fixed results.
Map<String, dynamic> previewDishResponse({bool hasMatches = true}) {
  Map<String, dynamic> match(String category) {
    final e = <String, dynamic>{
      'source': 'Fictional preview',
      'original_name': 'Special sauce',
      'confidence': 25,
      'allergens': [category],
      'mapping_evidence': <dynamic>[],
    };
    return {
      'allergen': category,
      'causes': [
        {
          'ingredient': 'Sauce',
          'sources': ['Fictional preview'],
          'evidence': [e],
          'original_members': [
            {
              'id': 'sample-sauce',
              'name': 'Special sauce',
              'evidence': [e],
            },
          ],
        },
      ],
    };
  }

  return {
    'decision': 'accepted',
    'final_dish_display_name_en': 'Sample dish',
    'semantic_normalization_performed': true,
    'user_allergy_matching_performed': true,
    'personalization': {
      'status': 'completed',
      'safety_assessment': 'not_established',
      'selected_allergies': ['Egg', 'Milk', 'Soybean'],
      'unresolved_profile_terms': <dynamic>[],
      'match_status': hasMatches
          ? 'potential_matches_found'
          : 'no_known_matches',
      'matches': hasMatches
          ? [match('Egg'), match('Milk'), match('Soybean')]
          : <dynamic>[],
      'mapping_disagreements': <dynamic>[],
      'ingredients_without_identified_allergens': <dynamic>[],
    },
  };
}

class PreviewDishScanService implements DishScanService {
  final DishPreviewScenario scenario;
  // Retained for existing preview callers; never used to generate timed progress.
  final Duration stageDelay;
  const PreviewDishScanService(
    this.scenario, {
    this.stageDelay = Duration.zero,
  });
  @override
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) throw const DishScanCancelled();
    final failure = switch (scenario) {
      DishPreviewScenario.lowQuality => DishScanFailure.lowQuality,
      DishPreviewScenario.notSingleDish => DishScanFailure.notSingleDish,
      DishPreviewScenario.unsupportedDish => DishScanFailure.unsupportedDish,
      DishPreviewScenario.connectionError => DishScanFailure.connection,
      _ => null,
    };
    if (failure != null) throw DishScanException(failure);
    return DishResult.fromJson(
      previewDishResponse(hasMatches: scenario == DishPreviewScenario.matching),
    );
  }
}
