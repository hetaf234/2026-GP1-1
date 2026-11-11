import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/scan_result.dart';
import 'label_scan_progress.dart';

/// Borrows the application HTTP client; aborts only this request, never the
/// shared connection. Exactly one send, no redirects/retries/host fallback.
class LabelScanHttpClient {
  final http.Client client;
  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final String? Function() currentUid;
  final Duration timeout;

  const LabelScanHttpClient({
    required this.client,
    required this.baseUrl,
    required this.tokenProvider,
    required this.currentUid,
    // Whole-request deadline: 180 seconds for token retrieval, upload and
    // stream completion, matching the dish default. Heartbeats do not
    // restart this deadline; cancellation still aborts the single request.
    this.timeout = const Duration(seconds: 180),
  });

  Future<ScanResult> analyze(
    Uint8List image, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) async {
    if (image.isEmpty || image.length > 4 * 1024 * 1024) {
      throw const LabelScanException('invalid_image');
    }
    if (timeout <= Duration.zero) {
      throw const LabelScanException('timeout');
    }
    final cancel = cancellation ?? LabelScanCancellation();
    final abort = LabelScanCancellation();
    var active = true;
    StreamIterator<LabelStreamEvent>? events;
    final uid = currentUid();

    void check() {
      if (!active || cancel.isCancelled) throw const LabelScanCancelled();
      if (uid == null || uid.isEmpty || currentUid() != uid) {
        throw const LabelScanException(
          'authentication_required',
          statusCode: 401,
        );
      }
    }

    Future<ScanResult> run() async {
      check();
      final token = await tokenProvider();
      check();
      if (token.isEmpty) {
        throw const LabelScanException(
          'authentication_required',
          statusCode: 401,
        );
      }
      final address = baseUrl.replaceFirst(RegExp(r'/+$'), '');
      final uri = Uri.parse('$address/scan/image');
      if (!const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const LabelScanException('invalid_endpoint');
      }
      final request =
          http.AbortableMultipartRequest(
              'POST',
              uri,
              abortTrigger: abort.whenCancelled,
            )
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $token'
            ..headers['Accept'] = 'text/event-stream'
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                image,
                filename: 'label.jpg',
                contentType: MediaType('image', 'jpeg'),
              ),
            );
      final response = await client.send(request);
      if (!active || cancel.isCancelled || currentUid() != uid) {
        await response.stream.listen((_) {}).cancel();
        check();
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw LabelScanException(
          response.statusCode == 401 ? 'authentication_required' : 'http_error',
          statusCode: response.statusCode,
        );
      }
      if (response.headers['content-type']
              ?.split(';')
              .first
              .trim()
              .toLowerCase() !=
          'text/event-stream') {
        await response.stream.listen((_) {}).cancel();
        throw const LabelScanException('unsupported_response');
      }
      events = StreamIterator(decodeLabelEvents(response.stream));
      String? scanId;
      var sequence = 0;
      var terminal = false;
      ScanResult? result;
      LabelScanException? failure;
      final stages = <LabelScanStage, LabelStageStatus>{};
      while (await events!.moveNext()) {
        check();
        final event = events!.current;
        if (terminal) throw const FormatException('Event after terminal.');
        final id = event.data['scan_id'];
        final next = event.data['sequence'];
        if (id is! String ||
            !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
            next is! int ||
            next != sequence + 1 ||
            (scanId != null && scanId != id) ||
            (event.id != null && event.id != '$id:$next')) {
          throw const FormatException('Invalid label event identity.');
        }
        scanId = id;
        sequence = next;
        if (event.type == 'progress') {
          final stage = LabelScanStage.fromId(event.data['stage']);
          final status = switch (event.data['status']) {
            'started' => LabelStageStatus.started,
            'completed' => LabelStageStatus.completed,
            _ => throw const FormatException('Invalid label stage status.'),
          };
          if (stage.index > 0 &&
              stages[LabelScanStage.values[stage.index - 1]] !=
                  LabelStageStatus.completed) {
            throw const FormatException('Out-of-order label progress.');
          }
          if ((status == LabelStageStatus.started &&
                  stages.containsKey(stage)) ||
              (status == LabelStageStatus.completed &&
                  (stages[stage] == LabelStageStatus.completed ||
                      (stage.index > 0 &&
                          stages[stage] != LabelStageStatus.started)))) {
            throw const FormatException('Invalid label transition.');
          }
          stages[stage] = status;
          onProgress(LabelProgressUpdate(stage, status));
        } else if (event.type == 'outcome') {
          if (event.data['http_status'] != 200 ||
              !LabelScanStage.values.every(
                (stage) => stages[stage] == LabelStageStatus.completed,
              )) {
            throw const FormatException('Unconfirmed label outcome.');
          }
          final payload = event.data['result'];
          if (payload is! Map<String, dynamic>) {
            throw const FormatException('Invalid label outcome.');
          }
          result = ScanResult.fromJson(payload);
          if (!result.success || result.status != 'completed') {
            throw const FormatException('Rejected label outcome.');
          }
          terminal = true;
        } else {
          final status = event.data['http_status'];
          final code = event.data['code'];
          if (status is! int ||
              status < 400 ||
              status > 599 ||
              code is! String ||
              !const {
                'low_quality',
                'no_text',
                'no_ingredients',
                'analysis_failed',
                'quality_unavailable',
                'ocr_failed',
                'ingredient_extraction_failed',
                'allergen_check_failed',
                'profile_not_found',
                'profile_unavailable',
                'invalid_allergy_profile',
              }.contains(code) ||
              event.data['message'] is! String) {
            throw const FormatException('Invalid label error.');
          }
          // Never expose provider text or trust stream messages for UI wording.
          failure = LabelScanException(code, statusCode: status);
          terminal = true;
        }
      }
      check();
      if (!terminal) throw const FormatException('Missing terminal event.');
      if (failure != null) throw failure;
      return result!;
    }

    try {
      return await Future.any<ScanResult>([
        run(),
        cancel.whenCancelled.then<ScanResult>((_) {
          abort.cancel();
          throw const LabelScanCancelled();
        }),
      ]).timeout(timeout);
    } on LabelScanCancelled {
      rethrow;
    } on LabelScanException {
      rethrow;
    } on TimeoutException {
      throw const LabelScanException('timeout');
    } catch (_) {
      if (cancel.isCancelled) throw const LabelScanCancelled();
      throw const LabelScanException('invalid_or_interrupted_stream');
    } finally {
      active = false;
      abort.cancel();
      final iterator = events;
      if (iterator != null) {
        // Native IO is aborted immediately. An uncooperative stream must not
        // hold up the cancellation/deadline while its async generator unwinds.
        unawaited(iterator.cancel().catchError((Object _) {}));
      }
    }
  }
}
