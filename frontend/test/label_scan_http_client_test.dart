import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/services/label_scan_http_client.dart';
import 'package:misbar_app/services/label_scan_progress.dart';

import 'support/http_lifecycle_doubles.dart';
import 'support/label_sse_fixtures.dart';

class LabelClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final requests = <http.BaseRequest>[];
  bool closed = false;
  int aborts = 0;
  LabelClient(this.respond);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) => aborts++);
    }
    return respond(request);
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse reply(
  String text, {
  int status = 200,
  String type = 'text/event-stream',
  bool fragmented = false,
}) => http.StreamedResponse(
  Stream.fromIterable(
    fragmented ? utf8.encode(text).map((b) => [b]) : [utf8.encode(text)],
  ),
  status,
  headers: {'content-type': type},
);

void main() {
  final image = Uint8List.fromList([1, 2, 3]);
  late String? uid;
  var tokenCalls = 0;
  setUp(() {
    uid = 'local-user';
    tokenCalls = 0;
  });
  LabelScanHttpClient service(
    LabelClient client, {
    Duration timeout = const Duration(seconds: 2),
    Future<String> Function()? tokenProvider,
    String baseUrl = 'https://local.invalid',
  }) => LabelScanHttpClient(
    client: client,
    baseUrl: baseUrl,
    tokenProvider:
        tokenProvider ??
        () async {
          tokenCalls++;
          return 'local-token';
        },
    currentUid: () => uid,
    timeout: timeout,
  );

  test('one authenticated POST, fragmented UTF-8, exact result, shared client survives', () async {
    String? body;
    final payload = {
      ...LifecycleHttpClient.scanBody,
      'ingredient_list': 'Crème brûlée',
    };
    final client = LabelClient((request) async {
      body = utf8.decode(await request.finalize().toBytes());
      return reply(labelSuccess(payload), fragmented: true);
    });
    final progress = <LabelProgressUpdate>[];
    final result = await service(client)
        .analyze(image, onProgress: progress.add);
    expect(result.ingredientList, 'Crème brûlée');
    expect(client.requests, hasLength(1));
    final request = client.requests.single;
    expect(request, isA<http.AbortableMultipartRequest>());
    expect(request.method, 'POST');
    expect(request.url.path, '/scan/image');
    expect(request.headers['Authorization'], 'Bearer local-token');
    expect(request.headers['Accept'], 'text/event-stream');
    expect(request.followRedirects, isFalse);
    expect(body, contains('name="file"; filename="label.jpg"'));
    expect(body, isNot(contains('user_allergens')));
    expect(body, isNot(contains('user_id')));
    expect(tokenCalls, 1);
    expect(
      progress
          .where((p) => p.status == LabelStageStatus.completed)
          .map((p) => p.stage),
      LabelScanStage.values,
    );
    expect(client.closed, isFalse);
    expect(
      (await service(client).analyze(image, onProgress: (_) {})).success,
      isTrue,
    );
    expect(client.closed, isFalse);
  });

  test('consumes the exact synthetic backend contract fixture', () async {
    final fixture = File('test/support/label_backend_stream.sse')
        .readAsStringSync();
    final client = LabelClient((_) async => reply(fixture, fragmented: true));
    final result = await service(client).analyze(image, onProgress: (_) {});
    expect(result.extractedOcrText, 'Ingredients: Milk, Sugar');
    expect(result.allergensDetected.single.allergen, 'Milk');
    expect(result.allergensDetected.single.isUserAllergen, isTrue);
    expect(result.isSafe, isFalse);
  });

  test('comments, CRLF and multiline JSON do not invent progress', () async {
    final normal = labelSuccess(LifecycleHttpClient.scanBody);
    final text =
        ': heartbeat\r\n\r\n${normal.replaceAll('\n', '\r\n').replaceAll(',"sequence"', ',\r\ndata: "sequence"')}';
    final progress = <LabelProgressUpdate>[];
    final client = LabelClient((_) async => reply(text, fragmented: true));
    expect(
      (await service(client).analyze(image, onProgress: progress.add)).success,
      isTrue,
    );
    expect(progress, hasLength(7));
  });

  test(
    'default total deadline covers Cloud Run 600 seconds plus transport grace',
    () {
      final client = LabelClient((_) async => reply(''));
      expect(
        LabelScanHttpClient(
          client: client,
          baseUrl: 'https://local.invalid',
          tokenProvider: () async => 'x',
          currentUid: () => uid,
        ).timeout,
        const Duration(minutes: 11),
      );
    },
  );

  testWidgets(
    'a legitimate stream survives 25 seconds and the full server budget',
    (tester) async {
      final controller = StreamController<List<int>>();
      final client = LabelClient(
        (_) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final updates = <LabelProgressUpdate>[];
      Object? failure;
      bool succeeded = false;
      final finished =
          LabelScanHttpClient(
                client: client,
                baseUrl: 'https://local.invalid',
                tokenProvider: () async => 'local-token',
                currentUid: () => uid,
              )
              .analyze(image, onProgress: updates.add)
              .then<void>(
                (result) => succeeded = result.success,
                onError: (Object error) {
                  failure = error;
                },
              );
      await tester.pump();
      final frames = labelProgressFrames();
      controller.add(utf8.encode(frames.take(2).join()));
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        controller.add(utf8.encode(': keep-alive\n\n'));
        await tester.pump(const Duration(seconds: 15));
        expect(failure, isNull);
        expect(succeeded, isFalse);
        expect(updates, hasLength(2));
      }
      // A small transport/EOF delay beyond the server's 600-second budget is
      // covered without extending the backend's own limit or resubmitting.
      await tester.pump(const Duration(seconds: 10));
      controller.add(
        utf8.encode(
          '${frames.skip(2).join()}${labelOutcome(LifecycleHttpClient.scanBody)}',
        ),
      );
      unawaited(controller.close());
      await tester.pump();
      await finished;
      expect(succeeded, isTrue);
      expect(failure, isNull);
      expect(client.requests, hasLength(1));
      expect(client.closed, isFalse);
    },
  );

  testWidgets(
    'heartbeats cannot keep a hung stream alive past the total deadline',
    (tester) async {
      final controller = StreamController<List<int>>();
      final client = LabelClient(
        (_) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      Object? failure;
      bool succeeded = false;
      final updates = <LabelProgressUpdate>[];
      final finished =
          LabelScanHttpClient(
                client: client,
                baseUrl: 'https://local.invalid',
                tokenProvider: () async => 'local-token',
                currentUid: () => uid,
              )
              .analyze(image, onProgress: updates.add)
              .then<void>(
                (_) => succeeded = true,
                onError: (Object error) {
                  failure = error;
                },
              );
      await tester.pump();
      for (var i = 0; i < 44; i++) {
        controller.add(utf8.encode(': keep-alive\n\n'));
        await tester.pump(const Duration(seconds: 15));
      }
      await finished;
      expect(
        failure,
        isA<LabelScanException>().having((e) => e.code, 'code', 'timeout'),
      );
      expect(client.aborts, 1);
      controller.add(utf8.encode(labelSuccess(LifecycleHttpClient.scanBody)));
      unawaited(controller.close());
      await tester.pump();
      expect(succeeded, isFalse);
      expect(updates, isEmpty);
      expect(client.requests, hasLength(1));
      expect(client.closed, isFalse);
    },
  );

  for (final status in [301, 307, 400, 401, 403, 413, 429, 500, 503]) {
    test(
      'HTTP $status never refreshes, redirects, retries or falls back',
      () async {
        final client = LabelClient(
          (_) async => reply(
            'PRIVATE_TOKEN_BODY',
            status: status,
            type: 'application/json',
          ),
        );
        await expectLater(
          service(client).analyze(image, onProgress: (_) {}),
          throwsA(
            isA<LabelScanException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.toString(),
                  'safe text',
                  isNot(contains('PRIVATE')),
                ),
          ),
        );
        expect(client.requests, hasLength(1));
        expect(tokenCalls, 1);
        expect(client.closed, isFalse);
      },
    );
  }

  test(
    'a legacy JSON response is rejected without resending the image',
    () async {
      final client = LabelClient(
        (_) async => reply(
          jsonEncode(LifecycleHttpClient.scanBody),
          type: 'application/json',
        ),
      );
      await expectLater(
        service(client).analyze(image, onProgress: (_) {}),
        throwsA(
          isA<LabelScanException>().having(
            (e) => e.code,
            'code',
            'unsupported_response',
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );

  for (final code in [
    'low_quality',
    'no_text',
    'no_ingredients',
    'quality_unavailable',
    'ocr_failed',
    'ingredient_extraction_failed',
    'allergen_check_failed',
    'profile_not_found',
    'invalid_allergy_profile',
  ]) {
    test(
      'structured $code error is terminal and never leaks its message',
      () async {
        final client = LabelClient(
          (_) async => reply(
            labelFrame('error', {
              'http_status': 422,
              'code': code,
              'message': 'OPAQUE_PROVIDER_SECRET',
            }, 1),
          ),
        );
        await expectLater(
          service(client).analyze(image, onProgress: (_) {}),
          throwsA(
            isA<LabelScanException>()
                .having((e) => e.code, 'code', code)
                .having(
                  (e) => e.toString(),
                  'safe message',
                  isNot(contains('OPAQUE')),
                ),
          ),
        );
        expect(client.requests, hasLength(1));
      },
    );
  }

  final success = labelSuccess(LifecycleHttpClient.scanBody);
  final progress = labelProgressFrames();
  final invalidStreams = <String, String>{
    'missing outcome': progress.join(),
    'outcome without progress': labelOutcome(
      LifecycleHttpClient.scanBody,
      sequence: 1,
    ),
    'duplicated terminal':
        '$success${labelOutcome(LifecycleHttpClient.scanBody, sequence: 9)}',
    'truncated outcome': success.substring(0, success.length - 2),
    'missing stage':
        '${progress.take(3).join()}${progress.skip(4).join()}${labelOutcome(LifecycleHttpClient.scanBody)}',
    'unknown stage': success.replaceFirst('image_received', 'quality_check'),
    'unknown status': success.replaceFirst('completed', 'estimated'),
    'sequence gap': success.replaceFirst('"sequence":2', '"sequence":9'),
    'changed request ID': success.replaceFirst(
      '"scan_id":"label-test"',
      '"scan_id":"other"',
    ),
    'complete before start':
        '${progress.first}${labelFrame('progress', {'stage': 'extracting_text', 'status': 'completed'}, 2)}',
    'regression':
        '${progress.take(3).join()}${labelFrame('progress', {'stage': 'extracting_text', 'status': 'started'}, 4)}',
    'malformed JSON': 'event: progress\ndata: {bad}\n\n',
    'empty event': 'event: progress\n\n',
    'unknown event': 'event: unsafe\ndata: {}\n\n',
    'unknown field': 'credential: PRIVATE\n\n',
    'repeated event field': 'event: progress\nevent: outcome\ndata: {}\n\n',
    'contradictory result': success.replaceFirst(
      '"is_safe":true',
      '"is_safe":false',
    ),
  };
  for (final entry in invalidStreams.entries) {
    test('rejects ${entry.key} without retry or successful result', () async {
      final client = LabelClient((_) async => reply(entry.value));
      await expectLater(
        service(client).analyze(image, onProgress: (_) {}),
        throwsA(isA<LabelScanException>()),
      );
      expect(client.requests, hasLength(1));
    });
  }

  test('UTF-8 errors fail safely', () async {
    final client = LabelClient(
      (_) async => http.StreamedResponse(
        Stream.value([0xff]),
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    await expectLater(
      service(client).analyze(image, onProgress: (_) {}),
      throwsA(isA<LabelScanException>()),
    );
  });

  test(
    'oversized partial lines are bounded before a delimiter arrives',
    () async {
      final client = LabelClient(
        (_) async => reply('data: ${'x' * (8 * 1024 * 1024)}'),
      );
      await expectLater(
        service(
          client,
          timeout: const Duration(seconds: 10),
        ).analyze(image, onProgress: (_) {}),
        throwsA(isA<LabelScanException>()),
      );
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'no success is returned until the sole terminal is followed by stream end',
    () async {
      final controller = StreamController<List<int>>();
      addTearDown(() {
        controller.close();
      });
      final client = LabelClient(
        (_) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      var completed = false;
      final result = service(client)
          .analyze(image, onProgress: (_) {})
          .then((value) {
            completed = true;
            return value;
          });
      controller.add(utf8.encode(success));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      await controller.close();
      expect((await result).success, isTrue);
    },
  );

  test(
    'cancellation aborts only its request and discards late events',
    () async {
      var bodyCancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () {
          bodyCancelled = true;
        },
      );
      addTearDown(() {
        controller.close();
      });
      final client = LabelClient(
        (_) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final cancel = LabelScanCancellation();
      final updates = <LabelProgressUpdate>[];
      final result = service(client)
          .analyze(image, cancellation: cancel, onProgress: updates.add);
      final assertion = expectLater(result, throwsA(isA<LabelScanCancelled>()));
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await assertion;
      controller.add(utf8.encode(success));
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);
      expect(bodyCancelled, isTrue);
      expect(client.aborts, 1);
      expect(client.closed, isFalse);
    },
  );

  for (final where in ['token', 'headers', 'stream']) {
    test(
      'timeout while waiting for $where aborts without resubmission',
      () async {
        final controller = StreamController<List<int>>();
        addTearDown(() {
          controller.close();
        });
        final headers = Completer<http.StreamedResponse>();
        final token = Completer<String>();
        final client = LabelClient(
          (_) => where == 'headers'
              ? headers.future
              : Future.value(
                  http.StreamedResponse(
                    controller.stream,
                    200,
                    headers: {'content-type': 'text/event-stream'},
                  ),
                ),
        );
        await expectLater(
          service(
            client,
            timeout: const Duration(milliseconds: 20),
            tokenProvider: where == 'token' ? () => token.future : null,
          ).analyze(image, onProgress: (_) {}),
          throwsA(
            isA<LabelScanException>().having((e) => e.code, 'code', 'timeout'),
          ),
        );
        token.complete('late-token');
        if (where == 'headers') headers.complete(reply(success));
        await Future<void>.delayed(Duration.zero);
        expect(client.requests, hasLength(where == 'token' ? 0 : 1));
        expect(client.closed, isFalse);
      },
    );
  }

  test(
    'account change while awaiting token cannot send the old image',
    () async {
      final token = Completer<String>();
      final client = LabelClient((_) async => reply(success));
      final result = service(
        client,
        tokenProvider: () => token.future,
      ).analyze(image, onProgress: (_) {});
      final assertion = expectLater(result, throwsA(isA<LabelScanException>()));
      uid = 'other-user';
      token.complete('old-token');
      await assertion;
      expect(client.requests, isEmpty);
    },
  );

  test(
    'account change while streaming cannot deliver progress or results',
    () async {
      final controller = StreamController<List<int>>();
      addTearDown(() {
        controller.close();
      });
      final client = LabelClient(
        (_) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final updates = <LabelProgressUpdate>[];
      final result = service(client).analyze(image, onProgress: updates.add);
      final assertion = expectLater(result, throwsA(isA<LabelScanException>()));
      await Future<void>.delayed(Duration.zero);
      uid = 'other-user';
      controller.add(utf8.encode(success));
      await assertion;
      expect(updates, isEmpty);
    },
  );

  test('cancellation before token or HTTP causes zero submissions', () async {
    final cancel = LabelScanCancellation()..cancel();
    final client = LabelClient((_) async => reply(success));
    await expectLater(
      service(client).analyze(image, cancellation: cancel, onProgress: (_) {}),
      throwsA(isA<LabelScanCancelled>()),
    );
    expect(tokenCalls, 0);
    expect(client.requests, isEmpty);
  });

  test('empty and oversized images never reach token or HTTP', () async {
    final client = LabelClient((_) async => reply(success));
    for (final data in [Uint8List(0), Uint8List(4 * 1024 * 1024 + 1)]) {
      await expectLater(
        service(client).analyze(data, onProgress: (_) {}),
        throwsA(isA<LabelScanException>()),
      );
    }
    expect(tokenCalls, 0);
    expect(client.requests, isEmpty);
  });
}
