import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/scan_result.dart';
import 'api_service.dart';

class AllergyService {
  static final AllergyService _instance = AllergyService._internal();
  factory AllergyService([ApiService? apiService]) {
    if (apiService != null) {
      _instance._apiService = apiService;
    }
    return _instance;
  }

  ApiService _apiService;

  AllergyService._internal({ApiService? apiService})
    : _apiService = apiService ?? ApiService();

  List<String>? _currentAllergies;
  List<String>? _lastCommittedAllergies;
  int _version = 0;
  int _sessionGeneration = 0;
  bool _isSaving = false;
  Object? _lastSaveError;

  Future<void>? _activePipeline;
  List<String>? _queuedPayload;
  Completer<void>? _queuedCompleter;

  /// Authoritative list of user allergens from the current session.
  List<String>? get currentAllergies => _currentAllergies != null
      ? List<String>.unmodifiable(_currentAllergies!)
      : null;

  /// Last successfully persisted allergy list confirmed by backend.
  List<String>? get lastCommittedAllergies => _lastCommittedAllergies != null
      ? List<String>.unmodifiable(_lastCommittedAllergies!)
      : null;

  /// Monotonically increasing preference version counter.
  int get version => _version;

  /// Whether an allergy persistence request is actively in-flight or queued.
  bool get isSaving => _isSaving;

  /// Drop only session memory; never delete or change saved Firestore data.
  void clearSession() {
    _sessionGeneration++;
    _currentAllergies = null;
    _lastCommittedAllergies = null;
    _lastSaveError = null;
    _queuedPayload = null;
    final queued = _queuedCompleter;
    _queuedCompleter = null;
    _activePipeline = null;
    _isSaving = false;
    _version++;
    if (queued != null && !queued.isCompleted) {
      queued.completeError(StateError('The authenticated session changed.'));
    }
  }

  /// Fetches the authenticated user's saved allergies via FastAPI backend.
  /// (userId parameter is kept for signature compatibility, backend derives UID from verified token)
  Future<List<String>?> fetchUserAllergies([String? userId]) async {
    final session = _sessionGeneration;
    // A failed/new account read must never expose another session's selections.
    _currentAllergies = null;
    _lastCommittedAllergies = null;
    _version++;
    try {
      final list = await _apiService.getUserAllergies();
      if (session != _sessionGeneration) {
        throw StateError('The authenticated session changed.');
      }
      if (list.toSet().length != list.length ||
          list.any(
            (value) =>
                !AllergenDetection.categories.any((item) => item.name == value),
          )) {
        throw const FormatException('Saved allergy selections are invalid.');
      }
      _currentAllergies = List<String>.from(list);
      _lastCommittedAllergies = List<String>.from(list);
      _lastSaveError = null;
      _version++;
      return _currentAllergies;
    } catch (e) {
      debugPrint('[AllergyService] fetchUserAllergies error via FastAPI: $e');
      rethrow;
    }
  }

  /// Sets local in-memory allergies directly (e.g. for testing or initialization).
  void setLocalAllergies(List<String> allergies) {
    if (allergies.toSet().length != allergies.length ||
        allergies.any(
          (value) =>
              !AllergenDetection.categories.any((item) => item.name == value),
        )) {
      throw const FormatException('Invalid local allergy selections.');
    }
    _currentAllergies = List<String>.from(allergies);
    _lastCommittedAllergies = List<String>.from(allergies);
    _lastSaveError = null;
    _version++;
  }

  /// Saves or updates the user's selected allergies in the database via FastAPI backend.
  /// Serializes concurrent calls to eliminate race conditions, ensuring only ordered
  /// requests reach the backend and that final committed state matches user intent.
  Future<void> saveUserAllergies(
    dynamic userIdOrAllergies, [
    List<String>? maybeAllergies,
  ]) async {
    final List<String> targetAllergies;
    if (userIdOrAllergies is List<String>) {
      targetAllergies = List<String>.from(userIdOrAllergies);
    } else if (maybeAllergies != null) {
      targetAllergies = List<String>.from(maybeAllergies);
    } else {
      throw const FormatException('Invalid allergy selections.');
    }

    if (targetAllergies.isEmpty ||
        targetAllergies.toSet().length != targetAllergies.length ||
        targetAllergies.any(
          (value) =>
              !AllergenDetection.categories.any((item) => item.name == value),
        )) {
      throw const FormatException('Select at least one valid allergen.');
    }

    // Immediately update in-memory authoritative state and increment version
    _currentAllergies = List<String>.from(targetAllergies);
    _version++;

    return _enqueueSave(targetAllergies);
  }

  Future<void> _enqueueSave(List<String> allergiesToSave) {
    _isSaving = true;

    // If an HTTP save is already in-flight, update the queued target payload
    if (_activePipeline != null) {
      _queuedPayload = List<String>.from(allergiesToSave);
      _queuedCompleter ??= Completer<void>();
      return _queuedCompleter!.future;
    }

    final completer = Completer<void>();
    _activePipeline = _executeSave(allergiesToSave, _sessionGeneration)
        .then((_) {
          completer.complete();
        })
        .catchError((e, stack) {
          completer.completeError(e, stack);
        });

    return completer.future;
  }

  Future<void> _executeSave(List<String> allergiesToSave, int session) async {
    try {
      final saved = await _apiService.saveUserAllergies(allergiesToSave);
      if (session != _sessionGeneration) {
        throw StateError('The authenticated session changed.');
      }
      if (saved.isEmpty ||
          saved.length != allergiesToSave.length ||
          saved.toSet().length != saved.length ||
          saved.any((value) => !allergiesToSave.contains(value))) {
        throw const FormatException(
          'Saved allergy selections were not confirmed.',
        );
      }
      _lastCommittedAllergies = List<String>.from(saved);
      _lastSaveError = null;
      debugPrint(
        '[AllergyService] Successfully persisted ${saved.length} allergies via backend.',
      );
    } catch (e) {
      if (session == _sessionGeneration) _lastSaveError = e;
      debugPrint('[AllergyService] saveUserAllergies error via FastAPI: $e');
      // If save failed and no newer queued payload is pending, revert current state
      if (session == _sessionGeneration && _queuedPayload == null) {
        _currentAllergies = _lastCommittedAllergies == null
            ? null
            : List<String>.from(_lastCommittedAllergies!);
        _version++;
      }
      rethrow;
    } finally {
      if (session == _sessionGeneration) {
        _activePipeline = null;
        if (_queuedPayload != null) {
          final nextPayload = _queuedPayload!;
          final nextCompleter = _queuedCompleter;
          _queuedPayload = null;
          _queuedCompleter = null;

          _activePipeline = _executeSave(nextPayload, session)
              .then((_) {
                nextCompleter?.complete();
              })
              .catchError((e, stack) {
                nextCompleter?.completeError(e, stack);
              });
        } else {
          _isSaving = false;
        }
      }
    }
  }

  /// Blocks until all in-flight and queued save requests have completed.
  /// Throws if the final save failed.
  Future<void> ensureSaved() async {
    while (_activePipeline != null || _queuedCompleter != null) {
      if (_queuedCompleter != null) {
        await _queuedCompleter!.future;
      } else if (_activePipeline != null) {
        await _activePipeline;
      }
    }
    if (_lastSaveError != null) throw _lastSaveError!;
    if (_lastCommittedAllergies == null || _lastCommittedAllergies!.isEmpty) {
      throw const FormatException(
        'Select and save at least one allergen to continue.',
      );
    }
  }
}
