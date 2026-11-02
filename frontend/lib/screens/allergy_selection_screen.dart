import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../widgets/app_header.dart';
import '../services/allergen_scanner_service.dart';
import '../services/allergy_service.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../models/scan_result.dart';
import 'scanning_screen.dart';
import 'image_capture_screen.dart';
import 'welcome_screen.dart';
import '../features/dish_scan/dish_home_screen.dart';
import '../features/dish_scan/dish_widgets.dart';

class AllergySelectionScreen extends StatefulWidget {
  final bool manageAllergies;
  final bool skipSavedSelection;
  const AllergySelectionScreen({
    super.key,
    this.manageAllergies = false,
    this.skipSavedSelection = false,
  });

  @override
  State<AllergySelectionScreen> createState() => _AllergySelectionScreenState();
}

class _AllergySelectionScreenState extends State<AllergySelectionScreen> {
  static const MethodChannel _channel = MethodChannel(
    'com.example.misbar/image_capture',
  );
  late final AllergenScannerService _scannerService;
  final AllergyService _allergyService = AllergyService();
  final AuthService _authService = AuthService();

  final _allergens = AllergenDetection.categories;
  final Set<String> _selectedAllergens = {};
  final Set<String> _savedAllergens = {};
  bool _allowManagementPop = false;
  bool _isShowingLeaveDialog = false;
  bool _isShowingSaveConfirmation = false;

  bool get _hasUnsavedChanges =>
      _selectedAllergens.length != _savedAllergens.length ||
      !_selectedAllergens.containsAll(_savedAllergens);

  bool _isLoadingAllergies = true;
  bool _hasLoadedAllergies = false;
  String? _allergyLoadError;
  String? _selectionError;
  bool _isSavingAllergies = false;
  bool _isNavigatingToScanner = false;
  bool _isOpeningScanHome = false;
  bool _isSigningOut = false;
  int _allergyLoadRequest = 0;
  late bool _resolvingEntry;
  bool _bypassedSelection = false;

  @override
  void initState() {
    super.initState();
    _resolvingEntry = widget.skipSavedSelection && !widget.manageAllergies;
    _scannerService = AllergenScannerService();
    _loadUserAllergiesFromFirestore();
  }

  Future<void> _loadUserAllergiesFromFirestore() async {
    final request = ++_allergyLoadRequest;
    setState(() {
      _isLoadingAllergies = true;
      _hasLoadedAllergies = false;
      _allergyLoadError = null;
      _selectionError = null;
      _selectedAllergens.clear();
      _savedAllergens.clear();
    });
    try {
      final user = _authService.currentUser;
      if (user == null) throw StateError('Authentication required.');
      // Management keeps its draft separate from shared, confirmed selections.
      final saved = widget.manageAllergies
          ? await ApiService().getUserAllergies()
          : await _allergyService.fetchUserAllergies(user.uid);
      if (saved == null) {
        throw const FormatException('Missing allergy selections.');
      }
      if (!mounted || request != _allergyLoadRequest) return;
      if (_authService.currentUser?.uid != user.uid) {
        throw StateError('The authenticated user changed.');
      }
      if (widget.manageAllergies && saved.isEmpty) {
        setState(() {
          _allergyLoadError = 'Your account has no saved allergy selection. Complete your allergy selection before continuing.';
        });
        return;
      }
      if (widget.manageAllergies) _allergyService.setLocalAllergies(saved);
      setState(() {
        _savedAllergens.addAll(saved);
        _selectedAllergens.addAll(saved);
        _hasLoadedAllergies = true;
        _isLoadingAllergies = false;
        if (_resolvingEntry && saved.isEmpty) _resolvingEntry = false;
      });
      if (_resolvingEntry && saved.isNotEmpty) {
        _bypassedSelection = true;
        await _openScanHome();
      }
    } catch (error) {
      if (!mounted || request != _allergyLoadRequest) return;
      setState(() {
        _allergyLoadError = widget.manageAllergies
            ? 'Unable to load your saved allergies. Please try again.'
            : error is FormatException
            ? 'Your saved allergy selections are invalid. They must use the 14 supported categories. Please retry after they are updated.'
            : 'Could not load your saved allergies. Please retry before continuing.';
      });
    } finally {
      if (mounted && request == _allergyLoadRequest) {
        setState(() => _isLoadingAllergies = false);
      }
    }
  }

  Future<void> _toggleAllergen(String name) async {
    if (!_hasLoadedAllergies ||
        _allergyLoadError != null ||
        _isLoadingAllergies ||
        (widget.manageAllergies && _isSavingAllergies)) {
      return;
    }
    if (_authService.currentUser == null) return;
    if (_selectedAllergens.length == 1 && _selectedAllergens.contains(name)) {
      const message =
          'Select at least one allergen. Add another before removing your last selection.';
      setState(() => _selectionError = message);
      return;
    }
    // Invalidate/cancel any active or in-flight scan
    _scannerService.cancelCurrentScan();

    final willRemove = _selectedAllergens.contains(name);
    setState(() {
      if (willRemove) {
        _selectedAllergens.remove(name);
      } else {
        _selectedAllergens.add(name);
      }
      _isSavingAllergies = !widget.manageAllergies;
      _selectionError = null;
    });

    if (widget.manageAllergies) return;

    final user = _authService.currentUser;
    if (user != null) {
      try {
        await _allergyService.saveUserAllergies(
          user.uid,
          _selectedAllergens.toList(),
        );
      } catch (e) {
        debugPrint(
          '[AllergySelectionScreen] Failed to persist allergy update: $e',
        );
        if (mounted) {
          setState(() {
            _selectedAllergens.clear();
            _selectedAllergens.addAll(_allergyService.currentAllergies ?? []);
            _selectionError ??= 'Failed to save allergy change ($e). Reverted.';
          });
        }
      } finally {
        if (mounted) {
          setState(() => _isSavingAllergies = _allergyService.isSaving);
        }
      }
    } else {
      if (mounted) {
        setState(() => _isSavingAllergies = false);
      }
    }
  }

  void _closeManagement() {
    setState(() => _allowManagementPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _handleManagementBack() async {
    if (_isSavingAllergies ||
        _isShowingSaveConfirmation ||
        _isShowingLeaveDialog) {
      return;
    }
    if (!_hasUnsavedChanges) {
      Navigator.of(context).maybePop();
      return;
    }
    _isShowingLeaveDialog = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Discard unsaved changes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep Editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard Changes'),
          ),
        ],
      ),
    );
    _isShowingLeaveDialog = false;
    if (mounted && discard == true) _closeManagement();
  }

  Future<void> _saveManagementChanges() async {
    if (_isSavingAllergies ||
        !_hasLoadedAllergies ||
        _allergyLoadError != null) {
      return;
    }
    if (_selectedAllergens.isEmpty) {
      setState(
        () => _selectionError = 'Select at least one allergen to continue.',
      );
      return;
    }
    final user = _authService.currentUser;
    if (user == null) {
      setState(
        () => _selectionError =
            'Unable to save your allergies. Please try again.',
      );
      return;
    }
    final draft = List<String>.from(_selectedAllergens);
    setState(() {
      _isSavingAllergies = true;
      _selectionError = null;
    });
    try {
      // The existing API validates the persistence acknowledgement. Do not put
      // this draft into shared saved state before that acknowledgement arrives.
      final saved = await ApiService().saveUserAllergies(draft);
      if (!mounted) return;
      if (_authService.currentUser?.uid != user.uid) {
        throw StateError('The authenticated user changed.');
      }
      _allergyService.setLocalAllergies(saved);
      setState(() {
        _savedAllergens.clear();
        _savedAllergens.addAll(saved);
        _isShowingSaveConfirmation = true;
      });
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            content: const Text(
              'Your allergies have been updated successfully.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      );
      if (mounted) {
        setState(() => _isShowingSaveConfirmation = false);
        _closeManagement();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _selectionError =
              'Unable to save your allergies. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingAllergies = false);
    }
  }

  Future<void> _handleSignOut() async {
    if (_isSigningOut) return;
    _isSigningOut = true;
    final navigator = Navigator.of(context);
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Log Out',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text('Are you sure you want to log out of Misbar?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.alertRed,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    try {
      if (shouldSignOut == true) {
        await _authService.signOut();
        if (!navigator.mounted) return;
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (route) => false,
        );
      }
    } catch (_) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: const Text('Unable to log out. Please try again.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      _isSigningOut = false;
    }
  }

  Future<void> _proceedToScanner() async {
    if (_isLoadingAllergies) return;
    if (!_hasLoadedAllergies ||
        _allergyLoadError != null ||
        _selectedAllergens.isEmpty) {
      final message =
          _allergyLoadError ??
          (!_hasLoadedAllergies
              ? 'Load your saved allergies before continuing.'
              : 'Select at least one allergen to continue.');
      setState(() => _selectionError = message);
      return;
    }

    // Prevent concurrent/duplicate navigation attempts while saving or navigating
    if (_isNavigatingToScanner) return;
    _isNavigatingToScanner = true;
    final headerAppearance = AppHeader.nativeAppearance(context);

    // Ensure any in-flight or queued database save finishes and is confirmed by backend
    if (_isSavingAllergies || _allergyService.isSaving) {
      setState(() => _isSavingAllergies = true);
    }
    try {
      await _allergyService.ensureSaved();
    } catch (e) {
      _isNavigatingToScanner = false;
      if (mounted) {
        setState(() {
          _selectionError =
              'Cannot proceed to scanner: Failed to save allergies ($e). Please retry.';
        });
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _isSavingAllergies = _allergyService.isSaving);
      }
    }

    final latestAllergens = _allergyService.lastCommittedAllergies!;

    try {
      final String? tempPath = await _channel.invokeMethod<String>(
        'openImageCapture',
        {'header': headerAppearance},
      );

      if (tempPath != null && tempPath.isNotEmpty) {
        final file = File(tempPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          try {
            await file.delete();
          } catch (_) {}

          if (!mounted) {
            _isNavigatingToScanner = false;
            return;
          }

          Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) => ScanningScreen(
                    imageBytes: bytes,
                    userId: _authService.currentUser?.uid,
                    userAllergens: latestAllergens,
                    scannerService: _scannerService,
                  ),
                ),
              )
              .then((_) {
                _isNavigatingToScanner = false;
              });
          return;
        }
      }
    } catch (_) {}

    if (!mounted) {
      _isNavigatingToScanner = false;
      return;
    }

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ImageCaptureScreen(
              userId: _authService.currentUser?.uid,
              userAllergens: latestAllergens,
              scannerService: _scannerService,
            ),
          ),
        )
        .then((_) {
          _isNavigatingToScanner = false;
        });
  }

  Future<void> _openScanHome() async {
    if (_isLoadingAllergies) return;
    if (!_hasLoadedAllergies ||
        _allergyLoadError != null ||
        _selectedAllergens.isEmpty) {
      final message =
          _allergyLoadError ??
          (!_hasLoadedAllergies
              ? 'Load your saved allergies before continuing.'
              : 'Select at least one allergen to continue.');
      setState(() => _selectionError = message);
      return;
    }

    if (_isOpeningScanHome || _isLoadingAllergies) return;
    setState(() => _isOpeningScanHome = true);
    try {
      await _allergyService.ensureSaved();
      if (!mounted) return;
      var profile = List<String>.unmodifiable(
        _allergyService.lastCommittedAllergies!,
      );
      var managingAllergies = false;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: scanHomeRoute),
          builder: (homeContext) => PopScope(
            canPop: !_bypassedSelection,
            child: StatefulBuilder(
              builder: (homeContext, updateHome) => DishHomeScreen(
                displayName: _authService.currentUser?.displayName ?? 'Friend',
                userAllergens: profile,
                onScanLabel: _proceedToScanner,
                onManageAllergies: () async {
                  if (managingAllergies) return;
                  managingAllergies = true;
                  try {
                    await Navigator.of(homeContext).push<void>(
                      MaterialPageRoute<void>(
                        settings: const RouteSettings(name: '/my-allergies'),
                        builder: (_) =>
                            const AllergySelectionScreen(manageAllergies: true),
                      ),
                    );
                    if (!mounted || !homeContext.mounted) return;
                    final saved = _allergyService.lastCommittedAllergies;
                    if (saved == null || saved.isEmpty) return;
                    setState(() {
                      _selectedAllergens.clear();
                      _selectedAllergens.addAll(saved);
                    });
                    updateHome(
                      () => profile = List<String>.unmodifiable(saved),
                    );
                  } finally {
                    managingAllergies = false;
                  }
                },
                onLogout: _handleSignOut,
              ),
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _selectionError =
              'Could not confirm your saved allergies. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _isOpeningScanHome = false);
    }
  }

  @override
  void dispose() {
    _scannerService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _authService.currentUser;
    final displayName = user?.displayName ?? 'Friend';

    final header = AppHeader(
      showBack: widget.manageAllergies,
      onBack: widget.manageAllergies ? _handleManagementBack : null,
      onLogout: !widget.manageAllergies && user != null ? _handleSignOut : null,
      logoutKey: const ValueKey('onboarding-logout'),
    );

    // Resolve the authoritative read before showing onboarding. A read failure
    // remains a retryable error, never an empty selection or a profile write.
    if (_resolvingEntry) {
      final error = _allergyLoadError ?? _selectionError;
      return Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Column(
            children: [
              header,
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: error == null
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                color: AppColors.primaryGreen,
                              ),
                              SizedBox(height: 16),
                              Text('Loading your saved allergies...'),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(error, textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              TextButton(
                                onPressed: _loadUserAllergiesFromFirestore,
                                child: const Text('Retry'),
                              ),
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

    final screen = Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            header,

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hello, $displayName 👋',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primaryGreen,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.manageAllergies
                          ? 'My Allergies'
                          : 'Select Your Allergies',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.manageAllergies
                          ? 'Choose at least one allergen, then save your changes.'
                          : "We'll warn you when these allergens are detected. Changes sync automatically to your account.",
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textMuted,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Same error presentation as Log In and Create Account.
                    if (_allergyLoadError != null ||
                        _selectionError != null) ...[
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
                                (_allergyLoadError ?? _selectionError)!,
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

                    // Allergy Chips Grid
                    if (_isLoadingAllergies)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: CircularProgressIndicator(
                            color: AppColors.primaryGreen,
                          ),
                        ),
                      )
                    else if (_allergyLoadError != null)
                      TextButton(
                        onPressed: _loadUserAllergiesFromFirestore,
                        child: const Text('Retry'),
                      )
                    else
                      Wrap(
                        spacing: 10,
                        runSpacing: 12,
                        children: _allergens.map((item) {
                          final isSelected = _selectedAllergens.contains(
                            item.name,
                          );
                          return GestureDetector(
                            onTap: () => _toggleAllergen(item.name),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primaryGreen
                                    : AppColors.chipUnselectedBg,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    item.emoji,
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      AllergenDetection.displayName(item.name),
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: isSelected
                                            ? Colors.white
                                            : AppColors.chipUnselectedText,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                  ],
                ),
              ),
            ),

            // Continue Button
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: widget.manageAllergies
                      ? (_isLoadingAllergies ||
                                !_hasLoadedAllergies ||
                                _allergyLoadError != null ||
                                _isSavingAllergies ||
                                _selectedAllergens.isEmpty
                            ? null
                            : _saveManagementChanges)
                      : (_isOpeningScanHome || _isLoadingAllergies
                            ? null
                            : _openScanHome),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    widget.manageAllergies
                        ? (_isSavingAllergies ? 'Saving...' : 'Save Changes')
                        : 'Continue',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!widget.manageAllergies) return screen;
    return PopScope(
      canPop:
          _allowManagementPop ||
          (!_hasUnsavedChanges &&
              !_isSavingAllergies &&
              !_isShowingSaveConfirmation),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleManagementBack();
      },
      child: screen,
    );
  }
}
