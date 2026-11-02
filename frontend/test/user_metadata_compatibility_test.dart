import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:misbar_app/services/api_service.dart';
import 'package:misbar_app/services/auth_service.dart';

import 'support/http_lifecycle_doubles.dart';

class _ProfileTransport extends http.BaseClient {
  Map<String, dynamic> profile = {};
  final requests = <RecordedRequest>[];
  bool failProfile = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = utf8.decode(await request.finalize().toBytes());
    requests.add(RecordedRequest(request, body));
    if (request.url.path == '/users/profile') {
      if (failProfile) {
        return LifecycleHttpClient.response({
          'detail': 'Unavailable',
        }, status: 503);
      }
      return LifecycleHttpClient.response(profile);
    }
    if (request.url.path == '/users/me') {
      return LifecycleHttpClient.response(profile);
    }
    throw StateError('Unexpected local endpoint');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAuth identity;
  late _ProfileTransport transport;
  late ApiService api;
  late AuthService auth;

  setUpAll(() async {
    identity = await initializeTestAuth();
    transport = _ProfileTransport();
    api = http.runWithClient(ApiService.new, () => transport);
    auth = AuthService();
  });

  setUp(() {
    identity.signedIn = true;
    identity.userId = 'local-test-user';
    identity.createAccountCalls = 0;
    identity.displayNameUpdates.clear();
    transport.requests.clear();
    transport.failProfile = false;
    transport.profile = {
      'uid': 'local-test-user',
      'name': 'Fixture',
      'email': 'fixture@example.invalid',
      'allergies': ['Milk'],
      'allergy_selection_saved': true,
      'language': 'en',
      'role': 'member',
    };
  });

  tearDownAll(() => api.dispose());

  test('registration uses existing Firebase and trusted profile endpoint without metadata input', () async {
    final credential = await auth.signUp(
      name: ' Fixture ',
      email: ' fixture@example.invalid ',
      password: 'Local-test-password!1',
    );
    expect(credential.user?.uid, 'local-test-user');
    expect(identity.createAccountCalls, 1);
    expect(identity.displayNameUpdates, ['Fixture']);
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.request.url.path, '/users/profile');
    expect(request.request.method, 'POST');
    expect(request.request.headers['Authorization'], 'Bearer local-test-token');
    expect(jsonDecode(request.body), {
      'name': 'Fixture',
      'email': 'fixture@example.invalid',
    });
  });

  test('new server metadata survives profile response parsing', () async {
    final profile = await api.getProfile();
    expect(profile['role'], 'member');
    expect(profile['language'], 'en');
    expect(profile['allergies'], ['Milk']);
    expect(profile['allergy_selection_saved'], isTrue);
  });

  test(
    'existing administrative role and language are preserved in reads',
    () async {
      transport.profile['role'] = 'admin';
      transport.profile['language'] = 'ar-SA';
      final profile = await api.getProfile();
      expect(profile['role'], 'admin');
      expect(profile['language'], 'ar-SA');
      expect(profile['allergies'], ['Milk']);
      expect(transport.requests.single.request.method, 'GET');
    },
  );

  test('profile updates send only existing editable fields', () async {
    transport.profile['role'] = 'admin';
    transport.profile['language'] = 'fr';
    final profile = await api.updateProfile(name: 'Changed');
    expect(jsonDecode(transport.requests.single.body), {'name': 'Changed'});
    expect(profile['role'], 'admin');
    expect(profile['language'], 'fr');
    expect(profile['allergies'], ['Milk']);
  });

  test('legacy profile responses without metadata remain readable', () async {
    transport.profile.remove('language');
    transport.profile.remove('role');
    final profile = await api.getProfile();
    expect(profile['name'], 'Fixture');
    expect(profile['allergies'], ['Milk']);
    expect(profile['allergy_selection_saved'], isTrue);
  });

  test('existing sign in remains independent of profile metadata', () async {
    identity.signedIn = false;
    transport.profile['role'] = 'admin';
    transport.profile['language'] = 'ar';
    final credential = await auth.signIn(
      email: 'fixture@example.invalid',
      password: 'Local-test-password!1',
    );
    expect(credential.user?.uid, 'local-test-user');
    expect(transport.requests, isEmpty);
    expect(transport.profile['role'], 'admin');
    expect(transport.profile['allergies'], ['Milk']);
  });

  test(
    'existing deferred profile initialization does not add registration steps',
    () async {
      transport.failProfile = true;
      final credential = await auth.signUp(
        name: 'Fixture',
        email: 'fixture@example.invalid',
        password: 'Local-test-password!1',
      );
      expect(credential.user?.uid, 'local-test-user');
      expect(identity.createAccountCalls, 1);
      expect(
        jsonDecode(transport.requests.single.body).keys,
        unorderedEquals(['name', 'email']),
      );
    },
  );
}
