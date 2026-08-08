import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'dart:async';

class OrderTrackingService {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  Timer? _globalTimer;
  
  static final OrderTrackingService _instance = OrderTrackingService._internal();
  factory OrderTrackingService() => _instance;
  OrderTrackingService._internal();

  // Start automatic order tracking system
  void startGlobalOrderTracking() {
    _globalTimer?.cancel();
    _globalTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _checkAndUpdateOrders();
    });
  }

  // Stop global tracking
  void stopGlobalOrderTracking() {
    _globalTimer?.cancel();
  }

  // Check all orders and update their status automatically
  Future<void> _checkAndUpdateOrders() async {
    try {
      DatabaseReference ordersRef = _database.child('orders');
      DataSnapshot snapshot = await ordersRef.get();

      if (snapshot.exists) {
        Map<dynamic, dynamic> orders = snapshot.value as Map<dynamic, dynamic>;
        
        for (var entry in orders.entries) {
          String orderId = entry.key;
          Map<dynamic, dynamic> orderData = entry.value;
          
          if (orderData['status'] == 'confirmed') {
            await _updateOrderProgress(orderId, orderData);
          }
        }
      }
    } catch (e) {
      print('Error checking orders: $e');
    }
  }

  // Update individual order progress
  Future<void> _updateOrderProgress(String orderId, Map<dynamic, dynamic> orderData) async {
    try {
      DateTime orderTime = DateTime.fromMillisecondsSinceEpoch(orderData['timestamp']);
      int estimatedMinutes = orderData['estimatedTime'] ?? 40;
      DateTime expectedDeliveryTime = orderTime.add(Duration(minutes: estimatedMinutes));
      DateTime now = DateTime.now();

      // Calculate progress percentage
      int totalDuration = estimatedMinutes * 60; // in seconds
      int elapsed = now.difference(orderTime).inSeconds;
      double progress = (elapsed / totalDuration).clamp(0.0, 1.0);

      // Update progress in database
      await _database.child('orders/$orderId').update({
        'progress': progress,
        'remainingTime': (totalDuration - elapsed).clamp(0, totalDuration),
        'lastUpdated': DateTime.now().millisecondsSinceEpoch,
      });

      // Check if order should be marked as delivered
      if (now.isAfter(expectedDeliveryTime) && orderData['status'] == 'confirmed') {
        await _markOrderAsDelivered(orderId);
      }
    } catch (e) {
      print('Error updating order $orderId: $e');
    }
  }

  // Automatically mark order as delivered
  Future<void> _markOrderAsDelivered(String orderId) async {
    try {
      await _database.child('orders/$orderId').update({
        'status': 'delivered',
        'deliveredAt': DateTime.now().millisecondsSinceEpoch,
        'progress': 1.0,
        'remainingTime': 0,
      });

      Fluttertoast.showToast(
        msg: "Order #${orderId.substring(0, 8)} has been delivered!",
        toastLength: Toast.LENGTH_LONG,
      );
    } catch (e) {
      print('Error marking order as delivered: $e');
    }
  }

  // Get real-time order tracking data
  Stream<Map<String, dynamic>?> getOrderTrackingStream(String orderId) {
    return _database.child('orders/$orderId').onValue.map((event) {
      if (event.snapshot.exists) {
        return Map<String, dynamic>.from(event.snapshot.value as Map);
      }
      return null;
    });
  }

  // Calculate order stages based on progress
  Map<String, dynamic> getOrderStages(double progress, String status) {
    List<Map<String, dynamic>> stages = [
      {
        'title': 'Order Confirmed',
        'subtitle': 'Your order has been received',
        'icon': 'check_circle',
        'completed': true,
      },
      {
        'title': 'Preparing',
        'subtitle': 'Your order is being prepared',
        'icon': 'restaurant',
        'completed': progress >= 0.25,
      },
      {
        'title': 'On the Way',
        'subtitle': 'Rider is coming to you',
        'icon': 'delivery_dining',
        'completed': progress >= 0.75,
      },
      {
        'title': 'Delivered',
        'subtitle': 'Order has been delivered',
        'icon': 'done_all',
        'completed': status == 'delivered',
      },
    ];

    int currentStageIndex = 0;
    for (int i = 0; i < stages.length; i++) {
      if (!stages[i]['completed']) {
        currentStageIndex = i;
        break;
      }
      if (i == stages.length - 1) {
        currentStageIndex = i;
      }
    }

    return {
      'stages': stages,
      'currentStage': currentStageIndex,
      'progress': progress,
    };
  }

  // Update order status
  Future<void> updateOrderStatus(String orderId, String status) async {
    try {
      await _database.child('orders/$orderId').update({
        'status': status,
        'lastUpdated': DateTime.now().millisecondsSinceEpoch,
        if (status == 'delivered') ...{
          'deliveredAt': DateTime.now().millisecondsSinceEpoch,
          'progress': 1.0,
          'remainingTime': 0,
        },
      });
    } catch (e) {
      print('Error updating order status: $e');
    }
  }

  // Format remaining time in a user-friendly way
  String formatRemainingTime(int remainingSeconds) {
    if (remainingSeconds <= 0) return "Order Ready!";
    
    int minutes = remainingSeconds ~/ 60;
    int seconds = remainingSeconds % 60;
    
    if (minutes > 0) {
      return "${minutes}m ${seconds}s remaining";
    } else {
      return "${seconds}s remaining";
    }
  }

  // Get estimated delivery time
  String getEstimatedDeliveryTime(DateTime orderTime, int estimatedMinutes) {
    DateTime deliveryTime = orderTime.add(Duration(minutes: estimatedMinutes));
    String hour = deliveryTime.hour.toString().padLeft(2, '0');
    String minute = deliveryTime.minute.toString().padLeft(2, '0');
    return "$hour:$minute";
  }
}
