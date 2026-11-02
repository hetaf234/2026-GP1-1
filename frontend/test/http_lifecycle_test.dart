import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/models/scan_result.dart';
import 'package:misbar_app/services/allergen_scanner_service.dart';
import 'package:misbar_app/services/allergy_service.dart';
import 'package:misbar_app/services/api_service.dart';

import 'support/http_lifecycle_doubles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LifecycleHttpClient client;
  late ApiService api;
  late TestAuth auth;

  setUpAll(() async {
    auth = await initializeTestAuth();
    client = LifecycleHttpClient();
    // Intercept only construction in this test isolate; production is untouched.
    api = http.runWithClient(ApiService.new, () => client);
    expect(identical(api, ApiService()), isTrue);
  });

  setUp(() {
    client.requests.clear();
    client.pendingScan = null;
    client.scanStarted = null;
    client.nextStatus = null;
    client.failNetwork = false;
    client.allergyResponse = null;
    client.pendingAllergies = null;
    client.pendingSave = null;
    client.savedAllergies = ['Milk'];
    auth.signedIn = true;
    auth.userId = 'local-test-user';
    auth.pendingToken = null;
    auth.tokenRefreshes.clear();
  });

  tearDownAll(() => api.dispose());

  test(
    'Selection metadata distinguishes saved, incomplete and invalid data',
    () async {
      client.allergyResponse = {
        'allergies': ['Milk'],
        'allergy_selection_saved': true,
      };
      expect(await api.getUserAllergies(), ['Milk']);
      client.allergyResponse = {
        'allergies': <String>[],
        'allergy_selection_saved': false,
      };
      expect(await api.getUserAllergies(), isEmpty);
      for (final body in [
        {'allergies': <String>[], 'allergy_selection_saved': true},
        {
          'allergies': ['Milk'],
          'allergy_selection_saved': false,
        },
        {
          'allergies': ['Milk'],
          'allergy_selection_saved': 'true',
        },
      ]) {
        client.allergyResponse = body;
        await expectLater(api.getUserAllergies(), throwsFormatException);
      }
    },
  );

  test(
    'Changing account while token is pending cannot send the old request',
    () async {
      final token = Completer<String?>();
      auth.pendingToken = token;
      final rejected = expectLater(api.getUserAllergies(), throwsStateError);
      auth.userId = 'other-local-user';
      token.complete('old-local-token');
      await rejected;
      expect(client.requests, isEmpty);
    },
  );

  test(
    'Old account response cannot be reused or refresh as the new user',
    () async {
      final pending = Completer<http.StreamedResponse>();
      client.pendingAllergies = pending;
      final rejected = expectLater(api.getUserAllergies(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(client.requests, hasLength(1));
      auth.userId = 'other-local-user';
      pending.complete(
        LifecycleHttpClient.response({'detail': 'expired'}, status: 401),
      );
      await rejected;
      expect(client.requests, hasLength(1));
      expect(auth.tokenRefreshes, [false]);
      client.pendingAllergies = null;
      client.savedAllergies = ['Fish'];
      expect(await api.getUserAllergies(), ['Fish']);
    },
  );

  test(
    'Configured cloud failure never falls back to laptop or emulator hosts',
    () async {
      client.failNetwork = true;
      await expectLater(
        api.getUserAllergies(),
        throwsA(isA<http.ClientException>()),
      );
      expect(client.requests.length, 1);
      expect(
        client.requests.single.request.url.host,
        Uri.parse(ApiService.configuredBaseUrl).host,
      );
    },
    skip: ApiService.configuredBaseUrl.trim().isEmpty,
  );

  test(
    'Disposing one scanner preserves shared profile, allergies and scans',
    () async {
      final first = AllergenScannerService();
      final second = AllergenScannerService();
      final allergies = AllergyService();
      expect(await allergies.fetchUserAllergies(), ['Milk']);

      first.dispose();
      first.dispose();
      expect(client.closeCount, 0);
      expect(await api.getProfile(), containsPair('name', 'Test User'));
      await allergies.saveUserAllergies(['Egg']);
      expect(await allergies.fetchUserAllergies(), ['Egg']);
      expect((await second.scanText('Local test text')).success, isTrue);
      expect(
        (await second.scanImageBytes(Uint8List.fromList([1, 2, 3]))).success,
        isTrue,
      );
      second.dispose();
      expect(client.closed, isFalse);

      for (final record in client.requests) {
        expect(
          record.request.headers['Authorization'],
          'Bearer local-test-token',
        );
        expect(record.body, isNot(contains('user_allergens')));
      }
      final textRequest = client.requests.singleWhere(
        (r) => r.request.url.path == '/scan/text',
      );
      expect(jsonDecode(textRequest.body), {'text': 'Local test text'});
      final imageRequest = client.requests.singleWhere(
        (r) => r.request.url.path == '/scan/image',
      );
      expect(imageRequest.body, contains('name="file"; filename="label.jpg"'));
    },
  );

  for (final image in [true, false]) {
    for (final dispose in [true, false]) {
      for (final fail in [true, false]) {
        test(
          '${image ? 'Image' : 'Text'} ignores late ${fail ? 'failure' : 'result'} after ${dispose ? 'disposal' : 'cancellation'}',
          () async {
            final scanner = AllergenScannerService();
            final pending = Completer<http.StreamedResponse>();
            final started = Completer<void>();
            client.pendingScan = pending;
            client.scanStarted = started;
            final future = image
                ? scanner.scanImageBytes(Uint8List.fromList([1, 2, 3]))
                : scanner.scanText('Local test');
            final assertion = expectLater(
              future,
              throwsA(isA<ScanCancelledException>()),
            );
            await started.future;
            if (dispose) {
              scanner.dispose();
            } else {
              scanner.cancelCurrentScan();
            }
            pending.complete(
              LifecycleHttpClient.response(
                fail
                    ? {'detail': 'Test failure'}
                    : LifecycleHttpClient.scanBody,
                status: fail ? 500 : 200,
              ),
            );
            await assertion;
            expect(client.closed, isFalse);
            client.pendingScan = null;
            if (!dispose) {
              expect((await scanner.scanText('New scan')).success, isTrue);
            }
            scanner.dispose();
          },
        );
      }
    }
  }

  test(
    'Disposed scanner rejects new image and text requests before HTTP',
    () async {
      final scanner = AllergenScannerService()..dispose();
      await expectLater(
        scanner.scanText('Test'),
        throwsA(isA<ScanCancelledException>()),
      );
      await expectLater(
        scanner.scanImageBytes(Uint8List(0)),
        throwsA(isA<ScanCancelledException>()),
      );
      expect(client.requests, isEmpty);
    },
  );

  test('New scan completes while an older generation is discarded', () async {
    final scanner = AllergenScannerService();
    final started = Completer<void>();
    final pending = Completer<http.StreamedResponse>();
    client.pendingScan = pending;
    client.scanStarted = started;
    final old = scanner.scanText('Old');
    final oldAssertion = expectLater(
      old,
      throwsA(isA<ScanCancelledException>()),
    );
    await started.future;
    client.pendingScan = null;
    final ScanResult latest = await scanner.scanText('Latest');
    expect(latest.success, isTrue);
    pending.complete(
      LifecycleHttpClient.response(LifecycleHttpClient.scanBody),
    );
    await oldAssertion;
    scanner.dispose();
  });

  test('Current scan preserves real API errors', () async {
    final scanner = AllergenScannerService();
    client.nextStatus = 503;
    await expectLater(
      scanner.scanText('Test'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 503)),
    );
    expect(client.requests.length, 1);
    scanner.dispose();
  });

  test('Missing authentication cannot send a request', () async {
    auth.signedIn = false;
    await expectLater(api.getUserAllergies(), throwsA(isA<SocketException>()));
    expect(client.requests, isEmpty);
  });

  test(
    '401 still refreshes Firebase token and retries authenticated request',
    () async {
      client.nextStatus = 401;
      expect(await api.getUserAllergies(), ['Milk']);
      expect(auth.tokenRefreshes, [false, true]);
      expect(client.requests.length, 2);
      expect(
        client.requests.last.request.headers['Authorization'],
        'Bearer local-test-token',
      );
    },
  );
  test(
    'An explicit empty read is preserved; an empty save sends no request',
    () async {
      client.savedAllergies = [];
      expect(await api.getUserAllergies(), isEmpty);
      client.requests.clear();
      await expectLater(api.saveUserAllergies([]), throwsFormatException);
      expect(client.requests, isEmpty);
    },
  );

  test('Malformed or noncanonical reads never become empty selections or retry other hosts', () async {
    for (final body in <Object>[
      {},
      {'allergies': null},
      {'allergies': 'Milk'},
      {
        'allergies': [123],
      },
      {
        'allergies': ['Dairy allergy'],
      },
      {
        'allergies': ['milk'],
      },
      {
        'allergies': ['Milk '],
      },
      {
        'allergies': ['Milk', 'Milk'],
      },
    ]) {
      client.requests.clear();
      client.allergyResponse = body;
      await expectLater(api.getUserAllergies(), throwsFormatException);
      expect(client.requests, hasLength(1));
    }
  });

  test('All 14 names are sent and confirmed without conversions', () async {
    for (final item in AllergenDetection.categories) {
      client.requests.clear();
      expect(await api.saveUserAllergies([item.name]), [item.name]);
      expect(jsonDecode(client.requests.single.body), {
        'allergies': [item.name],
      });
      expect(await api.getUserAllergies(), [item.name]);
    }
  });

  test(
    'Invalid selections are rejected before authentication or HTTP',
    () async {
      for (final values in [
        <String>[],
        ['Gluten'],
        ['Dairy allergy'],
        ['Milk '],
        ['milk'],
        ['Milk', 'Milk'],
      ]) {
        await expectLater(api.saveUserAllergies(values), throwsFormatException);
      }
      expect(client.requests, isEmpty);
    },
  );

  test(
    'A write needs an exact nonempty confirmation from the server',
    () async {
      for (final body in <Object>[
        {},
        {'allergies': null},
        {'allergies': []},
        {
          'allergies': ['Egg'],
        },
        {
          'allergies': ['Milk', 'Milk'],
        },
        {
          'allergies': [123],
        },
      ]) {
        client.requests.clear();
        client.allergyResponse = body;
        await expectLater(
          api.saveUserAllergies(['Milk']),
          throwsFormatException,
        );
        expect(client.requests, hasLength(1));
      }
    },
  );
}
