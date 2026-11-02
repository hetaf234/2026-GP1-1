import 'dart:async';
import 'dart:convert';

/// Only these four stages may be shown. States are confirmed backend facts.
enum LabelScanStage {
  imageReceived('image_received', 'Image Received'),
  extractingText('extracting_text', 'Extracting Text'),
  identifyingIngredients('identifying_ingredients', 'Identifying Ingredients'),
  checkingAllergens('checking_allergens', 'Checking Allergens');

  final String id;
  final String label;
  const LabelScanStage(this.id, this.label);

  static LabelScanStage fromId(Object? id) => values.firstWhere(
    (stage) => stage.id == id,
    orElse: () => throw const FormatException('Unknown label stage.'),
  );
}

enum LabelStageStatus { pending, started, completed }

class LabelProgressUpdate {
  final LabelScanStage stage;
  final LabelStageStatus status;
  const LabelProgressUpdate(this.stage, this.status);
}

class LabelScanCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class LabelScanCancelled implements Exception {
  const LabelScanCancelled();
}

class LabelScanException implements Exception {
  final String code;
  final int? statusCode;
  const LabelScanException(this.code, {this.statusCode});
  bool get isContentError =>
      const {'low_quality', 'no_text', 'no_ingredients'}.contains(code);
  @override
  String toString() => 'Label analysis could not complete.';
}

class LabelStreamEvent {
  final String type;
  final String? id;
  final Map<String, dynamic> data;
  const LabelStreamEvent(this.type, this.id, this.data);
}

const _maxFrameCharacters = 8 * 1024 * 1024;

/// Bound a line before LineSplitter could accumulate an unbounded partial line.
Stream<String> _boundedLines(Stream<List<int>> bytes) async* {
  var line = StringBuffer();
  var length = 0;
  await for (final chunk in bytes.transform(utf8.decoder)) {
    var offset = 0;
    while (offset < chunk.length) {
      final newline = chunk.indexOf('\n', offset);
      final end = newline < 0 ? chunk.length : newline;
      final part = chunk.substring(offset, end);
      length += part.length;
      if (length > _maxFrameCharacters) {
        throw const FormatException('Label event too large.');
      }
      line.write(part);
      if (newline < 0) break;
      var text = line.toString();
      if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
      yield text;
      line = StringBuffer();
      length = 0;
      offset = newline + 1;
    }
  }
  if (length != 0) yield line.toString();
}

/// Supports arbitrary UTF-8 chunks, CRLF, comments and multiline JSON data.
/// A terminal frame still needs its blank-line delimiter and end of stream.
Stream<LabelStreamEvent> decodeLabelEvents(Stream<List<int>> bytes) async* {
  String? kind;
  String? id;
  final data = <String>[];
  var size = 0;
  var first = true;
  await for (var line in _boundedLines(bytes)) {
    if (first && line.startsWith('\uFEFF')) line = line.substring(1);
    first = false;
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final value = jsonDecode(data.join('\n'));
        if (value is! Map<String, dynamic> ||
            !const ['progress', 'outcome', 'error'].contains(kind)) {
          throw const FormatException('Invalid label event.');
        }
        yield LabelStreamEvent(kind!, id, value);
      } else if (kind != null || id != null) {
        throw const FormatException('Empty label event.');
      }
      kind = null;
      id = null;
      data.clear();
      size = 0;
    } else if (!line.startsWith(':')) {
      size += line.length;
      if (size > _maxFrameCharacters) {
        throw const FormatException('Label event too large.');
      }
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          if (kind != null) {
            throw const FormatException('Repeated event field.');
          }
          kind = value;
        case 'id':
          if (id != null) throw const FormatException('Repeated event ID.');
          id = value;
        case 'data':
          data.add(value);
        case 'retry':
          // This client never reconnects or resubmits, even if a server asks.
          if (!RegExp(r'^\d+$').hasMatch(value)) {
            throw const FormatException('Invalid retry field.');
          }
        default:
          throw const FormatException('Invalid label event field.');
      }
    }
  }
  if (kind != null || id != null || data.isNotEmpty) {
    throw const FormatException('Truncated label event.');
  }
}
