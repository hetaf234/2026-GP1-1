import 'dart:convert';

import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';

Map<String, dynamic> matchedResponse({bool matches = true}) =>
    previewDishResponse(hasMatches: matches);
String event(String type, Map<String, dynamic> data) =>
    'event: $type\ndata: ${jsonEncode(data)}\n\n';
List<String> progressFrames() {
  var sequence = 0;
  return [
    for (final stage in [
      'image_received',
      'identifying_ingredients',
      'checking_allergens',
    ])
      for (final status in ['running', 'completed'])
        event('progress', {
          'scan_id': 'test-scan',
          'sequence': ++sequence,
          'stage': stage,
          'status': status,
        }),
  ];
}

String outcomeFrame(
  Map<String, dynamic> result, {
  int status = 200,
  int sequence = 7,
}) => event('outcome', {
  'scan_id': 'test-scan',
  'sequence': sequence,
  'http_status': status,
  'result': result,
});
String successStream({bool matches = true}) =>
    '${progressFrames().join()}${outcomeFrame(matchedResponse(matches: matches))}';
