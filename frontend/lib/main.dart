import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'theme/app_colors.dart';
import 'screens/welcome_screen.dart';
import 'screens/allergy_selection_screen.dart';
import 'services/allergy_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase.initializeApp warning: $e');
  }
  runApp(const MisbarApp());
}

class MisbarApp extends StatelessWidget {
  const MisbarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Misbar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryGreen),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

/// Listens to the Firebase Auth state:
/// - If signed in: checks saved allergies before opening home or onboarding
/// - If signed out: presents the WelcomeScreen with Login & Create Account options
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Stream<User?>? _authChanges;
  String? _lastUid;
  bool _observedSession = false;

  @override
  Widget build(BuildContext context) {
    try {
      return StreamBuilder<User?>(
        stream: _authChanges ??= FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: AppColors.background,
              body: Center(
                child: CircularProgressIndicator(color: AppColors.primaryGreen),
              ),
            );
          }

          final uid = snapshot.data?.uid;
          // Login/Create Account owns navigation while its route covers this
          // signed-out gate. Do not start a competing read or invalidate the
          // new route's allergy session during that transition.
          if (_observedSession &&
              _lastUid == null &&
              uid != null &&
              ModalRoute.of(context)?.isCurrent == false) {
            return const WelcomeScreen();
          }
          if (_observedSession && uid != _lastUid) {
            // Remove routes belonging to the previous identity as well as its
            // cached preferences before the new account enters the app.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            });
          }
          if (!_observedSession || uid != _lastUid) {
            AllergyService().clearSession();
            _lastUid = uid;
            _observedSession = true;
          }
          if (uid != null) {
            return AllergySelectionScreen(
              key: ValueKey(uid),
              skipSavedSelection: true,
            );
          }

          return const WelcomeScreen();
        },
      );
    } catch (_) {
      // Graceful fallback if Firebase is not yet initialized with google-services.json
      return const WelcomeScreen();
    }
  }
}
