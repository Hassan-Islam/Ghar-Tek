import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'city_scope_service.dart';
import 'local_notification_store.dart';
import 'rider_orders_loader.dart';

/// Foodpanda/Uber-style notification service for riders.
/// Fires a max-priority heads-up notification with order details, sound,
/// and Accept/View action buttons — works even when app is fully killed.
class RiderNotificationService {
  static final RiderNotificationService _instance = RiderNotificationService._();
  factory RiderNotificationService() => _instance;
  RiderNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _listening = false;

  /// Set this callback before calling [startListening].
  /// Will be called on the UI thread when a new order is detected while the
  /// app is running (foreground / background-resumed).
  static Function(Map<String, dynamic> order)? onNewOrderForRider;

  // Track order IDs that existed when we started listening so we only alert
  // for genuinely new ones.
  final Set<String> _seenIds = {};
  final Map<String, String> _lastStatus = {};

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'rider_new_order',
    'New Order Alert',
    description: 'Alarm-style alert for incoming orders',
    importance: Importance.max,
    playSound: true,
    enableLights: true,
    enableVibration: true,
    showBadge: true,
    sound: RawResourceAndroidNotificationSound('order_bell'),
  );

  // ── Initialize ────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    _initialized = true;
  }

  // ── Start listening for new orders ────────────────────────────────────────

  Future<void> startListening() async {
    if (_listening) return;
    _listening = true;

    await initialize();
    final riderId = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (riderId.isNotEmpty) {
      await RiderOrdersLoader.ensureRiderCityScope(riderId);
    } else {
      await CityScopeService.ensureLoaded();
    }

    final db = FirebaseDatabase.instance.ref();

    // Seed only current available orders — avoids downloading full order trees.
    final availableIds =
        await RiderOrdersLoader.fetchAvailableOrderIds(riderId: riderId);
    _seenIds.addAll(availableIds);

    // Now listen – only fire for IDs that weren't present above
    db.child(_tenantPath('shop-orders')).onChildAdded.listen((event) {
      final key = event.snapshot.key ?? '';
      if (_seenIds.contains(key)) return;
      _seenIds.add(key);
      if (!event.snapshot.exists) return;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      data['id'] = key;
      data['orderType'] = 'shop';
      _handleOrderEvent(data);
    });

    db.child(_tenantPath('shop-orders')).onChildChanged.listen((event) {
      final key = event.snapshot.key ?? '';
      if (key.isEmpty || !event.snapshot.exists) return;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      data['id'] = key;
      data['orderType'] = 'shop';
      _handleOrderEvent(data, fromChange: true);
    });
  }

  void stopListening() {
    _listening = false;
    _seenIds.clear();
    _lastStatus.clear();
  }

  // ── Handle a new order ────────────────────────────────────────────────────

  String _normalizeRiderStatus(dynamic rawStatus) {
    final status = (rawStatus ?? 'pending').toString().toLowerCase().trim();
    if (status == 'on_way' || status == 'out_for_delivery') {
      return 'on_the_way';
    }
    if (status == 'confirmed' || status == 'preparing') {
      return 'available';
    }
    return status;
  }

  bool _isRiderRelevant(String status) {
    return status == 'available';
  }

  void _handleOrderEvent(Map<String, dynamic> order, {bool fromChange = false}) {
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return;

    final status = _normalizeRiderStatus(order['status']);
    final previous = _lastStatus[orderId];
    _lastStatus[orderId] = status;

    if (!_isRiderRelevant(status)) return;
    if (fromChange && previous == status) return;

    final shopName = order['shopName'] ?? order['shop'] ?? 'New Order';
    final customer = order['userName'] ?? order['userEmail'] ?? 'Customer';
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final code = (order['customOrderId'] ?? orderId).toString();
    final address = (order['fullAddress'] ?? order['address'] ?? 'No address').toString();
    final items = order['items'];

    String itemsText = '';
    if (items is List && items.isNotEmpty) {
      final parts = <String>[];
      for (final raw in items) {
        if (raw is! Map) continue;
        parts.add('${raw['quantity'] ?? 1}x ${raw['name'] ?? 'Item'}');
      }
      itemsText = parts.join(', ');
    } else {
      itemsText = (order['items'] ?? '').toString();
    }

    _showAlarmNotification(
      title: '🛵 New Order #$code',
      body: '📍 $shopName\n👤 $customer\n🛒 $itemsText\n💰 Rs. $total\n📮 $address',
      orderId: (order['id'] ?? '').toString(),
      orderType: (order['orderType'] ?? '').toString(),
    );

    // In-app callback (only fires when Dart isolate is alive)
    onNewOrderForRider?.call(order);
  }

  // ── System notification (Foodpanda/Uber style) ────────────────────────────

  static Future<void> showIncomingOrderCall({
    required String title,
    required String body,
    required String orderId,
    required String orderType,
  }) async {
    final plugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true,
    );
    await plugin.initialize(const InitializationSettings(android: androidInit, iOS: iosInit));

    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    await LocalNotificationStore.addNotification(
      title: title,
      body: body,
      data: {
        'type': 'rider_new_order',
        'orderId': orderId,
      },
      dedupeKey: 'rider_order_$orderId',
    );

    await plugin.show(
      orderId.hashCode & 0x7FFFFFFF,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          enableVibration: true,
          playSound: true,
          sound: const RawResourceAndroidNotificationSound('order_bell'),
          additionalFlags: Int32List.fromList(<int>[4]), // FLAG_INSISTENT
          timeoutAfter: 30000, // 30 seconds
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFF06B6D4),
          ticker: 'New order received',
          category: AndroidNotificationCategory.call,
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: title,
            htmlFormatContent: false,
            htmlFormatContentTitle: false,
          ),
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction(
              'accept_order',
              '✅ Accept Order',
              showsUserInterface: true,
            ),
            const AndroidNotificationAction(
              'view_order',
              '👁️ View Details',
              showsUserInterface: true,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.critical,
        ),
      ),
      payload: '{"type": "rider_new_order", "orderId": "$orderId", "orderType": "$orderType"}',
    );
  }

  Future<void> _showAlarmNotification({
    required String title,
    required String body,
    required String orderId,
    required String orderType,
  }) async {
    await showIncomingOrderCall(
      title: title,
      body: body,
      orderId: orderId,
      orderType: orderType,
    );
  }
}
