import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'loyalty_service.dart';

class BackgroundTimerService {
  static final BackgroundTimerService _instance = BackgroundTimerService._internal();
  factory BackgroundTimerService() => _instance;
  BackgroundTimerService._internal();

  Timer? _backgroundTimer;
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final LoyaltyService _loyaltyService = LoyaltyService();

  // Start background timer service
  void startBackgroundTracking() {
    _backgroundTimer?.cancel();
    
    // Check every 30 seconds for active timers
    _backgroundTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _checkActiveTimers();
    });
  }

  // Stop background timer service
  void stopBackgroundTracking() {
    _backgroundTimer?.cancel();
  }

  // Check all active timers and update their status
  Future<void> _checkActiveTimers() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      Set<String> keys = prefs.getKeys();
      
      // Find all timer start keys
      List<String> timerKeys = keys.where((key) => key.startsWith('timer_start_')).toList();
      
      for (String timerKey in timerKeys) {
        String orderId = timerKey.replaceFirst('timer_start_', '');
        await _updateTimerForOrder(orderId, prefs);
      }
    } catch (e) {
      print('Error checking active timers: $e');
    }
  }

  // Update timer for specific order
  Future<void> _updateTimerForOrder(String orderId, SharedPreferences prefs) async {
    try {
      int? startTime = prefs.getInt('timer_start_$orderId');
      int? estimatedTime = prefs.getInt('estimated_time_$orderId');
      String? currentStatus = prefs.getString('order_status_$orderId');
      
      if (startTime != null && estimatedTime != null) {
        DateTime timerStart = DateTime.fromMillisecondsSinceEpoch(startTime);
        DateTime now = DateTime.now();
        
        int totalSeconds = estimatedTime * 60;
        int elapsedSeconds = now.difference(timerStart).inSeconds;
        
        if (elapsedSeconds >= totalSeconds) {
          // Timer finished, mark as delivered
          await _markOrderAsDelivered(orderId, prefs);
        } else {
          // Update progress in database
          double progress = (elapsedSeconds / totalSeconds).clamp(0.0, 1.0);
          int remainingTime = totalSeconds - elapsedSeconds;
          
          String newStatus = _calculateStatus(progress);
          
          // Update database
          await _updateOrderInDatabase(orderId, progress, remainingTime, newStatus);
          
          // Update local status if changed
          if (newStatus != currentStatus) {
            await prefs.setString('order_status_$orderId', newStatus);
          }
        }
      }
    } catch (e) {
      print('Error updating timer for order $orderId: $e');
    }
  }

  // Calculate status based on progress
  String _calculateStatus(double progress) {
    if (progress >= 1.0) {
      return 'delivered';
    } else if (progress >= 0.75) {
      return 'on_way';
    } else if (progress >= 0.25) {
      return 'preparing';
    } else {
      return 'confirmed';
    }
  }

  // Update order in database
  Future<void> _updateOrderInDatabase(String orderId, double progress, int remainingTime, String status) async {
    try {
      // Try both custom-orders and shop-orders paths
      await _database.child('custom-orders/$orderId').update({
        'progress': progress,
        'remainingTime': remainingTime,
        'status': status,
        'lastUpdated': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      try {
        await _database.child('shop-orders/$orderId').update({
          'progress': progress,
          'remainingTime': remainingTime,
          'status': status,
          'lastUpdated': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (e2) {
        print('Error updating order in database: $e2');
      }
    }
  }

  // Mark order as delivered and clean up
  Future<void> _markOrderAsDelivered(String orderId, SharedPreferences prefs) async {
    try {
      // Update database
      await _updateOrderInDatabase(orderId, 1.0, 0, 'delivered');

      // Award loyalty points once per delivered order
      await _awardLoyaltyPoints(orderId);
      
      // Clear timer state from local storage
      await prefs.remove('timer_start_$orderId');
      await prefs.remove('estimated_time_$orderId');
      await prefs.remove('order_status_$orderId');
      
      // Show notification if app is active
      _showDeliveryNotification(orderId);
      
    } catch (e) {
      print('Error marking order as delivered: $e');
    }
  }

  Future<void> _awardLoyaltyPoints(String orderId) async {
    final paths = ['shop-orders', 'custom-orders'];
    for (final path in paths) {
      try {
        final orderRef = _database.child('$path/$orderId');
        final snap = await orderRef.get();
        if (!snap.exists || snap.value is! Map) continue;

        final data = Map<String, dynamic>.from(snap.value as Map);
        if (data['loyaltyPointsAwarded'] == true) return;

        final userId = (data['userId'] ?? '').toString();
        if (userId.isEmpty) return;

        await orderRef.update({
          'loyaltyPointsAwarded': true,
          'loyaltyPointsAwardedPoints': LoyaltyService.pointsPerOrderDelivered,
          'loyaltyPointsAwardedAt': DateTime.now().millisecondsSinceEpoch,
        });
        await _loyaltyService.addPoints(
          userId,
          LoyaltyService.pointsPerOrderDelivered,
        );
        return;
      } catch (_) {}
    }
  }

  // Show delivery notification
  void _showDeliveryNotification(String orderId) {
    try {
      Fluttertoast.showToast(
        msg: "Order #${orderId.substring(0, 8)} has been delivered!",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Color(0xFF4CAF50),
        textColor: Colors.white,
      );
    } catch (e) {
      print('Error showing notification: $e');
    }
  }

  // Get active timers count
  Future<int> getActiveTimersCount() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      Set<String> keys = prefs.getKeys();
      return keys.where((key) => key.startsWith('timer_start_')).length;
    } catch (e) {
      return 0;
    }
  }

  // Check if specific order has active timer
  Future<bool> hasActiveTimer(String orderId) async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.containsKey('timer_start_$orderId');
    } catch (e) {
      return false;
    }
  }
}
