import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/scan_result.dart';
import 'api_endpoint.dart';
import 'label_scan_http_client.dart';
import 'label_scan_progress.dart';
export 'label_scan_progress.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final Uri? uri;

  ApiException(this.statusCode, this.message, {this.uri});

  @override
  String toString() => 'ApiException ($statusCode): $message';
}

/// Application-owned connection shared by account, allergy and label services.
/// Screen-scoped services borrow it and must never dispose it.
class ApiService {
  static const authTokenTimeout = Duration(seconds: 10);
  static const allergyReadTimeout = Duration(seconds: 20);
  static const configuredBaseUrl = String.fromEnvironment(
    'MISBAR_API_BASE_URL',
  );
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;

  String baseUrl;
  final http.Client _client;

  static const List<String> candidateBaseUrls = [
    'http://0.0.0.0:8000 ',
    'http://127.0.0.1:8000', // Physical Android device over ADB reverse or desktop
    'http://192.168.68.100:8000', // Mac LAN IP
    'http://10.0.2.2:8000', // Android emulator loopback
  ];

  ApiService._internal({String? baseUrl, http.Client? client})
    : baseUrl =
          baseUrl ??
          deploymentApiBaseUrl(configuredBaseUrl, 'http://192.168.0.152:8000'),
      _client = client ?? http.Client();

  /// Retrieves the current Firebase ID token, optionally forcing a refresh.
  Future<String> _getAuthToken({bool forceRefresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const SocketException('User is not authenticated. Please log in.');
    }
    final uid = user.uid;
    final token = await user.getIdToken(forceRefresh).timeout(authTokenTimeout);
    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      throw StateError('The authenticated session changed.');
    }
    if (token == null || token.isEmpty) {
      throw const SocketException('Could not retrieve authentication token.');
    }
    return token;
  }

  /// Returns candidate host endpoints to attempt in order
  List<String> _getEndpoints() {
    // A deployed app uses its configured service only; a failed cloud request
    // must not fall through to unrelated laptop/emulator addresses.
    if (configuredBaseUrl.trim().isNotEmpty) return <String>[baseUrl];
    return <String>[
      baseUrl,
      ...candidateBaseUrls.where((url) => url != baseUrl),
    ];
  }

  // ==========================================================================
  // User Profile Endpoints
  // ==========================================================================

  /// GET /users/me
  /// Fetches authenticated user profile and saved allergies from FastAPI.
  Future<Map<String, dynamic>> getProfile() async {
    return _sendWithRetry((host, token) async {
      final uri = Uri.parse('$host/users/me');
      final response = await _client
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        baseUrl = host;
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        throw ApiException(response.statusCode, response.body, uri: uri);
      }
    });
  }

  /// POST /users/profile
  /// Initializes or updates the user profile record on the server.
  Future<Map<String, dynamic>> updateProfile({
    String? name,
    String? email,
  }) async {
    return _sendWithRetry((host, token) async {
      final uri = Uri.parse('$host/users/profile');
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              if (name != null) 'name': name,
              if (email != null) 'email': email,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        baseUrl = host;
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        throw ApiException(response.statusCode, response.body, uri: uri);
      }
    });
  }

  // ==========================================================================
  // User Allergies Database Endpoints
  // ==========================================================================

  /// GET /users/me/allergies
  /// Fetches user's saved allergies from the database via FastAPI.
  Future<List<String>> getUserAllergies() async {
    return _sendWithRetry((host, token) async {
      final uri = Uri.parse('$host/users/me/allergies');
      final response = await _client
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        baseUrl = host;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rawList = data['allergies'];
        if (rawList is! List ||
            rawList.any(
              (value) =>
                  value is! String ||
                  !AllergenDetection.categories.any(
                    (item) => item.name == value,
                  ),
            ) ||
            rawList.toSet().length != rawList.length) {
          throw const FormatException('Saved allergy selections are invalid.');
        }
        if (data.containsKey('allergy_selection_saved') &&
            (data['allergy_selection_saved'] is! bool ||
                data['allergy_selection_saved'] != rawList.isNotEmpty)) {
          throw const FormatException(
            'Saved allergy selection state is invalid.',
          );
        }
        return List<String>.from(rawList);
      } else {
        throw ApiException(response.statusCode, response.body, uri: uri);
      }
    }).timeout(allergyReadTimeout);
  }

  /// PUT /users/me/allergies
  /// Updates user's saved allergies in the database via FastAPI.
  Future<List<String>> saveUserAllergies(List<String> allergies) async {
    if (allergies.isEmpty ||
        allergies.toSet().length != allergies.length ||
        allergies.any(
          (value) =>
              !AllergenDetection.categories.any((item) => item.name == value),
        )) {
      throw const FormatException('Select at least one valid allergen.');
    }
    return _sendWithRetry((host, token) async {
      final uri = Uri.parse('$host/users/me/allergies');
      final response = await _client
          .put(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'allergies': allergies}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        baseUrl = host;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rawList = data['allergies'];
        if (rawList is! List ||
            rawList.isEmpty ||
            rawList.any(
              (value) => value is! String || !allergies.contains(value),
            ) ||
            rawList.toSet().length != rawList.length ||
            rawList.length != allergies.length) {
          throw const FormatException(
            'Saved allergy selections were not confirmed.',
          );
        }
        return List<String>.from(rawList);
      } else {
        throw ApiException(response.statusCode, response.body, uri: uri);
      }
    });
  }

  // ==========================================================================
  // Scanner Endpoints
  // ==========================================================================

  /// POST /scan/image
  /// Uploads product label photo with Bearer token for server-side processing.
  /// Note: Never supplies user_allergens; the server reads user allergies directly from Firestore.
  Future<ScanResult> scanImageBytes(Uint8List imageBytes) async {
    return _sendWithRetry((host, token) async {
      final uri = Uri.parse('$host/scan/image');
      final request = http.MultipartRequest('POST', uri);

      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: 'label.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );

      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        baseUrl = host;
        return await compute(parseScanResult, response.body);
      } else {
        throw ApiException(response.statusCode, response.body, uri: uri);
      }
    });
  }

  /// One authenticated SSE request. Never retries a paid image submission or
  /// falls back to another host/JSON. Cancellation aborts only this request.
  Future<ScanResult> scanImageWithProgress(
    Uint8List imageBytes, {
    required void Function(LabelProgressUpdate) onProgress,
    LabelScanCancellation? cancellation,
  }) => LabelScanHttpClient(
    client: _client,
    baseUrl: baseUrl,
    tokenProvider: _getAuthToken,
    currentUid: () => FirebaseAuth.instance.currentUser?.uid,
  ).analyze(imageBytes, onProgress: onProgress, cancellation: cancellation);

  /// POST /scan/text
  /// Analyzes text with Bearer token for server-side processing.
  /// Note: Never supplies user_allergens; the server reads user allergies directly from Firestore.
  Future<ScanResult> scanText(String text) async {
    return _sendWithRetry((host, token) async {
      final uri = Uri.parse('$host/scan/text');
      final body = <String, dynamic>{'text': text};
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        baseUrl = host;
        return await compute(parseScanResult, response.body);
      } else {
        throw ApiException(response.statusCode, response.body, uri: uri);
      }
    });
  }

  // ==========================================================================
  // Helper for Endpoint Failover and Token Refresh
  // ==========================================================================

  Future<T> _sendWithRetry<T>(
    Future<T> Function(String host, String token) executeRequest,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    void checkSession() {
      if (uid == null || FirebaseAuth.instance.currentUser?.uid != uid) {
        throw StateError('The authenticated session changed.');
      }
    }

    String token = await _getAuthToken();
    checkSession();
    Object? lastError;

    for (final host in _getEndpoints()) {
      try {
        checkSession();
        final result = await executeRequest(host, token);
        checkSession();
        return result;
      } on ApiException catch (e) {
        if (e.statusCode == 401) {
          checkSession();
          debugPrint(
            '[ApiService] Received 401 Unauthorized from $host. Refreshing token...',
          );
          try {
            token = await _getAuthToken(forceRefresh: true);
            checkSession();
            final result = await executeRequest(host, token);
            checkSession();
            return result;
          } catch (refreshErr) {
            debugPrint('[ApiService] Token refresh failed: $refreshErr');
            rethrow;
          }
        }
        // Don't retry other hosts for non-network errors
        rethrow;
      } on FormatException {
        // Invalid data is not a connection failure; never try a different server.
        rethrow;
      } on StateError {
        rethrow;
      } catch (e) {
        checkSession();
        lastError = e;
        debugPrint('[ApiService] Failed request to $host: $e');
      }
    }

    throw lastError ??
        const SocketException('Could not connect to FastAPI backend.');
  }

  /// Closes the application connection. Only the application owner may call this
  /// at final shutdown; the singleton cannot be reused after it is closed.
  void dispose() => _client.close();
}
