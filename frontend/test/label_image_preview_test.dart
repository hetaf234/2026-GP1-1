import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/features/dish_scan/dish_capture_screen.dart';
import 'package:misbar_app/features/dish_scan/preview/dish_preview_service.dart';
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/screens/allergy_selection_screen.dart';
import 'package:misbar_app/screens/error_screen.dart';
import 'package:misbar_app/screens/image_capture_screen.dart';
import 'package:misbar_app/screens/scan_result_screen.dart';
import 'package:misbar_app/screens/scanning_screen.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';
import 'package:misbar_app/services/allergy_service.dart';
import 'package:misbar_app/services/api_service.dart';

import 'support/http_lifecycle_doubles.dart';
import 'support/label_sse_fixtures.dart';

class _LabelTransport extends LifecycleHttpClient {
  late StreamController<List<int>> stream;
  final uploads = <Uint8List>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path != '/scan/image') return super.send(request);
    expect(request.method, 'POST');
    expect(request.headers['Accept'], 'text/event-stream');
    final multipart = request as http.MultipartRequest;
    uploads.add(await multipart.files.single.finalize().toBytes());
    return http.StreamedResponse(
      stream.stream,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('com.example.misbar/image_capture');
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  final original = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  late TestAuth auth;
  late _LabelTransport transport;
  late ApiService api;
  late AllergenScannerService scanner;
  late Directory directory;
  late File photo;

  setUpAll(() async {
    // Measure the real UI font instead of the test runner's wide Ahem glyphs.
    final config = File('.dart_tool/package_config.json');
    final packages =
        jsonDecode(await config.readAsString())['packages'] as List;
    final flutter = packages.singleWhere((entry) => entry['name'] == 'flutter');
    final packageUri = config.absolute.uri.resolve(
      flutter['rootUri'] as String,
    );
    final sdk = Directory.fromUri(packageUri).parent.parent;
    final font = FontLoader('Roboto');
    for (final name in ['Roboto-Regular.ttf', 'Roboto-Bold.ttf']) {
      font.addFont(
        File('${sdk.path}/bin/cache/artifacts/material_fonts/$name')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
    }
    await font.load();
    auth = await initializeTestAuth();
    transport = _LabelTransport();
    api = http.runWithClient(ApiService.new, () => transport);
  });

  setUp(() async {
    auth.signedIn = true;
    auth.pendingToken = null;
    transport.stream = StreamController<List<int>>();
    transport.uploads.clear();
    transport.requests.clear();
    transport.savedAllergies = ['Milk'];
    scanner = AllergenScannerService(apiService: api);
    AllergyService().setLocalAllergies(['Milk']);
    directory = await Directory.systemTemp.createTemp('misbar-label-preview-');
    photo = await File('${directory.path}/original.png').writeAsBytes(original);
  });

  tearDown(() async {
    scanner.dispose();
    unawaited(transport.stream.close());
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(native, null)
      ..setMockMethodCallHandler(picker, null);
  });
  tearDownAll(() => api.dispose());

  Future<void> open(
    WidgetTester tester, {
    Uint8List? bytes,
    bool nativeCapture = false,
    double width = 390,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImageCaptureScreen(
                  userAllergens: const ['Milk'],
                  scannerService: scanner,
                  initialImageBytes: bytes,
                  useNativeCapture: nativeCapture,
                ),
              ),
            ),
            child: const Text('Open label'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open label'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  // File IO runs outside the widget test's fake clock. Wait for the existing
  // temporary-file cleanup, rather than guessing when the image read completes.
  Future<void> choose(WidgetTester tester, String action, File file) async {
    final button = find.byTooltip(action).evaluate().isNotEmpty
        ? find.byTooltip(action)
        : find.text(action);
    await tester.ensureVisible(button);
    await tester.runAsync(() async {
      await tester.tap(button);
      for (var i = 0; i < 1000; i++) {
        if (!await file.exists()) return;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      throw StateError('Selected image was not read and cleaned up.');
    });
    await tester.pumpAndSettle();
  }

  void expectPreview(WidgetTester tester, Uint8List bytes) {
    expect(find.text('Analyze Label'), findsOneWidget);
    expect(find.byType(ScanningScreen), findsNothing);
    final preview = tester.widget<Image>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image && widget.semanticLabel == 'Selected label photo',
      ),
    );
    expect((preview.image as MemoryImage).bytes, orderedEquals(bytes));
    expect(preview.fit, BoxFit.cover);
    expect(transport.uploads, isEmpty);
  }

  testWidgets('initial label camera and gallery controls match Dish Scan', (
    tester,
  ) async {
    await open(tester);
    // Settle the route transition while the label viewfinder keeps animating.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Flash'), findsNothing);
    expect(find.text('Analyze Label'), findsNothing);
    List<Object?> controls() => [
      for (final caption in ['Take Photo', 'Upload Image']) ...[
        tester.getSize(find.byTooltip(caption)),
        tester.getCenter(find.byTooltip(caption)).dx,
        (tester
                    .widget<IconButton>(
                      find.widgetWithIcon(
                        IconButton,
                        caption == 'Take Photo'
                            ? Icons.photo_camera_outlined
                            : Icons.photo_library_outlined,
                      ),
                    )
                    .icon
                as Icon)
            .size,
        tester
            .widget<IconButton>(
              find.widgetWithIcon(
                IconButton,
                caption == 'Take Photo'
                    ? Icons.photo_camera_outlined
                    : Icons.photo_library_outlined,
              ),
            )
            .style!
            .backgroundColor!
            .resolve({}),
        tester
            .widget<IconButton>(
              find.widgetWithIcon(
                IconButton,
                caption == 'Take Photo'
                    ? Icons.photo_camera_outlined
                    : Icons.photo_library_outlined,
              ),
            )
            .style!
            .side!
            .resolve({}),
        tester.widget<Text>(find.text(caption)).style,
      ],
    ];
    final labelControls = controls();
    await tester.pumpWidget(
      const MaterialApp(
        key: ValueKey('dish-initial-reference'),
        home: DishCaptureScreen(
          userAllergens: ['Milk'],
          scanner: PreviewDishScanService(DishPreviewScenario.noMatches),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controls(), labelControls);
    expect(transport.uploads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final source in [('Take Photo', 0), ('Upload Image', 1)]) {
    testWidgets(
      '${source.$1} previews original bytes before one confirmed SSE scan',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
          call,
        ) async {
          expect(call.method, 'pickImage');
          final arguments = call.arguments as Map;
          expect(arguments['source'], source.$2);
          expect(arguments['maxWidth'], isNull);
          expect(arguments['maxHeight'], isNull);
          expect(arguments['imageQuality'], isNull);
          return photo.path;
        });
        await open(tester);
        await choose(tester, source.$1, photo);
        expectPreview(tester, original);

        // A queued second confirmation still submits exactly one request.
        await tester.ensureVisible(find.text('Analyze Label'));
        final confirm = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Analyze Label'),
            )
            .onPressed!;
        await tester.tap(find.text('Analyze Label'));
        confirm();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ScanningScreen), findsOneWidget);
        expect(transport.uploads, hasLength(1));
        expect(transport.uploads.single, orderedEquals(original));
        transport.stream.add(utf8.encode(labelProgressFrames().take(2).join()));
        await tester.pump();
        expect(find.byType(ScanResultScreen), findsNothing);
        transport.stream.add(
          utf8.encode(
            '${labelProgressFrames().skip(2).join()}${labelOutcome(LifecycleHttpClient.scanBody)}',
          ),
        );
        unawaited(transport.stream.close());
        await tester.pumpAndSettle();
        expect(find.byType(ScanResultScreen), findsOneWidget);
        expect(transport.uploads, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final entry in ['chooser', 'result', 'blurry', 'unreadable']) {
    testWidgets('native $entry selection reaches preview without submitting', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        expect(call.method, 'openImageCapture');
        expect((call.arguments as Map)['header'], isA<Map>());
        return photo.path;
      });
      final result = ScanResult.fromJson(LifecycleHttpClient.scanBody);
      await tester.pumpWidget(
        MaterialApp(
          home: entry == 'chooser'
              ? const AllergySelectionScreen()
              : entry == 'result'
              ? ScanResultScreen(
                  result: result,
                  imageBytes: original,
                  userAllergens: const ['Milk'],
                  scannerService: scanner,
                )
              : ErrorScreen(
                  type: entry == 'blurry'
                      ? ErrorType.imageBlurry
                      : ErrorType.labelUnreadable,
                  imageBytes: original,
                  userAllergens: const ['Milk'],
                  scannerService: scanner,
                ),
        ),
      );
      await tester.pumpAndSettle();
      if (entry == 'chooser') {
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
      }
      await choose(tester, switch (entry) {
        'chooser' => 'Scan Packaged Food Label',
        'result' => 'Scan Another Label',
        _ => 'Try Again',
      }, photo);
      expectPreview(tester, original);
      expect(
        tester
            .widget<ImageCaptureScreen>(find.byType(ImageCaptureScreen))
            .useNativeCapture,
        isTrue,
      );
      expect(find.byTooltip('Retake Photo'), findsOneWidget);
      expect(find.byTooltip('Upload Image'), findsOneWidget);
    });
  }

  for (final action in [
    ('Retake Photo', 'camera'),
    ('Upload Image', 'gallery'),
  ]) {
    testWidgets(
      'native ${action.$2} cancel retains image; replacement needs fresh confirmation',
      (tester) async {
        var calls = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          call,
        ) async {
          expect((call.arguments as Map)['source'], action.$2);
          calls++;
          return calls == 1 ? null : photo.path;
        });
        final previous = Uint8List.fromList([...original, 1, 2, 3]);
        await open(tester, bytes: previous, nativeCapture: true);
        await tester.tap(find.byTooltip(action.$1));
        await tester.pumpAndSettle();
        expectPreview(tester, previous);
        await choose(tester, action.$1, photo);
        expectPreview(tester, original);
        await tester.tap(find.text('Analyze Label'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(transport.uploads.single, orderedEquals(original));
        expect(calls, 2);
      },
    );
  }

  for (final exit in ['Back', 'system']) {
    testWidgets('$exit exits preview without scanning or late navigation', (
      tester,
    ) async {
      await open(tester, bytes: original, nativeCapture: true);
      if (exit == 'system') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('Back'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Open label'), findsOneWidget);
      expect(find.byType(ImageCaptureScreen), findsNothing);
      expect(transport.uploads, isEmpty);
    });
  }

  testWidgets('leaving while native replacement is pending cannot analyze', (
    tester,
  ) async {
    final selection = Completer<String?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (_) => selection.future,
    );
    await open(tester, bytes: original, nativeCapture: true);
    await tester.tap(find.byTooltip('Retake Photo'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Analyze Label'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      selection.complete(photo.path);
      for (var i = 0; i < 1000 && await photo.exists(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Open label'), findsOneWidget);
    expect(transport.uploads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 600.0]) {
    testWidgets('label preview matches actual dish geometry at $width', (
      tester,
    ) async {
      await open(tester, bytes: original, nativeCapture: true, width: width);
      await tester.pumpAndSettle();
      final labelPhoto = find.byWidgetPredicate(
        (widget) =>
            widget is Image && widget.semanticLabel == 'Selected label photo',
      );
      final labelRects = [
        tester.getRect(labelPhoto),
        tester.getRect(find.widgetWithText(FilledButton, 'Analyze Label')),
        tester.getRect(find.byTooltip('Retake Photo')),
        tester.getRect(find.byTooltip('Upload Image')),
      ];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (_) async => photo.path,
      );
      await tester.pumpWidget(
        const MaterialApp(
          key: ValueKey('dish-reference'),
          home: DishCaptureScreen(
            userAllergens: ['Milk'],
            scanner: PreviewDishScanService(DishPreviewScenario.noMatches),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Take Photo'));
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Take Photo'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final dishPhoto = find.byWidgetPredicate(
        (widget) =>
            widget is Image && widget.semanticLabel == 'Selected dish photo',
      );
      Scrollable.of(tester.element(dishPhoto)).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect([
        tester.getRect(dishPhoto),
        tester.getRect(find.widgetWithText(FilledButton, 'Analyze Dish')),
        tester.getRect(find.byTooltip('Retake Photo')),
        tester.getRect(find.byTooltip('Upload Image')),
      ], labelRects);
      expect(tester.takeException(), isNull);
      expect(transport.uploads, isEmpty);
    });
  }

  for (final width in [320.0, 600.0]) {
    testWidgets(
      'preview fits $width with large text and keeps original image',
      (tester) async {
        await open(tester, bytes: original, width: width, textScale: 1.5);
        await tester.pumpAndSettle();
        expectPreview(tester, original);
        await tester.ensureVisible(find.text('Analyze Label'));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
