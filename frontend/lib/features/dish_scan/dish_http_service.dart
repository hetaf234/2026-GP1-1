import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../../services/api_service.dart';
import 'dish_result.dart';
import 'dish_scan_service.dart';

class DishIdentity {
  final String uid;
  final String token;
  const DishIdentity(this.uid, this.token);
}

class HttpDishScanService implements DishScanService {
  final String? baseUrl;
  final http.Client Function()? clientFactory;
  final Future<DishIdentity> Function()? identityProvider;
  final String? Function()? currentUid;
  final Duration timeout;
  const HttpDishScanService({
    this.baseUrl,
    this.clientFactory,
    this.identityProvider,
    this.currentUid,
    this.timeout = const Duration(
      seconds: int.fromEnvironment(
        'MISBAR_DISH_TIMEOUT_SECONDS',
        defaultValue: 180,
      ),
    ),
  });

  Future<DishIdentity> _identity() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const DishScanException(DishScanFailure.connection);
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw const DishScanException(DishScanFailure.connection);
    }
    return DishIdentity(user.uid, token);
  }

  @override
  Future<DishResult> analyze(
    Uint8List image, {
    required void Function(DishProgressUpdate) onStage,
    DishScanCancellation? cancellation,
  }) async {
    if (timeout <= Duration.zero ||
        image.isEmpty ||
        image.length > 4 * 1024 * 1024) {
      throw const DishScanException(DishScanFailure.connection);
    }
    final cancel = cancellation ?? DishScanCancellation();
    if (cancel.isCancelled) throw const DishScanCancelled();
    // Each attempt owns its client. Never close Label Scan's shared connection.
    final client = (clientFactory ?? http.Client.new)();
    var active = true;
    int? responseStatus;
    bool cancelled() => !active || cancel.isCancelled;
    void checkIdentity(DishIdentity identity) {
      final uid = currentUid != null
          ? currentUid!()
          : identityProvider == null
          ? FirebaseAuth.instance.currentUser?.uid
          : identity.uid;
      if (uid != identity.uid) {
        throw const DishScanException(DishScanFailure.connection);
      }
    }

    Future<DishResult> run() async {
      final identity = await (identityProvider ?? _identity)();
      if (cancelled()) throw const DishScanCancelled();
      if (identity.uid.isEmpty || identity.token.isEmpty) {
        throw const FormatException('Missing identity');
      }
      checkIdentity(identity);
      final address = (baseUrl ?? ApiService().baseUrl).replaceFirst(
        RegExp(r'/+$'),
        '',
      );
      final uri = Uri.parse('$address/scan/dish');
      if (!const ['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid Dish address');
      }
      final request = http.MultipartRequest('POST', uri)
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer ${identity.token}'
        ..headers['Accept'] = 'text/event-stream'
        ..files.add(
          http.MultipartFile.fromBytes('file', image, filename: 'dish.image'),
        );
      // Exactly one send: no retries, redirects, host fallback, or SSE reconnect.
      final response = await client.send(request);
      if (cancelled()) throw const DishScanCancelled();
      responseStatus = response.statusCode;
      if (response.statusCode != 200 ||
          response.headers['content-type']
                  ?.split(';')
                  .first
                  .trim()
                  .toLowerCase() !=
              'text/event-stream') {
        final details = utf8.decode(
          await response.stream.toBytes(),
          allowMalformed: true,
        );
        throw DishScanException(
          DishScanFailure.connection,
          statusCode: response.statusCode,
          transportStatusCode: response.statusCode,
          diagnosticDetails: details,
        );
      }
      String? scanId;
      var sequence = 0;
      final stages = <DishScanStage, DishStageStatus>{};
      await for (final event in decodeDishEvents(response.stream)) {
        if (cancelled()) throw const DishScanCancelled();
        checkIdentity(identity);
        final id = dishText(event.data['scan_id']);
        final next = event.data['sequence'];
        if (next is! int || next < 1 || (scanId != null && scanId != id)) {
          throw const FormatException('Invalid event identity');
        }
        scanId = id;
        if (next <= sequence) continue;
        sequence = next;
        if (event.type == 'progress') {
          final stage = switch (event.data['stage']) {
            'image_received' => DishScanStage.imageReceived,
            'identifying_ingredients' => DishScanStage.identifyingDish,
            'checking_allergens' => DishScanStage.checkingAllergies,
            _ => throw const FormatException('Unknown progress stage'),
          };
          final status = switch (event.data['status']) {
            'running' => DishStageStatus.running,
            'completed' => DishStageStatus.completed,
            'error' => DishStageStatus.error,
            'rejected' => DishStageStatus.rejected,
            _ => throw const FormatException('Unknown progress status'),
          };
          if (stages[stage] == DishStageStatus.completed &&
              status != DishStageStatus.completed) {
            throw const FormatException('Progress regressed');
          }
          if (stage.index > 0 &&
              stages[DishScanStage.values[stage.index - 1]] !=
                  DishStageStatus.completed) {
            throw const FormatException('Progress out of order');
          }
          stages[stage] = status;
          onStage(DishProgressUpdate(stage, status));
        } else {
          final result = dishObject(event.data['result']);
          final outcomeStatus = event.data['http_status'];
          if (outcomeStatus != 200 || result['decision'] == 'error') {
            throw DishScanException(
              DishScanFailure.connection,
              statusCode: outcomeStatus is int
                  ? outcomeStatus
                  : response.statusCode,
              transportStatusCode: response.statusCode,
              diagnosticDetails: event.data,
            );
          }
          if (result['decision'] == 'rejected') {
            throw DishScanException(switch (result['stopped_at']) {
              'quality' => DishScanFailure.lowQuality,
              'food_gate' => DishScanFailure.notSingleDish,
              'ood' => DishScanFailure.unsupportedDish,
              _ => DishScanFailure.connection,
            });
          }
          if (!DishScanStage.values.every(
            (s) => stages[s] == DishStageStatus.completed,
          )) {
            throw const FormatException('Unconfirmed completion');
          }
          return DishResult.fromJson(result);
        }
      }
      throw const FormatException('Missing terminal outcome');
    }

    try {
      return await Future.any<DishResult>([
        run(),
        cancel.whenCancelled.then<DishResult>(
          (_) => throw const DishScanCancelled(),
        ),
      ]).timeout(timeout);
    } on DishScanCancelled {
      rethrow;
    } on DishScanException {
      rethrow;
    } catch (error, stack) {
      // Retain diagnostics internally, never log them or display them in the UI.
      throw DishScanException(
        DishScanFailure.connection,
        statusCode: responseStatus,
        transportStatusCode: responseStatus,
        diagnosticDetails: error,
        diagnosticStackTrace: stack,
      );
    } finally {
      active = false;
      client.close();
    }
  }
}
