import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'allergy_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiService _apiService = ApiService();

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Returns the current user's Firebase ID token
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    return await _auth.currentUser?.getIdToken(forceRefresh);
  }

  /// Creates a new user with email & password, sets display name,
  /// and initializes their user profile in the database via the FastAPI backend.
  Future<UserCredential> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    try {
      AllergyService().clearSession();
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      final user = credential.user;
      if (user != null) {
        await user.updateDisplayName(name.trim());

        // Initialize user document via FastAPI backend (no direct Firestore calls)
        try {
          await _apiService.updateProfile(
            name: name.trim(),
            email: email.trim(),
          );
        } catch (apiErr) {
          debugPrint(
            'Notice: Backend profile initialization deferred: $apiErr',
          );
        }
      }

      return credential;
    } catch (e) {
      debugPrint('AuthService.signUp error: $e');
      rethrow;
    }
  }

  /// Signs in an existing user with email and password
  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    try {
      AllergyService().clearSession();
      return await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } catch (e) {
      debugPrint('AuthService.signIn error: $e');
      rethrow;
    }
  }

  /// Sends a password reset email via Firebase Authentication
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } catch (e) {
      debugPrint('AuthService.sendPasswordResetEmail error: $e');
      rethrow;
    }
  }

  /// Signs out the current user
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      AllergyService().clearSession();
    } catch (e) {
      debugPrint('AuthService.signOut error: $e');
      rethrow;
    }
  }
}
