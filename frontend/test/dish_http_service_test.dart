import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/features/dish_scan/dish_http_service.dart';
import 'package:misbar_app/features/dish_scan/dish_scan_service.dart';

import 'support/dish_response_fixtures.dart';
import 'support/http_lifecycle_doubles.dart';

class DishClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final requests = <http.BaseRequest>[];
  bool closed = false;
  void Function()? onClose;
  DishClient(this.respond);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return respond(request);
  }

  @override
  void close() {
    closed = true;
    onClose?.call();
  }
}

http.StreamedResponse response(
  String text, {
  int code = 200,
  String type = 'text/event-stream',
  bool fragment = false,
}) => http.StreamedResponse(
  Stream.fromIterable(
    fragment ? utf8.encode(text).map((b) => [b]) : [utf8.encode(text)],
  ),
  code,
  headers: {'content-type': type},
);
final connection = isA<DishScanException>().having(
  (e) => e.reason,
  'reason',
  DishScanFailure.connection,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAuth auth;
  setUpAll(() async {
    auth = await initializeTestAuth();
  });
  setUp(() {
    auth.signedIn = true;
    auth.pendingToken = null;
    auth.tokenRefreshes.clear();
  });
  HttpDishScanService service(
    DishClient client, {
    Duration timeout = const Duration(seconds: 2),
  }) => HttpDishScanService(
    baseUrl: 'https://local.invalid',
    clientFactory: () => client,
    timeout: timeout,
  );
  final image = Uint8List.fromList([1, 2, 3]);
  test('default deadline is 180 seconds', () {
    expect(const HttpDishScanService().timeout, const Duration(seconds: 180));
  });
  test('current Firebase token, one POST, fragmented UTF-8, exact causes and confirmed stages', () async {
    String? body;
    final client = DishClient((request) async {
      body = utf8.decode(await request.finalize().toBytes());
      final result = matchedResponse();
      result['final_dish_display_name_en'] = 'Crème brûlée';
      return response(
        '${progressFrames().join()}${outcomeFrame(result)}',
        fragment: true,
      );
    });
    final progress = <DishProgressUpdate>[];
    final result = await service(client).analyze(image, onStage: progress.add);
    expect(client.requests.single.method, 'POST');
    expect(client.requests.single.url.path, '/scan/dish');
    expect(
      client.requests.single.headers['Authorization'],
      'Bearer local-test-token',
    );
    expect(client.requests.single.headers['Accept'], 'text/event-stream');
    expect(client.requests.single.followRedirects, isFalse);
    expect(body, isNot(contains('user_allergens')));
    expect(body, isNot(contains('user_id')));
    expect(auth.tokenRefreshes, [false]);
    expect(
      progress
          .where((p) => p.status == DishStageStatus.completed)
          .map((p) => p.stage),
      DishScanStage.values,
    );
    expect(result.dishName, 'Crème brûlée');
    expect(result.matches.single.allergens, ['Egg', 'Milk', 'Soybean']);
    expect(client.closed, isTrue);
  });
  test(
    'Parses the real backend nine-stage synthetic contract fixture',
    () async {
      final fixture = File('test/support/dish_backend_stream.sse')
          .readAsStringSync();
      final client = DishClient((_) async => response(fixture, fragment: true));
      final result = await service(client).analyze(image, onStage: (_) {});
      expect(result.dishName, 'Pizza');
      expect(result.matches.expand((m) => m.allergens).toSet(), {
        'Egg',
        'Milk',
        'Soybean',
      });
      final cheese = result.matches
          .expand((m) => m.causes)
          .where((c) => c.originalIngredient == 'cheese')
          .single;
      expect(cheese.source, 'Claude');
      expect(cheese.confidence, 12);
    },
  );
  test(
    'Connection loss during the event body never yields a result or retry',
    () async {
      final client = DishClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.multi((controller) {
            controller.add(utf8.encode(progressFrames().first));
            controller.addError(StateError('private connection failure'));
            controller.close();
          }),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(connection),
      );
      expect(client.requests.length, 1);
    },
  );
  test('SSE decoder supports multiline data and CRLF', () async {
    final payload = jsonEncode({
      'scan_id': 'test-scan',
      'sequence': 1,
      'stage': 'image_received',
      'status': 'completed',
    }).replaceAll(',', ',\n');
    final wire =
        'event: progress\r\n${payload.split('\n').map((line) => 'data: $line').join('\r\n')}\r\n\r\n';
    final events = await decodeDishEvents(Stream.value(utf8.encode(wire)))
        .toList();
    expect(events.single.data['status'], 'completed');
  });
  test('fresh token requested per explicit scan attempt', () async {
    final client = DishClient((_) async => response(successStream()));
    await service(client).analyze(image, onStage: (_) {});
    final second = DishClient((_) async => response(successStream()));
    await service(second).analyze(image, onStage: (_) {});
    expect(auth.tokenRefreshes, [false, false]);
    expect(client.requests.length + second.requests.length, 2);
  });
  test('signed out users never submit', () async {
    auth.signedIn = false;
    final client = DishClient((_) async => response(successStream()));
    await expectLater(
      service(client).analyze(image, onStage: (_) {}),
      throwsA(connection),
    );
    expect(client.requests, isEmpty);
  });
  test('sign out during token retrieval prevents submission', () async {
    auth.pendingToken = Completer<String?>();
    final client = DishClient((_) async => response(successStream()));
    final pending = service(client).analyze(image, onStage: (_) {});
    auth.signedIn = false;
    auth.pendingToken!.complete('old-token');
    await expectLater(pending, throwsA(connection));
    expect(client.requests, isEmpty);
  });
  test('all six outcomes map from server responses', () async {
    for (final entry in {
      'quality': DishScanFailure.lowQuality,
      'food_gate': DishScanFailure.notSingleDish,
      'ood': DishScanFailure.unsupportedDish,
    }.entries) {
      final client = DishClient(
        (_) async => response(
          outcomeFrame({'decision': 'rejected', 'stopped_at': entry.key}),
        ),
      );
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(
          isA<DishScanException>().having(
            (e) => e.reason,
            'reason',
            entry.value,
          ),
        ),
      );
    }
    final noMatches = DishClient(
      (_) async => response(successStream(matches: false)),
    );
    expect(
      (await service(noMatches).analyze(image, onStage: (_) {})).matches,
      isEmpty,
    );
    final matches = DishClient((_) async => response(successStream()));
    expect(
      (await service(matches).analyze(image, onStage: (_) {})).matches,
      isNotEmpty,
    );
    final error = DishClient(
      (_) async => response(outcomeFrame({'decision': 'error'}, status: 503)),
    );
    await expectLater(
      service(error).analyze(image, onStage: (_) {}),
      throwsA(connection),
    );
  });
  for (final code in [404, 500, 503]) {
    test('HTTP $code retains internal diagnostics without retrying', () async {
      const details = '{"detail":"PRIVATE_PROFILE_FAILURE"}';
      final client = DishClient(
        (_) async => response(details, code: code, type: 'application/json'),
      );
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(
          connection
              .having((e) => e.statusCode, 'statusCode', code)
              .having((e) => e.transportStatusCode, 'transportStatusCode', code)
              .having((e) => e.diagnosticDetails, 'diagnosticDetails', details),
        ),
      );
      expect(client.requests, hasLength(1));
      expect(client.closed, isTrue);
    });
    test(
      'SSE outcome $code retains its actual status and diagnostic result',
      () async {
        final result = {
          'decision': 'error',
          'stopped_at': 'user_allergy_matching',
          'personalization': {
            'status': 'error',
            'error_code': 'profile_unavailable',
          },
          'message': 'PRIVATE_PROFILE_FAILURE',
        };
        final client = DishClient(
          (_) async => response(outcomeFrame(result, status: code)),
        );
        await expectLater(
          service(client).analyze(image, onStage: (_) {}),
          throwsA(
            connection
                .having((e) => e.statusCode, 'statusCode', code)
                .having(
                  (e) => e.transportStatusCode,
                  'transportStatusCode',
                  200,
                )
                .having(
                  (e) => (e.diagnosticDetails as Map)['result'],
                  'result',
                  result,
                ),
          ),
        );
        expect(client.requests, hasLength(1));
        expect(client.closed, isTrue);
      },
    );
  }
  test(
    'Obsolete Dish outcome is rejected through the connection error path',
    () async {
      final result = matchedResponse(matches: false);
      result['personalization']['selected_allergies'] = <String>[];
      result['personalization']['match_status'] = 'no_allergies_selected';
      final client = DishClient(
        (_) async =>
            response('${progressFrames().join()}${outcomeFrame(result)}'),
      );
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(
          connection
              .having((e) => e.statusCode, 'statusCode', 200)
              .having(
                (e) => e.diagnosticDetails,
                'parser error',
                isA<FormatException>(),
              )
              .having(
                (e) => e.diagnosticStackTrace,
                'internal stack',
                isNotNull,
              ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );
  test('401, 429, 500, redirect and network failure never retry', () async {
    for (final code in [401, 429, 500, 302]) {
      final client = DishClient((_) async => response('', code: code));
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(connection),
      );
      expect(client.requests.length, 1);
      expect(client.closed, isTrue);
    }
    final client = DishClient(
      (_) async => throw StateError('private network error'),
    );
    await expectLater(
      service(client).analyze(image, onStage: (_) {}),
      throwsA(connection),
    );
    expect(client.requests.length, 1);
  });
  test(
    'incomplete personalization with known matches is an analysis error',
    () async {
      final result = matchedResponse();
      result['personalization']['status'] = 'incomplete';
      result['personalization']['unresolved_profile_terms'] = [
        'unknown allergy',
      ];
      final client = DishClient(
        (_) async =>
            response('${progressFrames().join()}${outcomeFrame(result)}'),
      );
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(connection),
      );
    },
  );
  test('missing terminal, malformed events, unconfirmed progress and wrong scan fail safely', () async {
    final badStreams = [
      progressFrames().join(),
      'event: progress\ndata: {bad}\n\n',
      'event: progress\ndata: {}',
      outcomeFrame(matchedResponse()),
      '${progressFrames().first}${event('progress', {'scan_id': 'wrong-scan', 'sequence': 2, 'stage': 'image_received', 'status': 'completed'})}',
      event('progress', {
        'scan_id': 'test-scan',
        'sequence': 1,
        'stage': 'checking_allergens',
        'status': 'completed',
      }),
    ];
    for (final text in badStreams) {
      final client = DishClient((_) async => response(text, fragment: true));
      await expectLater(
        service(client).analyze(image, onStage: (_) {}),
        throwsA(connection),
      );
      expect(client.requests.length, 1);
    }
  });
  test('comments and duplicate event sequences do not create fake progress', () async {
    final parts = progressFrames();
    final text =
        ': heartbeat\r\n\r\n${parts.first}${parts.first}${parts.skip(1).join()}${outcomeFrame(matchedResponse())}';
    final client = DishClient((_) async => response(text));
    final progress = <DishProgressUpdate>[];
    await service(client).analyze(image, onStage: progress.add);
    expect(progress.length, 6);
  });
  test(
    'deadline includes token retrieval and prevents a late paid submission',
    () async {
      auth.pendingToken = Completer<String?>();
      final client = DishClient((_) async => response(successStream()));
      await expectLater(
        service(
          client,
          timeout: const Duration(milliseconds: 20),
        ).analyze(image, onStage: (_) {}),
        throwsA(connection),
      );
      auth.pendingToken!.complete('late-token');
      await Future<void>.delayed(Duration.zero);
      expect(client.requests, isEmpty);
      expect(client.closed, isTrue);
    },
  );
  test('total deadline is not reset by stream activity', () async {
    final bytes = StreamController<List<int>>();
    final client = DishClient(
      (_) async => http.StreamedResponse(
        bytes.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    client.onClose = () {
      bytes.close();
    };
    final timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => bytes.add(utf8.encode(': heartbeat\n\n')),
    );
    try {
      await expectLater(
        service(
          client,
          timeout: const Duration(milliseconds: 35),
        ).analyze(image, onStage: (_) {}),
        throwsA(connection),
      );
      expect(client.requests.length, 1);
      expect(client.closed, isTrue);
    } finally {
      timer.cancel();
    }
  });
  test(
    'cancellation closes only the owned Dish client and never resubmits',
    () async {
      final bytes = StreamController<List<int>>();
      final client = DishClient(
        (_) async => http.StreamedResponse(
          bytes.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      client.onClose = () {
        bytes.close();
      };
      final cancellation = DishScanCancellation();
      final pending = service(client)
          .analyze(image, onStage: (_) {}, cancellation: cancellation);
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      await expectLater(pending, throwsA(isA<DishScanCancelled>()));
      expect(client.requests.length, 1);
      expect(client.closed, isTrue);
    },
  );
}
