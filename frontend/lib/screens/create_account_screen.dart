import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../services/auth_service.dart';
import 'allergy_selection_screen.dart';

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  List<({String label, bool met})> _passwordRequirements(String password) => [
    (label: '8 or more characters', met: password.characters.length >= 8),
    (
      label: 'At least one uppercase letter',
      met: password.contains(RegExp(r'[A-Z]')),
    ),
    (
      label: 'At least one lowercase letter',
      met: password.contains(RegExp(r'[a-z]')),
    ),
    (label: 'At least one number', met: password.contains(RegExp(r'[0-9]'))),
    (
      label: 'At least one special character',
      met: password.contains(RegExp(r'[^\p{L}\p{N}\s]', unicode: true)),
    ),
  ];

  bool _validatePassword(String password) =>
      _passwordRequirements(password).every((requirement) => requirement.met);

  Future<void> _handleSignUp() async {
    if (!_formKey.currentState!.validate()) return;

    final password = _passwordController.text;
    if (!_validatePassword(password)) {
      setState(() {
        _errorMessage = 'Please ensure password meets all requirements (8+ characters, uppercase, lowercase, number, special character).';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _authService.signUp(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: password,
      );

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AllergySelectionScreen()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        switch (e.code) {
          case 'email-already-in-use':
            _errorMessage = 'An account already exists for this email address.';
            break;
          case 'invalid-email':
            _errorMessage = 'Please enter a valid email address.';
            break;
          case 'weak-password':
            _errorMessage = 'The password is too weak.';
            break;
          default:
            _errorMessage =
                e.message ?? 'Registration failed. Please try again.';
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'An unexpected error occurred: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header with back button & Misbar logo
            AppHeader(
              onBack: () => Navigator.of(context).pop(),
              showBack: true,
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24.0,
                  vertical: 8.0,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),

                      // Title & Subtitle
                      const Text(
                        'Create Account',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Join Misbar to eat safely',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.textMuted,
                        ),
                      ),

                      const SizedBox(height: 28),

                      // Error message if any
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.alertBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.alertRed.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: AppColors.alertRed,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.alertRed,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Name Field
                      const Text(
                        'Name',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        decoration: _inputDecoration('Noof Mohammed'),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter your name';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 20),

                      // Email Address Field
                      const Text(
                        'Email Address',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: _inputDecoration('noof@example.com'),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter your email';
                          }
                          if (!value.contains('@') || !value.contains('.')) {
                            return 'Please enter a valid email';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 20),

                      // Password Field
                      const Text(
                        'Password',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passwordController,
                        // Keep the live checklist in view when the keyboard opens.
                        scrollPadding: const EdgeInsets.fromLTRB(
                          20,
                          20,
                          20,
                          300,
                        ),
                        onChanged: (_) => setState(() => _errorMessage = null),
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _handleSignUp(),
                        decoration: _inputDecoration('••••••••••••').copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: AppColors.textMuted,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(
                                () => _obscurePassword = !_obscurePassword,
                              );
                            },
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter a password';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 20),

                      // Password Requirements Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.sageBg,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Password Requirements',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppColors.darkGreen,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ..._passwordRequirements(
                              _passwordController.text,
                            ).map(
                              (requirement) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      requirement.met
                                          ? Icons.check_circle_rounded
                                          : Icons.radio_button_unchecked,
                                      color: requirement.met
                                          ? AppColors.primaryGreen
                                          : AppColors.textMuted,
                                      size: 18,
                                      semanticLabel: requirement.met
                                          ? 'Met'
                                          : 'Not met',
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        requirement.label,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.4,
                                          color: requirement.met
                                              ? AppColors.primaryGreen
                                              : AppColors.textMuted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Continue Button
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: FilledButton(
                          onPressed: _isLoading ? null : _handleSignUp,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primaryGreen,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Continue',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF9EABA2), fontSize: 14),
      filled: true,
      fillColor: AppColors.chipUnselectedBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primaryGreen, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.alertRed, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.alertRed, width: 1.5),
      ),
    );
  }
}
