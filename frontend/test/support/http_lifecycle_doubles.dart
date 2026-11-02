import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:http/http.dart' as http;

import 'label_sse_fixtures.dart';

/// Entirely local Firebase identity. No real account, token or Firebase request.
Future<TestAuth> initializeTestAuth() async {
  setupFirebaseCoreMocks();
  final auth = TestAuth();
  FirebaseAuthPlatform.instance = auth;
  await Firebase.initializeApp();
  return auth;
}

class TestAuth extends FirebaseAuthPlatform {
  bool _signedIn = true;
  bool get signedIn => _signedIn;
  set signedIn(bool value) {
    _signedIn = value;
    _changes.add(currentUser);
  }

  String userId = 'local-test-user';
  int signOutCalls = 0;
  bool failSignOut = false;
  final _changes = StreamController<UserPlatform?>.broadcast();
  Completer<String?>? pendingToken;
  final List<bool> tokenRefreshes = [];
  int createAccountCalls = 0;
  final List<String?> displayNameUpdates = [];
  late final UserPlatform user = _TestUser(this);

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseAuthPlatform setInitialValues({
    PigeonUserDetails? currentUser,
    String? languageCode,
  }) => this;

  @override
  UserPlatform? get currentUser => signedIn ? user : null;

  @override
  Stream<UserPlatform?> authStateChanges() async* {
    yield currentUser;
    yield* _changes.stream;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (failSignOut) {
      throw FirebaseAuthException(code: 'network-request-failed');
    }
    signedIn = false;
  }

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    signedIn = true;
    return _TestCredential(this);
  }

  @override
  Future<UserCredentialPlatform> createUserWithEmailAndPassword(
    String email,
    String password,
  ) async {
    createAccountCalls++;
    signedIn = true;
    return _TestCredential(this);
  }
}

class _TestCredential extends UserCredentialPlatform {
  _TestCredential(TestAuth auth) : super(auth: auth, user: auth.currentUser);
}

class _TestUser extends UserPlatform {
  final TestAuth testAuth;
  _TestUser(this.testAuth)
    : super(
        testAuth,
        _TestMultiFactor(testAuth),
        PigeonUserDetails(
          userInfo: PigeonUserInfo(
            uid: 'local-test-user',
            displayName: 'Test User',
            isAnonymous: false,
            isEmailVerified: true,
          ),
          providerData: [],
        ),
      );

  @override
  String get uid => testAuth.userId;

  @override
  Future<void> updateProfile(Map<String, String?> profile) async {
    testAuth.displayNameUpdates.add(profile['displayName']);
  }

  @override
  Future<String?> getIdToken(bool forceRefresh) async {
    testAuth.tokenRefreshes.add(forceRefresh);
    return testAuth.pendingToken != null
        ? testAuth.pendingToken!.future
        : 'local-test-token';
  }
}

class _TestMultiFactor extends MultiFactorPlatform {
  _TestMultiFactor(super.auth);
}

class RecordedRequest {
  final http.BaseRequest request;
  final String body;
  RecordedRequest(this.request, this.body);
}

/// Closes like a real client, so closing the shared connection fails tests.
class LifecycleHttpClient extends http.BaseClient {
  bool closed = false;
  int closeCount = 0;
  List<String> savedAllergies = ['Milk'];
  final List<RecordedRequest> requests = [];
  Completer<http.StreamedResponse>? pendingScan;
  Completer<void>? scanStarted;
  int? nextStatus;
  bool failNetwork = false;
  Object? allergyResponse;
  Completer<http.StreamedResponse>? pendingAllergies;
  Completer<http.StreamedResponse>? pendingSave;

  static const scanBody = {
    'success': true,
    'status': 'completed',
    'is_safe': true,
    'extracted_ocr_text': 'Local test text',
    'ingredient_list': 'Local test ingredients',
    'allergens_detected': <Object>[],
    'total_allergens_count': 0,
  };

  static http.StreamedResponse response(Object body, {int status = 200}) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
        headers: {'content-type': 'application/json'},
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw http.ClientException('Client is already closed.');
    final bytes = await request.finalize().toBytes();
    final body = utf8.decode(bytes);
    requests.add(RecordedRequest(request, body));
    if (failNetwork) throw http.ClientException('Local test network failure.');
    final status = nextStatus;
    nextStatus = null;
    if (status != null) {
      return response({'detail': 'Test failure'}, status: status);
    }
    switch (request.url.path) {
      case '/users/me/allergies':
        if (request.method == 'GET' && pendingAllergies != null) {
          return pendingAllergies!.future;
        }
        if (request.method == 'PUT' && pendingSave != null) {
          return pendingSave!.future;
        }
        if (allergyResponse != null) return response(allergyResponse!);
        if (request.method == 'PUT') {
          savedAllergies = (jsonDecode(body)['allergies'] as List)
              .cast<String>();
        }
        return response({'allergies': savedAllergies});
      case '/users/me':
        return response({'name': 'Test User', 'allergies': savedAllergies});
      case '/scan/image':
      case '/scan/text':
        scanStarted?.complete();
        scanStarted = null;
        final reply = pendingScan != null
            ? await pendingScan!.future
            : response(scanBody);
        if (request.url.path == '/scan/image' &&
            request.headers['Accept'] == 'text/event-stream' &&
            reply.statusCode == 200) {
          final body = jsonDecode(
            await reply.stream.bytesToString(),
          ) as Map<String, dynamic>;
          if (body['success'] == true && body['status'] == 'completed') {
            return http.StreamedResponse(
              Stream.value(utf8.encode(labelSuccess(body))),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                labelFrame('error', {
                  'http_status': 422,
                  'code': body['status'],
                  'message': 'Mocked label rejection.',
                }, 1),
              ),
            ),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return reply;
      default:
        throw StateError('Unexpected test endpoint: ${request.url.path}');
    }
  }

  @override
  void close() {
    closed = true;
    closeCount++;
  }
}
