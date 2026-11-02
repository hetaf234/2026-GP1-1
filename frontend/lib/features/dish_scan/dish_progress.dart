import 'dart:async';
import 'dart:convert';

/// Progress represents backend facts, never elapsed-time estimates.
enum DishScanStage { imageReceived, identifyingDish, checkingAllergies }

enum DishStageStatus { pending, running, completed, rejected, error }

class DishProgressUpdate {
  final DishScanStage stage;
  final DishStageStatus status;
  const DishProgressUpdate(this.stage, this.status);
}

class DishStreamEvent {
  final String type;
  final Map<String, dynamic> data;
  const DishStreamEvent(this.type, this.data);
}

/// Handles arbitrary UTF-8 chunks, CRLF, comments, and multiline SSE data.
Stream<DishStreamEvent> decodeDishEvents(Stream<List<int>> bytes) async* {
  String? kind;
  final data = <String>[];
  var size = 0;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final value = jsonDecode(data.join('\n'));
        if (value is! Map<String, dynamic> ||
            !const ['progress', 'outcome'].contains(kind)) {
          throw const FormatException('Invalid Dish event');
        }
        yield DishStreamEvent(kind!, value);
      }
      kind = null;
      data.clear();
      size = 0;
    } else if (!line.startsWith(':')) {
      size += line.length;
      if (size > 8 * 1024 * 1024) {
        throw const FormatException('Dish event too large');
      }
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        kind = value;
      } else if (field == 'data') {
        data.add(value);
      } else if (!const ['id', 'retry'].contains(field)) {
        throw const FormatException('Invalid Dish event field');
      }
    }
  }
  if (kind != null || data.isNotEmpty) {
    throw const FormatException('Truncated Dish event');
  }
}

class DishScanCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}
