import 'dart:async';
import 'dart:typed_data';

import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'city_scope_service.dart';
import 'local_notification_store.dart';

/// Alarm-style notification listener for merchant incoming orders.
class MerchantNotificationService {
  static final MerchantNotificationService _instance = MerchantNotificationService._();
  factory MerchantNotificationService() => _instance;
  MerchantNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _listening = false;
  String _merchantUid = '';
  Set<String> _assignedShopIds = {};

  final Set<String> _seenOrderIds = {};
  final List<StreamSubscription> _subs = [];
  final Map<String, Timer> _alertTimers = {};
  final Map<String, Map<String, dynamic>> _activeOrders = {};

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  static const Duration _alertPulse = Duration(seconds: 3);
  static const Duration _timeoutThreshold = Duration(minutes: 3);

  static Function(Map<String, dynamic> order)? onNewOrderForMerchant;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'merchant_new_order_v2',
    'Merchant New Order Alert',
    description: 'Alarm notification for merchant incoming orders',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('universfield_ringtone_021_365652'),
    enableVibration: true,
    showBadge: true,
  );

  Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestCriticalPermission: true,
    );

    await _plugin.initialize(const InitializationSettings(android: androidInit, iOS: iosInit));

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    await _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

    _initialized = true;
  }

  Future<void> startListening({required String merchantUid, required Set<String> assignedShopIds}) async {
    await initialize();
    await CityScopeService.ensureLoaded();

    _merchantUid = merchantUid;
    _assignedShopIds = assignedShopIds;

    if (_listening) return;
    _listening = true;

    final db = FirebaseDatabase.instance.ref();

    // Seed existing IDs so alert fires only for newly added orders.
    final existing = await db.child(_tenantPath('shop-orders')).get();
    if (existing.exists && existing.value is Map) {
      final data = existing.value as Map<dynamic, dynamic>;
      data.forEach((key, _) => _seenOrderIds.add(key.toString()));
    }

    _subs.add(
      db.child(_tenantPath('shop-orders')).onChildAdded.listen((event) {
        final key = event.snapshot.key ?? '';
        if (key.isEmpty || _seenOrderIds.contains(key)) return;
        _seenOrderIds.add(key);

        if (!event.snapshot.exists || event.snapshot.value is! Map) return;
        final order = Map<String, dynamic>.from(event.snapshot.value as Map);
        order['id'] = key;
        _handleOrder(order);
      }),
    );

    _subs.add(
      db.child(_tenantPath('shop-orders')).onChildChanged.listen((event) {
        final key = event.snapshot.key ?? '';
        if (key.isEmpty) return;
        if (!event.snapshot.exists || event.snapshot.value is! Map) return;
        final order = Map<String, dynamic>.from(event.snapshot.value as Map);
        order['id'] = key;
        _handleOrderUpdate(order);
      }),
    );
  }

  void updateAssignedShops(Set<String> assignedShopIds) {
    _assignedShopIds = assignedShopIds;
  }

  Future<void> stopListening() async {
    _listening = false;
    _merchantUid = '';
    _assignedShopIds = {};
    _seenOrderIds.clear();
    for (final timer in _alertTimers.values) {
      timer.cancel();
    }
    for (final orderId in _alertTimers.keys.toList()) {
      await _plugin.cancel(orderId.hashCode & 0x7FFFFFFF);
    }
    _alertTimers.clear();
    _activeOrders.clear();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  void _handleOrder(Map<String, dynamic> order) {
    final merchantId = (order['merchantId'] ?? '').toString();
    final shopId = (order['shopId'] ?? '').toString();

    final belongsToMerchant =
        merchantId == _merchantUid || (shopId.isNotEmpty && _assignedShopIds.contains(shopId));
    if (!belongsToMerchant) return;

    final status = (order['status'] ?? 'pending').toString().toLowerCase();
    if (status != 'merchant_pending' && status != 'confirmed' && status != 'preparing') return;

    _startOrRefreshAlert(order);

    onNewOrderForMerchant?.call(order);
  }

  void _handleOrderUpdate(Map<String, dynamic> order) {
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return;

    final merchantId = (order['merchantId'] ?? '').toString();
    final shopId = (order['shopId'] ?? '').toString();
    final belongsToMerchant =
        merchantId == _merchantUid || (shopId.isNotEmpty && _assignedShopIds.contains(shopId));

    final status = (order['status'] ?? '').toString().toLowerCase();

    if (!belongsToMerchant) {
      _stopAlertForOrder(orderId);
      return;
    }

    if (_isResolvedStatus(status)) {
      _stopAlertForOrder(orderId);
      return;
    }

    if (status == 'merchant_pending' || status == 'confirmed' || status == 'preparing') {
      _startOrRefreshAlert(order);
      return;
    }
  }

  bool _isResolvedStatus(String status) {
    return status == 'cancelled' ||
        status == 'canceled' ||
        status == 'rejected' ||
        status == 'delivered';
  }

  void _startOrRefreshAlert(Map<String, dynamic> order) {
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return;

    _activeOrders[orderId] = Map<String, dynamic>.from(order);

    final details = _buildNotificationText(order);
    _showAlarmNotification(orderId: orderId, title: details['title']!, body: details['body']!);

    final status = (order['status'] ?? '').toString().toLowerCase();
    if (status == 'preparing') {
      // Preparing is already accepted by admin flow, so no timeout auto-cancel cycle is needed.
      return;
    }

    if (_alertTimers.containsKey(orderId)) return;

    _alertTimers[orderId] = Timer.periodic(_alertPulse, (_) async {
      final active = _activeOrders[orderId];
      if (active == null) {
        await _stopAlertForOrder(orderId);
        return;
      }
      
      // Check 3-minute timeout
      final timeoutBase = int.tryParse((
        active['merchantPendingAt'] ?? active['adminApprovedAt'] ?? active['createdAt'] ?? '0'
      ).toString()) ?? 0;
      if (timeoutBase > 0) {
        final elapsed = DateTime.now().millisecondsSinceEpoch - timeoutBase;
        if (elapsed > _timeoutThreshold.inMilliseconds) {
          // AUTO-CANCEL after 3 minutes
          await _timeoutOrder(orderId, active);
          return;
        }
      }

      final text = _buildNotificationText(active);
      await _showAlarmNotification(orderId: orderId, title: text['title']!, body: text['body']!);
    });
  }

  Future<void> _timeoutOrder(String orderId, Map<String, dynamic> order) async {
    await _stopAlertForOrder(orderId);
    
    // Update status to merchant_review (merchant_cancel_requested)
    final db = FirebaseDatabase.instance.ref();
    await db.child(_tenantPath('shop-orders/$orderId')).update({
      'status': 'merchant_cancel_requested',
      'reason': 'Auto-timeout: Merchant did not accept within 3 minutes',
      'updatedAt': ServerValue.timestamp,
    });
    
    // Notify Admin
    final orderCode = (order['customOrderId'] ?? orderId).toString();
    await db.child(_tenantPath('notifications/admin/inbox')).push().set({
      'title': 'Timeout Alert: $orderCode',
      'body': 'Merchant did not accept order in 3 minutes. Moved to review.',
      'createdAt': ServerValue.timestamp,
      'read': false,
    });
  }

  Map<String, String> _buildNotificationText(Map<String, dynamic> order) {
    final orderCode = (order['customOrderId'] ?? order['id'] ?? '').toString();
    final shopName = (order['shopName'] ?? order['shop'] ?? 'Shop').toString();
    final customer = (order['userName'] ?? order['userEmail'] ?? 'Customer').toString();
    final total = (order['grandTotal'] ?? order['totalAmount'] ?? order['budget'] ?? 0).toString();
    final address = (order['fullAddress'] ?? order['address'] ?? 'No address').toString();

    String itemsText = '';
    final rawItems = order['items'];
    if (rawItems is List && rawItems.isNotEmpty) {
      final parts = <String>[];
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        parts.add('${item['quantity'] ?? 1}x ${item['name'] ?? 'Item'}');
      }
      itemsText = parts.join(', ');
    } else {
      itemsText = (order['items'] ?? '').toString();
    }

    final title = 'New Order ${orderCode.isEmpty ? '' : '#$orderCode'} • $shopName';
    final body = '$customer | Rs. $total | $itemsText | $address';
    return {'title': title, 'body': body};
  }

  Future<void> _stopAlertForOrder(String orderId) async {
    final timer = _alertTimers.remove(orderId);
    timer?.cancel();
    _activeOrders.remove(orderId);
    await _plugin.cancel(orderId.hashCode & 0x7FFFFFFF);
  }

  Future<void> _showAlarmNotification({
    required String orderId,
    required String title,
    required String body,
  }) async {
    await LocalNotificationStore.addNotification(
      title: title,
      body: body,
      data: {
        'type': 'merchant_new_order',
        'orderId': orderId,
      },
      dedupeKey: 'merchant_order_$orderId',
    );

    await _plugin.show(
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
          ongoing: true,
          autoCancel: false,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
          playSound: true,
          sound: const RawResourceAndroidNotificationSound('universfield_ringtone_021_365652'),
          category: AndroidNotificationCategory.alarm,
          icon: '@mipmap/ic_launcher',
          ticker: 'New merchant order received',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.critical,
        ),
      ),
      payload: orderId,
    );
  }
}
