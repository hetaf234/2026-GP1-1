import 'dart:convert';

/// The existing packaged-label API contract. No inference or matching happens here.
ScanResult parseScanResult(String body) =>
    ScanResult.fromJson(jsonDecode(body) as Map<String, dynamic>);

class AllergenDetection {
  // The existing selection options, shared by selection and validation.
  // Names remain canonical for storage, API contracts and validation.
  static const categories = [
    (name: 'Milk', emoji: '🥛'),
    (name: 'Tree nuts', emoji: '🥜'),
    (name: 'Cereals containing gluten', emoji: '🌾'),
    (name: 'Crustaceans', emoji: '🦀'),
    (name: 'Molluscs', emoji: '🐚'),
    (name: 'Egg', emoji: '🥚'),
    (name: 'Soybean', emoji: '🫘'),
    (name: 'Fish', emoji: '🐟'),
    (name: 'Sesame', emoji: '🌱'),
    (name: 'Peanut', emoji: '🥜'),
    (name: 'Mustard', emoji: '🌼'),
    (name: 'Celery', emoji: '🥬'),
    (name: 'Sulphur dioxide and sulphites', emoji: '🍇'),
    (name: 'Lupin', emoji: '🌿'),
  ];

  /// Presentation only. Never use this label for storage or matching.
  static String displayName(String canonicalName) =>
      canonicalName == 'Cereals containing gluten' ? 'Gluten' : canonicalName;

  final String allergen;
  final List<String> matchedIngredients;
  final bool isUserAllergen;

  const AllergenDetection({
    required this.allergen,
    required this.matchedIngredients,
    this.isUserAllergen = false,
  });

  factory AllergenDetection.fromJson(Map<String, dynamic> json) {
    final allergen = json['allergen'];
    final ingredients = json['matched_ingredients'];
    if (!categories.any((item) => item.name == allergen) ||
        ingredients is! List ||
        ingredients.any((item) => item is! String || item.trim().isEmpty) ||
        json['is_user_allergen'] is! bool) {
      throw const FormatException('Invalid allergen detection.');
    }
    return AllergenDetection(
      allergen: allergen as String,
      matchedIngredients: List<String>.unmodifiable(ingredients.cast<String>()),
      isUserAllergen: json['is_user_allergen'] == true,
    );
  }
}

class ScanResult {
  final bool success;
  final String status;
  final bool isSafe;
  final String extractedOcrText;
  final String ingredientList;
  final List<AllergenDetection> allergensDetected;
  final int totalAllergensCount;
  final String ocrEngine;
  final String? message;
  final String? errorTitle;

  const ScanResult({
    required this.success,
    required this.isSafe,
    required this.extractedOcrText,
    required this.ingredientList,
    required this.allergensDetected,
    this.status = 'completed',
    this.totalAllergensCount = 0,
    this.ocrEngine = 'unknown',
    this.message,
    this.errorTitle,
  });

  bool get isLowQuality => status == 'low_quality';
  bool get hasContentError =>
      isLowQuality || status == 'no_text' || status == 'no_ingredients';

  factory ScanResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final detections = json['allergens_detected'];
    final count = json['total_allergens_count'];
    if (json['success'] is! bool ||
        json['is_safe'] is! bool ||
        !const [
          'completed',
          'low_quality',
          'no_text',
          'no_ingredients',
        ].contains(status) ||
        json['extracted_ocr_text'] is! String ||
        json['ingredient_list'] is! String ||
        detections is! List ||
        count is! int ||
        count != detections.length ||
        detections.any((item) => item is! Map<String, dynamic>)) {
      throw const FormatException('Invalid label scan response.');
    }
    final parsed = detections
        .map((item) => AllergenDetection.fromJson(item as Map<String, dynamic>))
        .toList();
    if (parsed.map((item) => item.allergen).toSet().length != parsed.length ||
        (status == 'completed' &&
            (json['success'] != true ||
                json['is_safe'] !=
                    !parsed.any((item) => item.isUserAllergen))) ||
        (status != 'completed' &&
            (json['is_safe'] == true || parsed.isNotEmpty))) {
      throw const FormatException('Contradictory label scan response.');
    }
    return ScanResult(
      success: json['success'] == true,
      status: status as String,
      isSafe: json['is_safe'] == true,
      extractedOcrText: json['extracted_ocr_text'] as String,
      ingredientList: json['ingredient_list'] as String,
      allergensDetected: List<AllergenDetection>.unmodifiable(parsed),
      totalAllergensCount: count,
      ocrEngine: json['ocr_engine'] as String? ?? 'unknown',
      message: json['message'] as String?,
      errorTitle: json['error_title'] as String?,
    );
  }
}
