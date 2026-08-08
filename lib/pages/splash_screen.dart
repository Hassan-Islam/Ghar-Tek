import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_dashboard.dart';
import 'login_page.dart';
import 'main_layout.dart';
import 'rider_dashboard.dart';
import 'merchant_dashboard.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/city_scope_service.dart';
import '../services/tenant_data_migration_service.dart';
import 'city_selection_page.dart';
import 'package:flutter_animate/flutter_animate.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  static const String _roleCachePrefix = 'last_role_';
  static const Duration _minSplashDuration = const Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    _init();
  }

  User? _currentUser;
  String _userRole = 'customer';
  bool _hasCitySelection = false;

  Future<void> _init() async {
    final minDelay = Future.delayed(_minSplashDuration);
    final initTasks = _runBackgroundInit();

    await Future.wait([minDelay, initTasks]);

    if (!mounted) return;

    // Force-update gate: agar user ki app version minimum se purani hai to
    // force update dialog dikhega aur navigation ruk jayega (Firebase se aage
    // nahi jaane dega jab tak update na ho).
    final blockedByUpdate = await _checkForUpdates();
    if (blockedByUpdate) return;

    if (mounted) {
      _navigateReady();
    }
  }

  Future<void> _runBackgroundInit() async {
    // Check and request permissions in the background
    await _requestPermissions();

    _currentUser = await _getPersistedUser();
    _hasCitySelection = await CityScopeService.hasSelectedCity();

    if (_currentUser != null) {
      _userRole = _normalizeRole(await _resolveCurrentUserRole(_currentUser!));
      
      try {
        if (_userRole == 'admin') {
          await AuthService()
              .syncAdminCityScopeForCurrentUser(
                uid: _currentUser!.uid,
                assignFromCurrentIfMissing: _hasCitySelection,
              )
              .timeout(const Duration(seconds: 4));
        } else if (_userRole == 'rider' || _userRole == 'merchant') {
          // Operational roles must use profile city before loading orders/shops.
          await CityScopeService.syncCityFromUserProfile(
            _currentUser!.uid,
            role: _userRole,
          ).timeout(const Duration(seconds: 4));
        } else {
          try {
            unawaited(
              AuthService()
                  .syncUserCityScopeForCurrentUser(
                    uid: _currentUser!.uid,
                    role: _userRole,
                    assignFromCurrentIfMissing: _hasCitySelection,
                  )
                  .timeout(const Duration(seconds: 2)),
            );
          } catch (_) {}
        }
      } catch (_) {}
    }

    if (_hasCitySelection) {
      await CityScopeService.ensureLoaded();
      unawaited(_initNotifications());
      unawaited(_runPostLaunchTasks());
    }
  }

  Future<bool> _checkForUpdates() async {
    // Update / force-update feature has been removed. The app never prompts to
    // update from the Play Store and never blocks navigation.
    return false;
  }

  Future<void> _requestPermissions() async {
    try {
      await Permission.notification.request();
      final locPerm = await Permission.locationWhenInUse.request();
      if (locPerm.isGranted) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) await Geolocator.openLocationSettings();
      }
    } catch (_) {}
  }

  Future<void> _initNotifications() async {
    try {
      if (!kIsWeb) {
        unawaited(Permission.notification.request());
      }
      await NotificationService().initialize();
      unawaited(NotificationService.syncRtdbInboxToLocalStore());
    } catch (_) {}
  }

  Future<User?> _getPersistedUser() async {
    final auth = FirebaseAuth.instance;

    final immediateUser = auth.currentUser;
    if (immediateUser != null) return immediateUser;

    try {
      final restoredUser = await auth
          .authStateChanges()
          .firstWhere((user) => user != null)
          .timeout(const Duration(milliseconds: 1500));
      if (restoredUser != null) return restoredUser;
    } catch (_) {}

    for (var attempt = 0; attempt < 2; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final user = auth.currentUser;
      if (user != null) return user;
    }

    return auth.currentUser;
  }

  String _normalizeRole(dynamic raw) {
    final value = (raw ?? '').toString().trim().toLowerCase();
    if (value == 'admin' || value == 'rider' || value == 'merchant') {
      return value;
    }
    return 'customer';
  }

  Future<String?> _readCachedRole(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString('$_roleCachePrefix$uid');
      if (role == null || role.trim().isEmpty) return null;
      return _normalizeRole(role);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheRole(String uid, String role) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_roleCachePrefix$uid', _normalizeRole(role));
    } catch (_) {}
  }

  Future<String> _resolveCurrentUserRole(User user) async {
    final uid = user.uid;
    final cachedRole = await _readCachedRole(uid);

    // If we have a cached role, return it immediately to make splash screen fast!
    // But fire off a background task to keep it updated for the next launch
    if (cachedRole != null) {
      unawaited(_fetchAndCacheRoleFromServer(uid));
      return cachedRole;
    }

    return await _fetchAndCacheRoleFromServer(uid);
  }

  Future<String> _fetchAndCacheRoleFromServer(String uid) async {
    try {
      final roleSnap = await FirebaseDatabase.instance
          .ref('users/$uid/role')
          .get()
          .timeout(const Duration(seconds: 3));
      if (roleSnap.exists) {
        final role = _normalizeRole(roleSnap.value);
        await _cacheRole(uid, role);
        return role;
      }
    } catch (_) {}

    try {
      final userSnap = await FirebaseDatabase.instance
          .ref('users/$uid')
          .get()
          .timeout(const Duration(seconds: 2));
      if (userSnap.exists && userSnap.value is Map) {
        final row = Map<String, dynamic>.from(userSnap.value as Map);
        final roleFromProfile = _normalizeRole(row['role']);
        if (roleFromProfile != 'customer') {
          await _cacheRole(uid, roleFromProfile);
          return roleFromProfile;
        }

        final hasAdminCity = (row['adminCity'] ?? '').toString().trim().isNotEmpty;
        if (hasAdminCity) {
          try {
            await FirebaseDatabase.instance.ref('users/$uid/role').set('admin');
          } catch (_) {}
          await _cacheRole(uid, 'admin');
          return 'admin';
        }
      }
    } catch (_) {}

    return 'customer';
  }

  void _navigateReady() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));

    if (!_hasCitySelection) {
      _go(const CitySelectionPage());
      return;
    }

    if (_currentUser == null) {
      _go(const LoginPage());
      return;
    }

    try {
      if (_userRole == 'admin') {
        _go(const AdminDashboard());
      } else if (_userRole == 'rider') {
        _go(const RiderDashboard());
      } else if (_userRole == 'merchant') {
        _go(const MerchantDashboard());
      } else {
        _go(const MainLayout());
      }
    } catch (_) {
      _go(const MainLayout());
    }
  }

  Future<void> _runPostLaunchTasks() async {
    try {
      await TenantDataMigrationService.migrateLegacyDataForCity(
        city: CityScopeService.currentCity,
      );
    } catch (_) {}
  }

  void _go(Widget page) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 150),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/splash_bg_new.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              // Logo
              Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.98),
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.55),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 32,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Image.asset(
                      'assets/images/Ghartek (2).png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ).animate()
                .scale(duration: 800.ms, curve: Curves.elasticOut, begin: const Offset(0.4, 0.4))
                .fade(duration: 400.ms),
              const SizedBox(height: 28),
              // App name
              Column(
                children: [
                  const Text(
                    'GharTek',
                    style: TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Delivery at your doorstep',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ).animate(delay: 200.ms)
                .slideY(begin: 0.5, end: 0, duration: 600.ms, curve: Curves.easeOutQuart)
                .fade(duration: 600.ms),
              const Spacer(flex: 4),
              // Loading indicator
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              ).animate(delay: 600.ms).fade(duration: 400.ms),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

