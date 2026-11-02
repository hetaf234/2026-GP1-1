import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/screens/error_screen.dart';
import 'package:misbar_app/screens/scan_result_screen.dart';
import 'package:misbar_app/screens/scanning_screen.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';
import 'package:misbar_app/services/api_service.dart';
import 'package:misbar_app/widgets/app_header.dart';

import 'support/http_lifecycle_doubles.dart';
import 'support/label_sse_fixtures.dart';

const _snapshotKey = ValueKey('label-sse-snapshot');

Future<void> _snapshot(WidgetTester tester, String name) async {
  final directory = Platform.environment['LABEL_SSE_SCREENSHOT_DIR'];
  if (directory == null) return;
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/images/misbar_logo.png'),
      tester.element(find.byType(AppHeader)),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_snapshotKey),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

class _ProgressTransport extends http.BaseClient {
  late StreamController<List<int>> controller;
  final requests = <http.BaseRequest>[];
  int status = 200;
  int aborts = 0;
  bool closed = false;
  void reset() {
    requests.clear();
    status = 200;
    aborts = 0;
    controller = StreamController<List<int>>();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await request.finalize().toBytes();
    if (request is http.Abortable) request.abortTrigger?.then((_) => aborts++);
    return http.StreamedResponse(
      controller.stream,
      status,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  void emit(String event) => controller.add(utf8.encode(event));
  void finish() {
    controller.close();
  }

  @override
  void close() => closed = true;
}

class _LateApi implements ApiService {
  final result = Completer<ScanResult>();
  late void Function(LabelProgressUpdate) update;
  int calls = 0;
  @override
  Future<ScanResult> scanImageWithProgress(
    Uint8List imageBytes, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) {
    calls++;
    update = onProgress;
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TestAuth auth;
  late _ProgressTransport transport;
  late ApiService api;
  setUpAll(() async {
    final fontPath = Platform.environment['LABEL_SSE_FONT_FILE'];
    if (fontPath != null) {
      final font = FontLoader('Roboto');
      font.addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        File('${File(fontPath).parent.path}/MaterialIcons-Regular.otf')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
      await icons.load();
    }
    auth = await initializeTestAuth();
    transport = _ProgressTransport();
    api = http.runWithClient(ApiService.new, () => transport);
  });
  setUp(() {
    auth.signedIn = true;
    auth.userId = 'local-test-user';
    auth.pendingToken = null;
    transport.reset();
  });
  tearDown(() {
    transport.finish();
  });
  tearDownAll(() => api.dispose());

  Future<void> open(
    WidgetTester tester, {
    double width = 390,
    double textScale = 1,
    AllergenScannerService? scanner,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _snapshotKey,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ScanningScreen(
                      imageBytes: Uint8List.fromList([1, 2, 3]),
                      userAllergens: const ['Milk'],
                      scannerService: scanner ?? AllergenScannerService(),
                    ),
                  ),
                ),
                child: const Text('Open label scan'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open label scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Finder stage(LabelScanStage stage) =>
      find.byKey(ValueKey('label-stage-${stage.id}'));
  void expectStatus(LabelScanStage item, String text) => expect(
    find.descendant(of: stage(item), matching: find.text(text)),
    findsOneWidget,
  );
  Future<void> advance(WidgetTester tester, int index) async {
    transport.emit(labelProgressFrames()[index]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
  }

  testWidgets(
    'exactly four stages, all pending even after response headers and time',
    (tester) async {
      await open(tester);
      expect(find.text('Analyzing Your Label'), findsOneWidget);
      expect(find.byType(AppHeader), findsOneWidget);
      for (final item in LabelScanStage.values) {
        expect(find.text(item.label), findsOneWidget);
        expectStatus(item, 'Pending');
      }
      expect(find.text('Pending'), findsNWidgets(4));
      expect(find.text('Processing'), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      expect(find.text('Preparing Your Scan'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Pending'), findsNWidgets(4));
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.headers['Accept'], 'text/event-stream');
      expect(
        transport.requests.single.headers['Authorization'],
        'Bearer local-test-token',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'backend events alone advance stages and earlier completions remain',
    (tester) async {
      await open(tester);
      await _snapshot(tester, '01-pending');
      for (var index = 0; index < labelTransitions.length; index++) {
        await advance(tester, index);
        final current = LabelScanStage.fromId(labelTransitions[index].$1);
        final completed = labelTransitions[index].$2 == 'completed';
        for (final item in LabelScanStage.values) {
          expectStatus(
            item,
            item.index < current.index
                ? 'Completed'
                : item == current
                ? (completed ? 'Completed' : 'Processing')
                : 'Pending',
          );
        }
        expect(find.byType(ScanResultScreen), findsNothing);
        if (index == 1 || index == 3 || index == 5) {
          await _snapshot(tester, 'stage-$index');
        }
      }
      expect(find.text('Completed'), findsNWidgets(4));
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(4));
      await _snapshot(tester, '05-completed');
      transport.emit(labelOutcome(LifecycleHttpClient.scanBody));
      await tester.pump();
      expect(
        find.byType(ScanResultScreen),
        findsNothing,
      ); // EOF is required too.
      transport.finish();
      await tester.pumpAndSettle();
      expect(find.byType(ScanResultScreen), findsOneWidget);
      expect(find.text('No Matching Allergens'), findsOneWidget);
      expect(transport.requests, hasLength(1));
      expect(transport.closed, isFalse);
    },
  );

  testWidgets('an unconfirmed or duplicate outcome never navigates to results', (
    tester,
  ) async {
    await open(tester);
    transport.emit(
      '${labelSuccess(LifecycleHttpClient.scanBody)}${labelOutcome(LifecycleHttpClient.scanBody, sequence: 9)}',
    );
    transport.finish();
    await tester.pumpAndSettle();
    expect(find.byType(ScanResultScreen), findsNothing);
    expect(find.text('Connection Error'), findsOneWidget);
    expect(transport.requests, hasLength(1));
  });

  for (final code in [
    'low_quality',
    'no_text',
    'no_ingredients',
    'quality_unavailable',
    'ocr_failed',
    'ingredient_extraction_failed',
    'allergen_check_failed',
    'profile_not_found',
  ]) {
    testWidgets(
      '$code preserves the existing error destination with safe text',
      (tester) async {
        await open(tester);
        transport.emit(
          labelFrame('error', {
            'http_status': 422,
            'code': code,
            'message': 'PRIVATE_PROVIDER_RESPONSE',
          }, 1),
        );
        transport.finish();
        await tester.pumpAndSettle();
        expect(find.byType(ErrorScreen), findsOneWidget);
        expect(find.byType(ScanResultScreen), findsNothing);
        expect(
          find.text(
            code == 'low_quality'
                ? 'Image Not Clear'
                : ['no_text', 'no_ingredients'].contains(code)
                ? 'Label Could Not Be Read'
                : 'Connection Error',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(transport.requests, hasLength(1));
      },
    );
  }

  for (final kind in ['interrupted', 'malformed', 'http-auth']) {
    testWidgets('$kind stream cannot restart itself or produce a result', (
      tester,
    ) async {
      if (kind == 'http-auth') transport.status = 401;
      await open(tester);
      if (kind == 'interrupted') {
        transport.emit(labelProgressFrames().take(2).join());
      }
      if (kind == 'malformed') {
        transport.emit('event: progress\ndata: {broken}\n\n');
      }
      transport.finish();
      // Cancellation can finish in the transport's outer zone. Let that
      // cleanup settle instead of relying on the request deadline to fail it.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorScreen), findsOneWidget);
      expect(find.byType(ScanResultScreen), findsNothing);
      expect(transport.requests, hasLength(1));
    });
  }

  for (final leave in ['Cancel', 'Back', 'dispose']) {
    testWidgets('$leave aborts and ignores a late successful stream', (
      tester,
    ) async {
      await open(tester);
      await advance(tester, 0);
      if (leave == 'Cancel') {
        await tester.ensureVisible(find.text('Cancel'));
        await tester.tap(find.text('Cancel'));
      } else if (leave == 'Back') {
        await tester.tap(find.byTooltip('Back'));
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pumpAndSettle();
      transport.emit(
        labelProgressFrames().skip(1).join() +
            labelOutcome(LifecycleHttpClient.scanBody),
      );
      transport.finish();
      await tester.pumpAndSettle();
      expect(find.byType(ScanResultScreen), findsNothing);
      expect(find.byType(ErrorScreen), findsNothing);
      expect(transport.aborts, 1);
      expect(transport.requests, hasLength(1));
      expect(transport.closed, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rebuilding the loading screen cannot submit a second scan', (
    tester,
  ) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {
      tester.element(find.byType(ScanningScreen)).markNeedsBuild();
      await tester.pump();
    }
    expect(transport.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'old service callbacks and results are ignored after cancellation',
    (tester) async {
      final old = _LateApi();
      final scanner = AllergenScannerService(apiService: old);
      await open(tester, scanner: scanner);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      old.update(
        const LabelProgressUpdate(
          LabelScanStage.checkingAllergens,
          LabelStageStatus.completed,
        ),
      );
      old.result.complete(ScanResult.fromJson(LifecycleHttpClient.scanBody));
      await tester.pumpAndSettle();
      expect(find.byType(ScanResultScreen), findsNothing);
      expect(find.byType(ErrorScreen), findsNothing);
      expect(old.calls, 1);
      expect(tester.takeException(), isNull);
      scanner.dispose();
    },
  );

  for (final width in [320.0, 600.0]) {
    testWidgets(
      'four stages and unified header fit width $width with larger text',
      (tester) async {
        await open(tester, width: width, textScale: 1.6);
        final logo = find.byKey(const ValueKey('app-header-logo'));
        expect(tester.getRect(logo).width, closeTo(94, .01));
        expect(tester.getRect(logo).height, closeTo(72, .01));
        for (final item in LabelScanStage.values) {
          await tester.ensureVisible(stage(item));
          expect(find.text(item.label), findsOneWidget);
        }
        await tester.ensureVisible(find.text('Cancel'));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'account change during forced token retrieval never submits the old scan',
    (tester) async {
      final token = Completer<String?>();
      auth.pendingToken = token;
      await open(tester);
      expect(find.text('Pending'), findsNWidgets(4));
      auth.userId = 'other-local-user';
      token.complete('old-token');
      await tester.pump();
      expect(transport.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
