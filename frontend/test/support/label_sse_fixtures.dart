import 'dart:convert';

String labelFrame(
  String kind,
  Map<String, dynamic> payload,
  int sequence, {
  String scanId = 'label-test',
}) =>
    'id: $scanId:$sequence\nevent: $kind\ndata: ${jsonEncode({"scan_id": scanId, "sequence": sequence, ...payload})}\n\n';

const labelTransitions = [
  ('image_received', 'completed'),
  ('extracting_text', 'started'),
  ('extracting_text', 'completed'),
  ('identifying_ingredients', 'started'),
  ('identifying_ingredients', 'completed'),
  ('checking_allergens', 'started'),
  ('checking_allergens', 'completed'),
];

List<String> labelProgressFrames() => [
  for (var i = 0; i < labelTransitions.length; i++)
    labelFrame('progress', {
      'stage': labelTransitions[i].$1,
      'status': labelTransitions[i].$2,
    }, i + 1),
];

String labelOutcome(Map<String, dynamic> result, {int sequence = 8}) =>
    labelFrame('outcome', {'http_status': 200, 'result': result}, sequence);

String labelSuccess(Map<String, dynamic> result) =>
    '${labelProgressFrames().join()}${labelOutcome(result)}';
