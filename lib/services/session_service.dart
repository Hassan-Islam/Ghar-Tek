import 'dart:async';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluttertoast/fluttertoast.dart';

class SessionService {
  static const String _deviceIdKey = 'ghartek_device_session_id';
  static final SessionService _instance = SessionService._internal();
  factory SessionService() => _instance;
  SessionService._internal();

  StreamSubscription<DatabaseEvent>? _sessionSubscription;
  String? _localDeviceId;
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Start listening to auth state changes
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user != null) {
        await _startSessionTracking(user.uid);
      } else {
        await _stopSessionTracking();
      }
    });
  }

  Future<String> _getOrCreateDeviceId() async {
    if (_localDeviceId != null) return _localDeviceId!;
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null) {
      deviceId = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(100000)}';
      await prefs.setString(_deviceIdKey, deviceId);
    }
    _localDeviceId = deviceId;
    return deviceId;
  }

  Future<void> updateSessionId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final deviceId = await _getOrCreateDeviceId();
      await FirebaseDatabase.instance.ref('users/${user.uid}/sessionId').set(deviceId);
    }
  }

  Future<void> _startSessionTracking(String uid) async {
    await _stopSessionTracking(); // clear existing if any
    final deviceId = await _getOrCreateDeviceId();
    
    // Listen to real-time database
    _sessionSubscription = FirebaseDatabase.instance
        .ref('users/$uid/sessionId')
        .onValue
        .listen((event) async {
      final dbSessionId = event.snapshot.value?.toString();
      
      if (dbSessionId != null && dbSessionId != deviceId) {
        // Wait briefly to avoid race condition when current device is logging in
        await Future.delayed(const Duration(milliseconds: 2000));
        
        // Check again if it still mismatches
        final checkSnap = await FirebaseDatabase.instance.ref('users/$uid/sessionId').get();
        final currentDbSessionId = checkSnap.value?.toString();
        
        if (currentDbSessionId != null && currentDbSessionId != deviceId) {
          await _stopSessionTracking();
          try {
            await FirebaseAuth.instance.signOut();
            Fluttertoast.showToast(
              msg: "Session expired: Logged in from another device.",
              toastLength: Toast.LENGTH_LONG,
            );
          } catch (_) {}
        }
      }
    });
  }

  Future<void> _stopSessionTracking() async {
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
  }
}
