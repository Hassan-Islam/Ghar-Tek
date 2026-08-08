import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/location_service.dart';
import '../services/city_scope_service.dart';
import '../services/instant_delivery_service.dart';
import '../services/loyalty_service.dart';
import '../services/notification_service.dart';
import 'admin_chats_page.dart';

class AdminOrdersPage extends StatefulWidget {
  const AdminOrdersPage({super.key});

  @override
  State<AdminOrdersPage> createState() => _AdminOrdersPageState();
}

class _AdminOrdersPageState extends State<AdminOrdersPage>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFFFF6B00);
  static const int _openOrderFreshnessWindowMs = 7 * 24 * 60 * 60 * 1000;
  static const int _maxFutureTimestampSkewMs = 2 * 60 * 60 * 1000;

  final _database = FirebaseDatabase.instance.ref();
  final LoyaltyService _loyaltyService = LoyaltyService();
  late TabController _tabController;
  StreamSubscription<DatabaseEvent>? _chatsSubscription;
  StreamSubscription<DatabaseEvent>? _shopOrdersSub;
  Timer? _loadOrdersDebounce;
  bool _initialLoadDone = false;

  List<Map<String, dynamic>> _allOrders = [];
  // Delivered / cancelled history loads lazily (only when its tab is opened) so
  // the page opens instantly without downloading months of terminal orders.
  List<Map<String, dynamic>> _deliveredList = [];
  List<Map<String, dynamic>> _cancelledList = [];
  bool _deliveredLoaded = false;
  bool _deliveredLoading = false;
  bool _cancelledLoaded = false;
  bool _cancelledLoading = false;
  bool _isLoading = true;
  String _searchActive = '';
  String _searchDelivered = '';
  String _searchCancelled = '';
  DateTimeRange? _deliveredDateRange;

  static const List<String> _activeRawStatuses = <String>[
    'pending',
    'pending_admin',
    'admin_pending',
    'available',
    'confirmed',
    'preparing',
    'picked',
    'on_the_way',
    'on_way',
    'out_for_delivery',
    'merchant_pending',
    'merchant_cancel_requested',
  ];
  final Map<String, String> _riderNameCache = {};
  int _activeChatThreadsCount = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    final now = DateTime.now();
    _deliveredDateRange = DateTimeRange(
      start: DateTime(now.year, now.month, now.day),
      end: DateTime(now.year, now.month, now.day),
    );
    _initTenantScope();
  }

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  Future<void> _initTenantScope() async {
    await CityScopeService.ensureLoaded();
    if (!mounted) return;
    _loadOrders();
    _setupRealTimeListeners();
  }

  @override
  void dispose() {
    _loadOrdersDebounce?.cancel();
    _shopOrdersSub?.cancel();
    _chatsSubscription?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _setupRealTimeListeners() {
    _shopOrdersSub?.cancel();
    _shopOrdersSub = _database
        .child(_tenantPath('shop-orders'))
        .onValue
        .listen((_) => _scheduleLoadOrders());
    _chatsSubscription?.cancel();
    _chatsSubscription = _database.child(_tenantPath('chats')).onValue.listen((event) {
      final count = _countActiveChatThreads(event.snapshot.value);
      if (!mounted) return;
      setState(() => _activeChatThreadsCount = count);
    });
  }

  void _scheduleLoadOrders() {
    _loadOrdersDebounce?.cancel();
    _loadOrdersDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadOrders(showLoader: !_initialLoadDone);
    });
  }

  int _countActiveChatThreads(dynamic raw) {
    if (raw is! Map) return 0;

    final data = Map<dynamic, dynamic>.from(raw);
    var count = 0;

    void inspectThread(Map<dynamic, dynamic> row) {
      final meta = row['meta'] is Map ? Map<dynamic, dynamic>.from(row['meta'] as Map) : row;
      if (meta['unreadByAdmin'] == true) count += 1;
    }

    data.forEach((userKey, userValue) {
      if (userValue is! Map) return;
      final userMap = Map<dynamic, dynamic>.from(userValue as Map);

      if (userMap.containsKey('messages') || userMap.containsKey('meta') || userMap.containsKey('lastMessage')) {
        inspectThread(userMap);
        return;
      }

      userMap.forEach((orderKey, orderValue) {
        if (orderValue is! Map) return;
        inspectThread(Map<dynamic, dynamic>.from(orderValue as Map));
      });
    });

    return count;
  }

  void _mergeSnapshot(
    Map<String, Map<String, dynamic>> byId,
    DataSnapshot snap,
  ) {
    if (!snap.exists || snap.value is! Map) return;
    (snap.value as Map).forEach((key, val) {
      if (val is! Map) return;
      final o = Map<String, dynamic>.from(val);
      o['id'] = key;
      o['orderType'] = 'shop';
      byId[key.toString()] = o;
    });
  }

  void _sortByCreatedDesc(List<Map<String, dynamic>> orders) {
    orders.sort((a, b) {
      final at = a['createdAt'];
      final bt = b['createdAt'];
      if (at is int && bt is int) return bt.compareTo(at);
      return 0;
    });
  }

  Future<void> _loadOrders({bool showLoader = true}) async {
    if (showLoader && mounted) setState(() => _isLoading = true);
    try {
      // Only active (non-terminal) orders — delivered/cancelled load lazily.
      final base = _database.child(_tenantPath('shop-orders'));
      final byId = <String, Map<String, dynamic>>{};
      await Future.wait(_activeRawStatuses.map((s) async {
        try {
          _mergeSnapshot(byId, await base.orderByChild('status').equalTo(s).get());
        } catch (_) {}
      }));

      final orders = byId.values.toList();
      await _hydrateAssignedRiderNames(orders);
      _sortByCreatedDesc(orders);

      if (mounted) {
        setState(() {
          _allOrders = orders;
          _isLoading = false;
          _initialLoadDone = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _initialLoadDone = true;
        });
      }
    }
  }

  void _onTabChanged() {
    if (_tabController.index == 1 && !_deliveredLoaded && !_deliveredLoading) {
      _loadDeliveredOrders();
    } else if (_tabController.index == 2 &&
        !_cancelledLoaded &&
        !_cancelledLoading) {
      _loadCancelledOrders();
    }
  }

  Future<void> _loadDeliveredOrders() async {
    if (_deliveredLoading) return;
    _deliveredLoading = true;
    if (mounted) setState(() {});
    try {
      final base = _database.child(_tenantPath('shop-orders'));
      final byId = <String, Map<String, dynamic>>{};
      _mergeSnapshot(byId, await base.orderByChild('status').equalTo('delivered').get());
      final orders = byId.values.toList();
      await _hydrateAssignedRiderNames(orders);
      _sortByCreatedDesc(orders);
      if (mounted) {
        setState(() {
          _deliveredList = orders;
          _deliveredLoaded = true;
        });
      }
    } catch (_) {
    } finally {
      _deliveredLoading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadCancelledOrders() async {
    if (_cancelledLoading) return;
    _cancelledLoading = true;
    if (mounted) setState(() {});
    try {
      final base = _database.child(_tenantPath('shop-orders'));
      final byId = <String, Map<String, dynamic>>{};
      for (final s in const ['cancelled', 'canceled', 'rejected']) {
        try {
          _mergeSnapshot(byId, await base.orderByChild('status').equalTo(s).get());
        } catch (_) {}
      }
      final orders = byId.values.toList();
      await _hydrateAssignedRiderNames(orders);
      _sortByCreatedDesc(orders);
      if (mounted) {
        setState(() {
          _cancelledList = orders;
          _cancelledLoaded = true;
        });
      }
    } catch (_) {
    } finally {
      _cancelledLoading = false;
      if (mounted) setState(() {});
    }
  }

  int get _pendingCustomCount => _allOrders
      .where(
        (o) =>
            o['orderType'] == 'custom' &&
            (o['status'] ?? '').toString().toLowerCase().trim() == 'pending' &&
            _isOpenStatusRecent(o),
      )
      .length;

  List<Map<String, dynamic>> get _activeOrders {
    var list = _allOrders.where((o) {
      final s = _normalizeWorkflowStatus(o['status']);
      final isActive =
          s == 'pending' ||
          s == 'pending_admin' ||
          s == 'admin_pending' ||
          s == 'available' ||
          s == 'picked' ||
          s == 'on_the_way' ||
          s == 'merchant_pending' ||
          s == 'merchant_cancel_requested';
      if (!isActive) return false;
      return _isOpenStatusRecent(o);
    }).toList();
    if (_searchActive.isNotEmpty) {
      final q = _searchActive.toLowerCase();
      list = list.where((o) => _matchesSearch(o, q)).toList();
    }
    return list;
  }

  List<Map<String, dynamic>> get _deliveredOrders {
    var list = _deliveredList
        .where(
          (o) {
            final s = (o['status'] ?? '').toString().toLowerCase().trim();
            return s == 'delivered';
          },
        )
        .toList();
    if (_deliveredDateRange != null) {
      final startDate = DateTime(
        _deliveredDateRange!.start.year,
        _deliveredDateRange!.start.month,
        _deliveredDateRange!.start.day,
      );
      final endDate = DateTime(
        _deliveredDateRange!.end.year,
        _deliveredDateRange!.end.month,
        _deliveredDateRange!.end.day,
        23,
        59,
        59,
        999,
      );
      list = list.where((o) {
        final ts = o['createdAt'];
        if (ts == null) return false;
        try {
          final dt = ts is int
              ? DateTime.fromMillisecondsSinceEpoch(ts)
              : DateTime.fromMillisecondsSinceEpoch(int.parse(ts.toString()));
          return !dt.isBefore(startDate) && !dt.isAfter(endDate);
        } catch (_) {
          return false;
        }
      }).toList();
    }
    if (_searchDelivered.isNotEmpty) {
      final q = _searchDelivered.toLowerCase();
      list = list.where((o) => _matchesSearch(o, q)).toList();
    }
    return list;
  }

  List<Map<String, dynamic>> get _cancelledOrders {
    var list = _cancelledList
        .where(
          (o) {
            final s = (o['status'] ?? '').toString().toLowerCase().trim();
            return s == 'cancelled' || s == 'canceled' || s == 'rejected';
          },
        )
        .toList();
    if (_deliveredDateRange != null) {
      final startDate = DateTime(
        _deliveredDateRange!.start.year,
        _deliveredDateRange!.start.month,
        _deliveredDateRange!.start.day,
      );
      final endDate = DateTime(
        _deliveredDateRange!.end.year,
        _deliveredDateRange!.end.month,
        _deliveredDateRange!.end.day,
        23,
        59,
        59,
        999,
      );
      list = list.where((o) {
        final ts = o['createdAt'];
        if (ts == null) return false;
        try {
          final dt = ts is int
              ? DateTime.fromMillisecondsSinceEpoch(ts)
              : DateTime.fromMillisecondsSinceEpoch(int.parse(ts.toString()));
          return !dt.isBefore(startDate) && !dt.isAfter(endDate);
        } catch (_) {
          return false;
        }
      }).toList();
    }
    if (_searchCancelled.isNotEmpty) {
      final q = _searchCancelled.toLowerCase();
      list = list.where((o) => _matchesSearch(o, q)).toList();
    }
    return list;
  }

  bool _isMerchantTimeoutOrder(Map<String, dynamic> order) {
    final type = (order['orderType'] ?? 'shop').toString();
    if (type != 'shop') return false;
    final status = (order['status'] ?? '').toString().toLowerCase();
    if (status != 'merchant_pending') return false;
    final createdAt = order['createdAt'] ?? order['timestamp'];
    if (createdAt == null) return false;
    final timeoutBase =
        order['merchantPendingAt'] ??
        order['adminApprovedAt'] ??
        order['createdAt'] ??
        order['timestamp'];
    if (timeoutBase == null) return false;
    final createdMs = int.tryParse(timeoutBase.toString()) ?? 0;
    if (createdMs <= 0) return false;
    final timeoutAt = createdMs + const Duration(minutes: 3).inMilliseconds;
    return DateTime.now().millisecondsSinceEpoch > timeoutAt;
  }

  bool _matchesSearch(Map<String, dynamic> o, String q) {
    return (o['shopName'] ?? '').toString().toLowerCase().contains(q) ||
        (o['userName'] ?? '').toString().toLowerCase().contains(q) ||
        (o['userEmail'] ?? '').toString().toLowerCase().contains(q) ||
        (o['customOrderId'] ?? o['id'] ?? '').toString().toLowerCase().contains(
          q,
        ) ||
        (o['assignedRiderName'] ?? '').toString().toLowerCase().contains(q) ||
        (o['assignedRider'] ?? '').toString().toLowerCase().contains(q) ||
        (o['contact'] ?? '').toString().toLowerCase().contains(q) ||
        (o['userPhone'] ?? '').toString().toLowerCase().contains(q);
  }

  String _normalizeWorkflowStatus(dynamic rawStatus) {
    final status = (rawStatus ?? 'pending').toString().toLowerCase().trim();
    if (status == 'on_way' || status == 'out_for_delivery') {
      return 'on_the_way';
    }
    if (status == 'confirmed' || status == 'preparing') {
      return 'available';
    }
    return status;
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '0') ?? 0.0;
  }

  int _toEpochMs(dynamic value) {
    int raw;
    if (value is int) {
      raw = value;
    } else if (value is num) {
      raw = value.toInt();
    } else {
      final text = (value ?? '').toString().trim();
      if (text.isEmpty) return 0;
      final asInt = int.tryParse(text);
      if (asInt != null) {
        raw = asInt;
      } else {
        final asDate = DateTime.tryParse(text);
        raw = asDate?.millisecondsSinceEpoch ?? 0;
      }
    }

    if (raw <= 0) return 0;

    // Normalize seconds/microseconds/nanoseconds into milliseconds.
    if (raw < 100000000000) {
      raw *= 1000;
    } else {
      while (raw > 9999999999999) {
        raw ~/= 1000;
      }
    }

    return raw;
  }

  int _resolveOpenOrderTimestamp(Map<String, dynamic> order) {
    final candidates = <dynamic>[
      order['createdAt'],
      order['createdAtClient'],
      order['timestamp'],
      order['confirmedAt'],
      order['preparingAt'],
      order['availableAt'],
      order['pickedAt'],
      order['onTheWayAt'],
      order['riderPickedAt'],
      order['updatedAt'],
    ];

    for (final candidate in candidates) {
      final ms = _toEpochMs(candidate);
      if (ms > 0) return ms;
    }
    return 0;
  }

  bool _isOpenStatusRecent(Map<String, dynamic> order) {
    final status = _normalizeWorkflowStatus(order['status']);
    const openStatuses = <String>{
      'pending',
      'pending_admin',
      'admin_pending',
      'available',
      'picked',
      'on_the_way',
      'merchant_pending',
      'merchant_cancel_requested',
    };

    if (!openStatuses.contains(status)) return true;

    final orderTime = _resolveOpenOrderTimestamp(order);
    if (orderTime <= 0) return false;

    final now = DateTime.now().millisecondsSinceEpoch;
    final age = now - orderTime;
    if (age < 0) {
      return (orderTime - now) <= _maxFutureTimestampSkewMs;
    }

    return age <= _openOrderFreshnessWindowMs;
  }

  List<Map<String, dynamic>> _extractItemList(dynamic rawItems) {
    final items = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) {
          items.add(Map<String, dynamic>.from(it));
        }
      }
    }
    return items;
  }

  Future<void> _hydrateAssignedRiderNames(
    List<Map<String, dynamic>> orders,
  ) async {
    final missingIds = <String>{};

    for (final order in orders) {
      final riderId = (order['assignedRider'] ?? '').toString().trim();
      if (riderId.isEmpty) continue;

      final currentName =
          (order['assignedRiderName'] ?? order['riderName'] ?? '')
              .toString()
              .trim();
      if (currentName.isNotEmpty) {
        _riderNameCache[riderId] = currentName;
        continue;
      }

      final cachedName = (_riderNameCache[riderId] ?? '').trim();
      if (cachedName.isNotEmpty) {
        order['assignedRiderName'] = cachedName;
        continue;
      }

      missingIds.add(riderId);
    }

    if (missingIds.isNotEmpty) {
      await Future.wait(
        missingIds.map((riderId) async {
          try {
            final snap = await _database.child('users/$riderId').get();
            if (!snap.exists || snap.value is! Map) {
              _riderNameCache[riderId] = '';
              return;
            }

            final riderData = Map<String, dynamic>.from(snap.value as Map);
            final riderName =
                (riderData['name'] ?? riderData['displayName'] ?? '')
                    .toString()
                    .trim();
            _riderNameCache[riderId] = riderName;
          } catch (_) {
            _riderNameCache[riderId] = '';
          }
        }),
      );
    }

    for (final order in orders) {
      final riderId = (order['assignedRider'] ?? '').toString().trim();
      if (riderId.isEmpty) continue;

      final existingName =
          (order['assignedRiderName'] ?? order['riderName'] ?? '')
              .toString()
              .trim();
      if (existingName.isNotEmpty) continue;

      final hydratedName = (_riderNameCache[riderId] ?? '').trim();
      if (hydratedName.isNotEmpty) {
        order['assignedRiderName'] = hydratedName;
      }
    }
  }

  // ── Actions ──

  Future<void> _pushNotificationToPath(
    String path, {
    required String title,
    required String body,
    required Map<String, dynamic> details,
  }) async {
    await _database.child(path).push().set({
      'title': title,
      'body': body,
      'details': details,
      'createdAt': ServerValue.timestamp,
      'read': false,
      'source': 'order_lifecycle',
    });
  }

  Future<void> _notifyOrderRoles(
    Map<String, dynamic> order, {
    required String title,
    required String body,
    bool notifyAdmin = false,
    bool notifyMerchant = false,
    bool notifyRider = false,
    bool notifyCustomer = false,
  }) async {
    final orderId = (order['id'] ?? '').toString();
    final userId = (order['userId'] ?? '').toString();
    final shopId = (order['shopId'] ?? '').toString();

    final details = <String, dynamic>{
      'orderId': orderId,
      'shopId': shopId,
      'shopName': (order['shopName'] ?? order['shop'] ?? '').toString(),
      'status': (order['status'] ?? '').toString(),
      'customerName': (order['userName'] ?? order['userEmail'] ?? '')
          .toString(),
      'total': (order['grandTotal'] ?? order['budget'] ?? 0),
      'cancelReason': (order['cancelReason'] ?? '').toString(),
    };

    if (notifyCustomer && userId.isNotEmpty) {
      unawaited(
        NotificationService.sendOrderStatusNotification(
          targetUserId: userId,
          status: (order['status'] ?? '').toString(),
          orderId: orderId,
          orderCode: (order['customOrderId'] ?? order['orderCode'] ?? orderId).toString(),
          shopName: (order['shopName'] ?? order['shop'] ?? '').toString(),
          cancelReason: (order['cancelReason'] ?? '').toString(),
        ).catchError((_) => {}),
      );
    }

    if (notifyAdmin) {
      await _pushNotificationToPath(
        _tenantPath('notifications/admin/inbox'),
        title: title,
        body: body,
        details: details,
      );
      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'admin',
          city: CityScopeService.currentCity,
          title: title,
          body: body,
          data: {
            'type': 'admin_inbox',
            'orderId': orderId,
            'city': CityScopeService.currentCity,
          },
        ).catchError((_) => {}),
      );
    }

    if (notifyMerchant) {
      final allItems = _extractItemList(order['items']);
      final targetShopIds = <String>{};
      if (shopId.isNotEmpty) targetShopIds.add(shopId);
      for (final item in allItems) {
        final itemShopId = (item['shopId'] ?? '').toString().trim();
        if (itemShopId.isNotEmpty) {
          targetShopIds.add(itemShopId);
        }
      }

      for (final targetShopId in targetShopIds) {
        final shopSnap = await _database
            .child(_tenantPath('shops/$targetShopId'))
            .get();
        if (!shopSnap.exists || shopSnap.value is! Map) continue;

        final shop = Map<String, dynamic>.from(shopSnap.value as Map);
        final merchantId = (shop['merchantId'] ?? '').toString().trim();
        if (merchantId.isEmpty) continue;

        final merchantItems = allItems
            .where((item) => (item['shopId'] ?? '').toString() == targetShopId)
            .toList();

        var merchantTotal = 0.0;
        for (final item in merchantItems) {
          merchantTotal +=
              _toDouble(item['price']) * _toDouble(item['quantity'] ?? 1);
        }

        final merchantDetails = Map<String, dynamic>.from(details)
          ..['shopId'] = targetShopId
          ..['shopName'] = (shop['name'] ?? details['shopName'] ?? '')
              .toString()
          ..['items'] = merchantItems
          ..['itemCount'] = merchantItems.length
          ..['merchantViewTotal'] = merchantTotal;

        await _pushNotificationToPath(
          _tenantPath('notifications/merchant/$merchantId'),
          title: title,
          body: body,
          details: merchantDetails,
        );
      }
    }

    if (notifyRider) {
      await _pushNotificationToPath(
        _tenantPath('notifications/rider/inbox'),
        title: title,
        body: body,
        details: details,
      );
      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'rider',
          city: CityScopeService.currentCity,
          title: title,
          body: body,
          channelId: 'rider_new_order',
          data: {
            'type': 'rider_inbox',
            'orderId': orderId,
            'city': CityScopeService.currentCity,
          },
        ).catchError((_) => {}),
      );
    }
  }

  Future<void> _archiveCancelledOrder(
    Map<String, dynamic> order, {
    required String reason,
    required String cancelledByRole,
  }) async {
    final orderId = (order['id'] ?? '').toString().trim();
    if (orderId.isEmpty) return;
    final orderType = (order['orderType'] ?? 'shop').toString();
    final key = '${orderType}_$orderId';
    final payload = Map<String, dynamic>.from(order)
      ..['orderId'] = orderId
      ..['orderType'] = orderType
      ..['status'] = 'cancelled'
      ..['cancelReason'] = reason
      ..['cancelledByRole'] = cancelledByRole
      ..['cancelledAt'] = DateTime.now().millisecondsSinceEpoch
      ..['archivedAt'] = ServerValue.timestamp;

    await _database.child(_tenantPath('order-history')).child(key).set(payload);
  }

  Future<Map<String, String>> _getAdminCancelDetails() async {
    String adminName = '';
    String adminEmail = '';
    String adminUid = '';

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        adminUid = user.uid;
        adminEmail = user.email ?? '';
        adminName = user.displayName ?? '';
        
        final snap = await FirebaseDatabase.instance.ref('users/${user.uid}').get();
        if (snap.exists && snap.value is Map) {
          final data = Map<String, dynamic>.from(snap.value as Map);
          if (adminName.isEmpty) {
            adminName = (data['name'] ?? '').toString().trim();
          }
          if (adminEmail.isEmpty) {
            adminEmail = (data['email'] ?? '').toString().trim();
          }
          if (adminEmail.isEmpty) {
            adminEmail = (data['phoneNumber'] ?? '').toString().trim();
          }
        }
        
        if (adminName.isEmpty) {
          adminName = adminEmail;
        }
        if (adminName.isEmpty) {
          adminName = 'Admin';
        }
      }
    } catch (_) {}
    
    return {
      'name': adminName.isEmpty ? 'Admin' : adminName,
      'email': adminEmail,
      'uid': adminUid,
    };
  }

  Future<void> _updateStatus(
    String orderId,
    String type,
    String newStatus,
  ) async {
    try {
      final path = _tenantPath(
        type == 'custom' ? 'custom-orders' : 'shop-orders',
      );
      final normalizedStatus = _normalizeWorkflowStatus(newStatus);
      final beforeSnap = await _database.child(path).child(orderId).get();
      final before = beforeSnap.exists && beforeSnap.value is Map
          ? Map<String, dynamic>.from(beforeSnap.value as Map)
          : <String, dynamic>{};
      before['id'] = orderId;
      before['orderType'] = type;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final updates = <String, dynamic>{
        'status': normalizedStatus,
        'updatedAt': ServerValue.timestamp,
      };
      if (normalizedStatus == 'available') {
        updates['availableAt'] = nowMs;
        updates['estimatedTime'] = 40;
      }
      if (normalizedStatus == 'picked') {
        updates['pickedAt'] = nowMs;
        updates['riderPickedAt'] = nowMs;
      }
      if (normalizedStatus == 'on_the_way') {
        updates['onTheWayAt'] = nowMs;
      }
      if (normalizedStatus == 'delivered') {
        updates['deliveredAt'] = nowMs;
      }
      if (normalizedStatus == 'cancelled' || normalizedStatus == 'canceled') {
        final details = await _getAdminCancelDetails();
        
        updates['cancelledByRole'] = 'admin';
        updates['cancelledByName'] = details['name'];
        updates['cancelledByEmail'] = details['email'];
        updates['cancelledByUid'] = details['uid'];
        updates['cancelledAt'] = nowMs;
        
        before['cancelledByRole'] = 'admin';
        before['cancelledByName'] = details['name'];
        before['cancelledByEmail'] = details['email'];
        before['cancelledByUid'] = details['uid'];
        before['cancelledAt'] = nowMs;
      }
      await _database.child(path).child(orderId).update(updates);
      before['status'] = normalizedStatus;

      // Terminal transitions invalidate the lazily-loaded history caches so the
      // order shows up when the Delivered/Cancelled tab is next opened.
      if (normalizedStatus == 'delivered') {
        _deliveredLoaded = false;
      } else if (normalizedStatus == 'cancelled' ||
          normalizedStatus == 'canceled' ||
          normalizedStatus == 'rejected') {
        _cancelledLoaded = false;
      }

      if (normalizedStatus == 'cancelled' || normalizedStatus == 'canceled') {
        await _archiveCancelledOrder(
          before,
          reason: (before['cancelReason'] ?? 'Cancelled by admin').toString(),
          cancelledByRole: 'admin',
        );
      }

      if (normalizedStatus == 'delivered') {
        final userId = (before['userId'] ?? '').toString();
        await _loyaltyService.awardOrderPoints(
          orderPath: path,
          orderId: orderId,
          userId: userId,
        );
      }

      final copy = NotificationService.getOrderStatusNotificationCopy(
        status: normalizedStatus,
        orderCode: (before['customOrderId'] ?? before['orderCode'] ?? orderId).toString(),
        shopName: (before['shopName'] ?? before['shop'] ?? '').toString(),
        cancelReason: (before['cancelReason'] ?? '').toString(),
      );
      final title = copy['title']!;
      final body = copy['body']!;

      await _notifyOrderRoles(
        before,
        title: title,
        body: body,
        notifyCustomer: true,
        notifyAdmin: false,
        notifyMerchant: false,
        notifyRider: normalizedStatus == 'available',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Status updated to ${_formatStatus(normalizedStatus)}',
            ),
            backgroundColor: _statusColor(normalizedStatus),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _approveForMerchant(Map<String, dynamic> order) async {
    final type = (order['orderType'] ?? 'shop').toString();
    if (type != 'shop') {
      await _updateStatus(order['id'], type, 'available');
      return;
    }

    try {
      final orderId = (order['id'] ?? '').toString();
      if (orderId.isEmpty) {
        throw Exception('Order id missing.');
      }

      await _database.child(_tenantPath('shop-orders')).child(orderId).update({
        'status': 'available',
        'adminApprovalStatus': 'approved',
        'merchantDecision': 'auto_approved_by_admin',
        'adminApprovedAt': DateTime.now().millisecondsSinceEpoch,
        'merchantAcceptedAt': DateTime.now().millisecondsSinceEpoch,
        'availableAt': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': ServerValue.timestamp,
        'customerStatusMessage':
            'Admin confirmed your order. Rider assignment is in progress.',
      });

      await _notifyOrderRoles(
        order,
        title: 'Order Confirmed by Admin',
        body:
            'Admin approved order ${(order['customOrderId'] ?? order['id']).toString()}. Order is now available for riders.',
        notifyCustomer: true,
        notifyMerchant: true,
        notifyAdmin: false,
        notifyRider: true,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order moved to available and sent to rider pool'),
            backgroundColor: Color(0xFFFF6B00),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _cancelOrderWithReason(
    Map<String, dynamic> order, {
    String? prefix,
  }) async {
    final reasons = [
      'Item out of stock',
      'Shop temporarily closed',
      'Delivery area unavailable',
      'Merchant unable to fulfill order',
      'Address issue',
      'Payment verification failed',
      'Other',
    ];

    String selected = reasons.first;
    final customCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Cancel Order with Reason'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Reason',
                ),
                items: reasons
                    .map(
                      (r) => DropdownMenuItem<String>(value: r, child: Text(r)),
                    )
                    .toList(),
                onChanged: (v) => setS(() => selected = v ?? reasons.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: customCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Additional note (optional)',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cancel Order'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;

    final note = customCtrl.text.trim();
    final reason = selected == 'Other' && note.isNotEmpty ? note : selected;
    final fullReason = prefix == null || prefix.isEmpty
        ? reason
        : '$prefix. $reason';

    final type = (order['orderType'] ?? 'shop').toString();
    final path = _tenantPath(
      type == 'custom' ? 'custom-orders' : 'shop-orders',
    );

    final details = await _getAdminCancelDetails();
    final adminName = details['name'];
    final adminEmail = details['email'];
    final adminUid = details['uid'];

    await _database.child(path).child(order['id']).update({
      'status': 'cancelled',
      'cancelReason': fullReason,
      'cancelledByRole': 'admin',
      'cancelledByName': adminName,
      'cancelledByEmail': adminEmail,
      'cancelledByUid': adminUid,
      'cancelledAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': ServerValue.timestamp,
      'customerStatusMessage': 'Order canceled: $fullReason',
      if (type == 'shop') 'merchantDecision': 'admin_canceled',
      if (type == 'shop') 'adminApprovalStatus': 'canceled',
    });

    final archived = Map<String, dynamic>.from(order)
      ..['orderType'] = type
      ..['status'] = 'cancelled'
      ..['cancelReason'] = fullReason
      ..['cancelledByRole'] = 'admin'
      ..['cancelledByName'] = adminName
      ..['cancelledByEmail'] = adminEmail
      ..['cancelledByUid'] = adminUid;
    await _archiveCancelledOrder(
      archived,
      reason: fullReason,
      cancelledByRole: 'admin',
    );

    await _notifyOrderRoles(
      order,
      title: 'Order Canceled by Admin',
      body:
          'Order ${(order['customOrderId'] ?? order['id']).toString()} canceled. Reason: $fullReason',
      notifyCustomer: true,
      notifyAdmin: false,
      notifyMerchant: true,
      notifyRider: false,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order canceled and reason shared with customer'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteAllOrders() async {
    final currentCityLabel = CityScopeService.cityLabel(CityScopeService.currentCity);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 24),
            const SizedBox(width: 8),
            Text('Delete All $currentCityLabel Orders'),
          ],
        ),
        content: Text(
          'This will permanently delete ALL orders (active + delivered + cancelled) for $currentCityLabel from the database.\n\nOrders in other cities will NOT be affected.\n\nThis action cannot be undone!',
          style: TextStyle(color: Colors.grey[600], height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await _database.child(_tenantPath('shop-orders')).remove();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('All $currentCityLabel orders deleted successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
        _loadOrders();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _deleteOrder(String orderId, String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.red, size: 22),
            SizedBox(width: 8),
            Text('Delete Order'),
          ],
        ),
        content: const Text(
          'Are you sure you want to delete this order?\nThis action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final path = _tenantPath(
        type == 'custom' ? 'custom-orders' : 'shop-orders',
      );
      final snap = await _database.child(path).child(orderId).get();
      if (snap.exists && snap.value is Map) {
        String? adminName;
        try {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            adminName = user.displayName;
            if (adminName == null || adminName.trim().isEmpty) {
              final snap = await FirebaseDatabase.instance.ref('users/${user.uid}/name').get();
              if (snap.exists) {
                adminName = snap.value?.toString();
              }
            }
            if (adminName == null || adminName.trim().isEmpty) {
              adminName = user.email;
            }
          }
        } catch (_) {}
        adminName = adminName ?? 'Admin';

        final order = Map<String, dynamic>.from(snap.value as Map)
          ..['id'] = orderId
          ..['orderType'] = type
          ..['cancelledByName'] = adminName;
        await _archiveCancelledOrder(
          order,
          reason: 'Deleted by admin',
          cancelledByRole: 'admin',
        );
      }
      await _database.child(path).child(orderId).remove();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order deleted'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        _loadOrders();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _copyOrderId(String id) {
    Clipboard.setData(ClipboardData(text: id));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Order ID copied!'),
          backgroundColor: _primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange:
          _deliveredDateRange ??
          DateTimeRange(
            start: DateTime(now.year, now.month, now.day),
            end: DateTime(now.year, now.month, now.day),
          ),
      builder: (context, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: const ColorScheme.light(primary: _primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _deliveredDateRange = picked);
  }

  // ── Helpers ──

  Color _statusColor(String status) {
    switch (_normalizeWorkflowStatus(status)) {
      case 'pending':
        return const Color(0xFFF59E0B);
      case 'merchant_pending':
        return const Color(0xFF0EA5A4);
      case 'merchant_cancel_requested':
        return const Color(0xFFDC2626);
      case 'available':
        return const Color(0xFFFF6B00);
      case 'picked':
        return const Color(0xFF8B5CF6);
      case 'on_the_way':
        return const Color(0xFF06B6D4);
      case 'delivered':
        return const Color(0xFF22C55E);
      case 'cancelled':
      case 'canceled':
        return const Color(0xFFEF4444);
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon(String status) {
    switch (_normalizeWorkflowStatus(status)) {
      case 'pending':
        return Icons.access_time_rounded;
      case 'merchant_pending':
        return Icons.storefront_rounded;
      case 'merchant_cancel_requested':
        return Icons.report_problem_rounded;
      case 'available':
        return Icons.local_offer_rounded;
      case 'picked':
        return Icons.backpack_rounded;
      case 'on_the_way':
        return Icons.moped_rounded;
      case 'delivered':
        return Icons.check_circle_rounded;
      case 'cancelled':
      case 'canceled':
        return Icons.cancel_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  String _formatStatus(String s) => _normalizeWorkflowStatus(s)
      .replaceAll('_', ' ')
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  String _timeAgo(dynamic ts) {
    if (ts == null) return 'Unknown';
    try {
      final dt = ts is int
          ? DateTime.fromMillisecondsSinceEpoch(ts)
          : DateTime.fromMillisecondsSinceEpoch(int.parse(ts.toString()));
      final diff = DateTime.now().difference(dt);
      if (diff.inDays > 0) return '${diff.inDays}d ago';
      if (diff.inHours > 0) return '${diff.inHours}h ago';
      if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
      return 'Just now';
    } catch (_) {
      return 'Unknown';
    }
  }

  String _formatFull(dynamic ts) {
    if (ts == null) return 'N/A';
    try {
      final dt = ts is int
          ? DateTime.fromMillisecondsSinceEpoch(ts)
          : DateTime.fromMillisecondsSinceEpoch(int.parse(ts.toString()));
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final m = dt.minute.toString().padLeft(2, '0');
      final p = dt.hour >= 12 ? 'PM' : 'AM';
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $h:$m $p';
    } catch (_) {
      return 'N/A';
    }
  }

  String _formatDateShort(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  void _openCustomerChat(Map<String, dynamic> order) {
    final userId = (order['userId'] ?? '').toString().trim();
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminChatDetailPage(
          userId: userId,
          userName: (order['userName'] ?? order['userEmail'] ?? 'Customer')
              .toString(),
          userPhone: (order['contact'] ?? order['userPhone'] ?? '').toString(),
          orderId: (order['id'] ?? '').toString(),
          orderType: (order['orderType'] ?? '').toString(),
          orderCode: (order['customOrderId'] ?? order['id'] ?? '').toString(),
        ),
      ),
    );
  }

  // ── BUILD ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: const Text(
          'Manage Orders',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadOrders();
            },
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                tooltip: 'Chats',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AdminChatsPage(),
                  ),
                ),
              ),
              if (_activeChatThreadsCount > 0)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        _activeChatThreadsCount > 99
                            ? '99+'
                            : '$_activeChatThreadsCount',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (val) {
              if (val == 'delete_all') _deleteAllOrders();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'delete_all',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, size: 18, color: Colors.red),
                    SizedBox(width: 8),
                    Text(
                      'Delete All Orders',
                      style: TextStyle(color: Colors.red),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          onTap: (_) => setState(() {}),
          isScrollable: false,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          indicatorSize: TabBarIndicatorSize.label,
          labelPadding: EdgeInsets.zero,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.pending_actions_rounded, size: 15),
                  const SizedBox(width: 4),
                  const Text('Active'),
                  if (_activeOrders.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_activeOrders.length}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_rounded, size: 15),
                  const SizedBox(width: 4),
                  const Text('Delivered'),
                  if (_deliveredOrders.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_deliveredOrders.length}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cancel_rounded, size: 15),
                  const SizedBox(width: 4),
                  const Text('Cancelled'),
                  if (_cancelledOrders.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_cancelledOrders.length}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildActiveTab(),
                _buildDeliveredTab(),
                _buildCancelledTab(),
              ],
            ),
    );
  }

  // ── ACTIVE TAB ──

  Widget _buildActiveTab() {
    final orders = _activeOrders;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          color: Colors.white,
          child: TextField(
            onChanged: (v) => setState(() => _searchActive = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search active orders...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: Colors.grey[400],
                size: 18,
              ),
              filled: true,
              fillColor: const Color(0xFFF5F5F5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        Expanded(
          child: orders.isEmpty
              ? _buildEmpty('No active orders')
              : RefreshIndicator(
                  color: _primary,
                  onRefresh: _loadOrders,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
                    itemCount: orders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _buildOrderCard(orders[i]),
                  ),
                ),
        ),
      ],
    );
  }

  // ── HISTORY TAB ──

  Widget _buildDeliveredTab() {
    final orders = _deliveredOrders;
    final hasFilter = _deliveredDateRange != null;
    final isToday = _isTodayRange(_deliveredDateRange);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          color: Colors.white,
          child: Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 16, color: _primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isToday
                      ? "Today's History"
                      : hasFilter
                          ? '${_formatDateShort(_deliveredDateRange!.start)} - ${_formatDateShort(_deliveredDateRange!.end)}'
                          : 'All History Orders',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: hasFilter ? _primary : const Color(0xFF1A1A1A),
                  ),
                ),
              ),
              if (hasFilter)
                GestureDetector(
                  onTap: () => setState(() => _deliveredDateRange = null),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Colors.red[400],
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _pickDateRange,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.filter_alt_rounded, size: 14, color: _primary),
                      const SizedBox(width: 4),
                      Text(
                        'Filter',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
          color: Colors.white,
          child: TextField(
            onChanged: (v) => setState(() => _searchDelivered = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search history orders...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: Colors.grey[400],
                size: 18,
              ),
              filled: true,
              fillColor: const Color(0xFFF5F5F5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        Expanded(
          child: (_deliveredLoading && !_deliveredLoaded)
              ? const Center(child: CircularProgressIndicator(color: _primary))
              : orders.isEmpty
              ? RefreshIndicator(
                  color: _primary,
                  onRefresh: _loadDeliveredOrders,
                  child: ListView(
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.5,
                        child: _buildEmpty(
                          hasFilter
                              ? 'No history orders in selected range'
                              : 'No delivered orders in history',
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  color: _primary,
                  onRefresh: _loadDeliveredOrders,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
                    itemCount: orders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _buildOrderCard(orders[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCancelledTab() {
    final orders = _cancelledOrders;
    final hasFilter = _deliveredDateRange != null;
    final isToday = _isTodayRange(_deliveredDateRange);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          color: Colors.white,
          child: Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 16, color: _primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isToday
                      ? "Today's Cancelled"
                      : hasFilter
                          ? '${_formatDateShort(_deliveredDateRange!.start)} - ${_formatDateShort(_deliveredDateRange!.end)}'
                          : 'All Cancelled Orders',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: hasFilter ? _primary : const Color(0xFF1A1A1A),
                  ),
                ),
              ),
              if (hasFilter)
                GestureDetector(
                  onTap: () => setState(() => _deliveredDateRange = null),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Colors.red[400],
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _pickDateRange,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.filter_alt_rounded, size: 14, color: _primary),
                      const SizedBox(width: 4),
                      Text(
                        'Filter',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
          color: Colors.white,
          child: TextField(
            onChanged: (v) => setState(() => _searchCancelled = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search cancelled orders...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: Colors.grey[400],
                size: 18,
              ),
              filled: true,
              fillColor: const Color(0xFFF5F5F5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        Expanded(
          child: (_cancelledLoading && !_cancelledLoaded)
              ? const Center(child: CircularProgressIndicator(color: _primary))
              : orders.isEmpty
              ? RefreshIndicator(
                  color: _primary,
                  onRefresh: _loadCancelledOrders,
                  child: ListView(
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.5,
                        child: _buildEmpty(
                          hasFilter
                              ? 'No cancelled orders in selected range'
                              : 'No cancelled orders in history',
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  color: _primary,
                  onRefresh: _loadCancelledOrders,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
                    itemCount: orders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _buildOrderCard(orders[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmpty(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: Colors.orange[50],
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.receipt_long_outlined,
              size: 40,
              color: Colors.orange[200],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Pull to refresh',
            style: TextStyle(fontSize: 13, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  // ── ORDER CARD (Redesigned — no status overlay) ──

  Widget _buildOrderCard(
    Map<String, dynamic> order, {
    bool readOnlyHistory = false,
  }) {
    final status = (order['status'] ?? 'pending').toString();
    final statusLower = status.toLowerCase();
    final isTerminalStatus = statusLower == 'delivered' ||
        statusLower == 'cancelled' ||
        statusLower == 'canceled' ||
        statusLower == 'rejected';
    final historyOnly = readOnlyHistory || isTerminalStatus;
    final statusC = _statusColor(status);
    final isCustom = order['orderType'] == 'custom';
    final isInstant = InstantDeliveryService.isInstantOrder(order);
    final shopName = isCustom
        ? (order['shop'] ?? 'Custom Order')
        : (order['shopName'] ?? 'Shop Order');
    final customer = order['userName'] ?? order['userEmail'] ?? 'Unknown';
    final contact = (order['contact']?.toString() ?? '').isNotEmpty
        ? order['contact'].toString()
        : (order['userPhone']?.toString() ?? '');
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final rawId = (order['customOrderId'] ?? order['id'] ?? '').toString();
    final shortId = rawId.length >= 8
        ? rawId.substring(0, 8).toUpperCase()
        : rawId.toUpperCase();
    final isUrgent = (order['urgency'] ?? '').toString().toLowerCase().contains(
      'urgent',
    );
    final assignedRiderId = (order['assignedRider'] ?? '').toString().trim();
    final assignedRiderName =
        (order['assignedRiderName'] ?? order['riderName'] ?? '')
            .toString()
            .trim();
    final hasPickedRider =
        assignedRiderId.isNotEmpty || assignedRiderName.isNotEmpty;
    final riderDisplayName = assignedRiderName.isNotEmpty
        ? assignedRiderName
        : (assignedRiderId.length >= 8
              ? 'Rider #${assignedRiderId.substring(0, 8).toUpperCase()}'
              : assignedRiderId);

    String itemsText = '';
    final items = order['items'];
    if (items is List && items.isNotEmpty) {
      itemsText = items
          .map((i) => '${i['quantity'] ?? 1}× ${i['name'] ?? 'Item'}')
          .join(', ');
    } else if (order['whatYouWant'] != null) {
      itemsText = order['whatYouWant'].toString();
    }

    final displayAddress =
        (order['autoAddressFormatted'] ??
                order['autoAddress'] ??
                order['fullAddress'] ??
                order['address'] ??
                '')
            .toString()
            .trim();

    return GestureDetector(
      onTap: () => _showOrderDetails(order, readOnly: historyOnly),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: isUrgent
              ? Border.all(color: Colors.red.shade300, width: 1.5)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isInstant) InstantDeliveryService.buildOrderBanner(forCardTop: true),
            // ── Colored status strip at top ──
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: statusC,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Row 1: Shop name + Price ──
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          shopName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: Color(0xFF1A1A1A),
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Rs. $total',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: statusC,
                        ),
                      ),
                    ],
                  ),
                  if (hasPickedRider) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.delivery_dining_rounded,
                            size: 13,
                            color: Color(0xFF334155),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              'Picked by: $riderDisplayName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF334155),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  // ── Row 2: Order ID (long press copy) + time + status chip + type badges ──
                  Row(
                    children: [
                      GestureDetector(
                        onLongPress: () => _copyOrderId(rawId),
                        child: Text(
                          '#$shortId',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        ' · ${_timeAgo(order['createdAt'])}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: statusC.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_statusIcon(status), size: 11, color: statusC),
                            const SizedBox(width: 3),
                            Text(
                              _formatStatus(status),
                              style: TextStyle(
                                color: statusC,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isCustom) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.purple[50],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Custom',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.purple[700],
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                      if (isInstant) ...[
                        const SizedBox(width: 4),
                        InstantDeliveryService.buildOrderBadge(compact: true),
                      ],
                      if (isUrgent) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red[50],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'URGENT',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.red[700],
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Divider(height: 1, color: Colors.grey[100]),
                  const SizedBox(height: 8),
                  // ── Customer + Contact ──
                  Row(
                    children: [
                      Icon(
                        Icons.person_outline_rounded,
                        size: 14,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          customer,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[700],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (contact.isNotEmpty)
                        GestureDetector(
                          onTap: () => _showContactOptions(context, contact),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green[50],
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.green[200]!),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.call_rounded,
                                  size: 11,
                                  color: Colors.green[700],
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  contact,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.green[700],
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  // ── Items ──
                  if (itemsText.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.shopping_bag_outlined,
                          size: 14,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            itemsText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // ── Address + Message button (simplified) ──
                  if (displayAddress.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            displayAddress,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // ── Cancellation / Rejection info ──
                  if (statusLower == 'cancelled' ||
                      statusLower == 'canceled' ||
                      statusLower == 'rejected') ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.shade100),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.cancel_outlined, size: 14, color: Colors.red[700]),
                              const SizedBox(width: 6),
                              Text(
                                statusLower == 'rejected' ? 'Rejected Details' : 'Cancellation Details',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.red[700],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          _buildCancelDetailRow('Reason:', order['cancelReason'] ?? 'No reason provided'),
                          const SizedBox(height: 3),
                          _buildCancelDetailRow(
                            'Cancelled By:',
                            _formatCancelledBy(
                              order['cancelledByRole'],
                              order['cancelledByName']?.toString(),
                            ),
                          ),
                          if (order['cancelledByEmail'] != null && order['cancelledByEmail'].toString().isNotEmpty) ...[
                            const SizedBox(height: 3),
                            _buildCancelDetailRow('Email:', order['cancelledByEmail']),
                          ],
                          if (order['cancelledAt'] != null) ...[
                            const SizedBox(height: 3),
                            _buildCancelDetailRow(
                              'Time:',
                              _formatFull(order['cancelledAt']),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: (order['userId'] ?? '').toString().trim().isEmpty
                          ? null
                          : () => _openCustomerChat(order),
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label: const Text('Message Customer',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _primary,
                        side: BorderSide(color: _primary.withValues(alpha: 0.35)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  if (!historyOnly) ...[
                    const SizedBox(height: 10),
                    // ── Quick Actions ──
                    _buildQuickActions(order, status),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions(Map<String, dynamic> order, String status) {
    final st = _normalizeWorkflowStatus(status);
    final type = (order['orderType'] ?? 'shop').toString();
    final isShop = type == 'shop';
    String primaryLabel = '';
    Color primaryColor = _primary;
    IconData primaryIcon = Icons.play_arrow_rounded;
    VoidCallback? primaryAction;

    if (['pending', 'pending_admin', 'admin_pending'].contains(st)) {
      primaryLabel = 'Confirm & Send to Riders';
      primaryIcon = Icons.verified_rounded;
      primaryColor = const Color(0xFFFF6B00);
      primaryAction = isShop
          ? () => _approveForMerchant(order)
          : () => _updateStatus(order['id'], order['orderType'], 'available');
    } else if (st == 'available') {
      primaryLabel = 'Mark as Picked';
      primaryIcon = Icons.backpack_rounded;
      primaryColor = const Color(0xFF8B5CF6);
      primaryAction = () =>
          _updateStatus(order['id'], order['orderType'], 'picked');
    } else if (st == 'picked') {
      primaryLabel = 'Send On the Way';
      primaryIcon = Icons.local_shipping_rounded;
      primaryColor = const Color(0xFF0099FF);
      primaryAction = () =>
          _updateStatus(order['id'], order['orderType'], 'on_the_way');
    } else if (st == 'on_the_way') {
      primaryLabel = 'Mark as Delivered';
      primaryIcon = Icons.check_circle_rounded;
      primaryColor = const Color(0xFF00AA66);
      primaryAction = () =>
          _updateStatus(order['id'], order['orderType'], 'delivered');
    } else if (st == 'merchant_cancel_requested' ||
        _isMerchantTimeoutOrder(order)) {
      primaryLabel = 'Call Merchant';
      primaryIcon = Icons.phone_in_talk_rounded;
      primaryColor = const Color(0xFFFF3B30);
      primaryAction = () {
        final merchantPhone =
            (order['merchantPhone'] ?? order['shopPhone'] ?? '').toString();
        if (merchantPhone.isNotEmpty) {
          launchUrl(Uri.parse('tel:$merchantPhone'));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Merchant phone not available'),
              backgroundColor: Colors.red,
            ),
          );
        }
      };
    }

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: primaryAction,
            icon: Icon(primaryIcon, size: 16),
            label: Text(
              primaryLabel.isEmpty ? 'No Quick Action' : primaryLabel,
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAction == null
                  ? Colors.grey[300]
                  : primaryColor,
              foregroundColor: primaryAction == null
                  ? Colors.grey[700]
                  : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => _showOrderDetails(order),
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text('Details'),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          onSelected: (v) {
            if (v == 'advanced') _showAdvancedStatusPicker(order);
            if (v == 'keep') _approveForMerchant(order);
            if (v == 'cancel') _cancelOrderWithReason(order);
            if (v == 'delete') _deleteOrder(order['id'], order['orderType']);
          },
          itemBuilder: (_) => [
            const PopupMenuItem<String>(
              value: 'advanced',
              child: Text('Advanced Status'),
            ),
            const PopupMenuItem<String>(
              value: 'keep',
              child: Text('Send to Rider Pool'),
            ),
            const PopupMenuItem<String>(
              value: 'cancel',
              child: Text('Cancel w/Reason'),
            ),
            const PopupMenuItem<String>(
              value: 'delete',
              child: Text('Delete Order'),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'More',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showAdvancedStatusPicker(Map<String, dynamic> order) async {
    final statuses = [
      'pending',
      'available',
      'picked',
      'on_the_way',
      'delivered',
      'cancelled',
    ];

    final current = _normalizeWorkflowStatus(order['status']);
    String selected = statuses.contains(current) ? current : 'pending';

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Advanced Status'),
        content: DropdownButtonFormField<String>(
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Select status',
          ),
          items: statuses
              .map(
                (s) => DropdownMenuItem<String>(
                  value: s,
                  child: Text(_formatStatus(s)),
                ),
              )
              .toList(),
          onChanged: (v) {
            selected = v ?? selected;
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, selected),
            child: const Text('Update'),
          ),
        ],
      ),
    );

    if (picked == null || picked.isEmpty) return;
    await _updateStatus(order['id'], order['orderType'], picked);
  }

  // ── ORDER DETAIL BOTTOM SHEET ──

  void _showOrderDetails(Map<String, dynamic> order, {bool readOnly = false}) {
    final status = (order['status'] ?? '').toString().toLowerCase();
    final isTerminal = status == 'delivered' ||
        status == 'cancelled' ||
        status == 'canceled' ||
        status == 'rejected';
    final sheetReadOnly = readOnly || isTerminal;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OrderDetailSheet(
        order: order,
        readOnly: sheetReadOnly,
        onUpdateStatus: _updateStatus,
        onCopyOrderId: _copyOrderId,
        onDeleteOrder: _deleteOrder,
        statusColor: _statusColor,
        formatStatus: _formatStatus,
        formatFull: _formatFull,
      ),
    );
  }

  Widget _buildCancelDetailRow(String label, String value) {
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 11, color: Color(0xFF1A1A1A)),
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: value),
        ],
      ),
    );
  }

  bool _isTodayRange(DateTimeRange? range) {
    if (range == null) return false;
    final now = DateTime.now();
    return range.start.year == now.year &&
        range.start.month == now.month &&
        range.start.day == now.day &&
        range.end.year == now.year &&
        range.end.month == now.month &&
        range.end.day == now.day;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ORDER DETAIL BOTTOM SHEET WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class _OrderDetailSheet extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool readOnly;
  final Future<void> Function(String, String, String) onUpdateStatus;
  final void Function(String) onCopyOrderId;
  final Future<void> Function(String, String) onDeleteOrder;
  final Color Function(String) statusColor;
  final String Function(String) formatStatus;
  final String Function(dynamic) formatFull;

  const _OrderDetailSheet({
    required this.order,
    this.readOnly = false,
    required this.onUpdateStatus,
    required this.onCopyOrderId,
    required this.onDeleteOrder,
    required this.statusColor,
    required this.formatStatus,
    required this.formatFull,
  });

  static const Color _primary = Color(0xFFFF6B00);

  @override
  Widget build(BuildContext context) {
    final status = (order['status'] ?? 'pending').toString();
    final sc = statusColor(status);
    final isCustom = order['orderType'] == 'custom';
    final isInstant = InstantDeliveryService.isInstantOrder(order);
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final assignedRiderId = (order['assignedRider'] ?? '').toString().trim();
    final assignedRiderName =
        (order['assignedRiderName'] ?? order['riderName'] ?? '')
            .toString()
            .trim();
    final riderDisplayName = assignedRiderName.isNotEmpty
        ? assignedRiderName
        : (assignedRiderId.length >= 8
              ? 'Rider #${assignedRiderId.substring(0, 8).toUpperCase()}'
              : assignedRiderId);
    final deliveryInstructions =
        (order['deliveryInstructions'] ??
                order['specialInstructions'] ??
                order['specialNotes'] ??
                '')
            .toString()
            .trim();
    final specialInstructions =
        (order['specialInstructions'] ?? order['specialNotes'] ?? '')
            .toString()
            .trim();
    final rawId = (order['customOrderId'] ?? order['id'] ?? '').toString();
    final shortId = rawId.length >= 8
        ? rawId.substring(0, 8).toUpperCase()
        : rawId.toUpperCase();

    List<Map<String, dynamic>> items = [];
    final rawItems = order['items'];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) items.add(Map<String, dynamic>.from(it));
      }
    }

    final fallbackShopName =
        (isCustom
                ? (order['shop'] ?? 'Custom Order')
                : (order['shopName'] ?? 'Shop Order'))
            .toString();

    final groupedShopItems = <String, List<Map<String, dynamic>>>{};
    final groupedShopNames = <String, String>{};
    for (final item in items) {
      final itemShopId = (item['shopId'] ?? '').toString().trim();
      final rawItemShopName = (item['shopName'] ?? fallbackShopName)
          .toString()
          .trim();
      final itemShopName = rawItemShopName.isEmpty
          ? fallbackShopName
          : rawItemShopName;
      final groupKey = itemShopId.isNotEmpty
          ? 'id:$itemShopId'
          : 'name:${itemShopName.toLowerCase()}';
      groupedShopNames[groupKey] = itemShopName;
      groupedShopItems
          .putIfAbsent(groupKey, () => <Map<String, dynamic>>[])
          .add(item);
    }
    final isMultiShop =
        groupedShopItems.length > 1 || order['isMultiShopOrder'] == true;

    final primaryAddress = (order['address'] ?? '').toString().trim();
    final addressLine2 = (order['address2'] ?? '').toString().trim();
    final manualAddress = (order['fullAddress'] ?? order['address'] ?? '')
        .toString()
        .trim();
    final liveAddress =
        (order['autoAddressFormatted'] ?? order['autoAddress'] ?? manualAddress)
            .toString()
            .trim();
    final parsedHostelRoom = _parseHostelRoom(addressLine2);
    final fallbackHostelRoom = _parseHostelRoom(
      [
        primaryAddress,
        manualAddress,
        liveAddress,
      ].where((part) => part.isNotEmpty).join(', '),
    );
    final hostelValue = _pickFirstNonEmpty([
      (order['hostelNo'] ?? order['hostel'] ?? order['hostelNumber'] ?? '')
          .toString(),
      parsedHostelRoom['hostel'] ?? '',
      fallbackHostelRoom['hostel'] ?? '',
    ]);
    final roomValue = _pickFirstNonEmpty([
      (order['roomNo'] ?? order['room'] ?? order['roomNumber'] ?? '')
          .toString(),
      parsedHostelRoom['room'] ?? '',
      fallbackHostelRoom['room'] ?? '',
    ]);
    final displayAddress = primaryAddress.isNotEmpty
        ? primaryAddress
        : manualAddress;
    final navLat = double.tryParse(
      (order['autoLatitude'] ?? order['latitude'] ?? '').toString(),
    );
    final navLng = double.tryParse(
      (order['autoLongitude'] ?? order['longitude'] ?? '').toString(),
    );
    final hasGpsCoords = navLat != null && navLng != null;
    final hasAddressQuery = liveAddress.isNotEmpty || manualAddress.isNotEmpty;
    final navigationAddress = liveAddress.isNotEmpty
        ? liveAddress
        : manualAddress;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isInstant) ...[
                    InstantDeliveryService.buildOrderBanner(),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: () => onCopyOrderId(rawId),
                              child: Text(
                                'Order #$shortId',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              formatFull(order['createdAt']),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[500],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: sc.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: sc.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          formatStatus(status),
                          style: TextStyle(
                            color: sc,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Divider(color: Colors.grey[100]),
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  // ─ Customer section ─
                  _sectionHeader(
                    'Customer Info',
                    Icons.person_rounded,
                    const Color(0xFFFF6B00),
                  ),
                  _infoTile(
                    Icons.person_outline,
                    'Name',
                    order['userName'] ?? 'N/A',
                  ),
                  _infoTile(
                    Icons.email_outlined,
                    'Email',
                    order['userEmail'] ?? 'N/A',
                  ),
                  if ((order['contact'] ?? order['userPhone'] ?? '')
                      .toString()
                      .isNotEmpty)
                    GestureDetector(
                      onTap: () => _showContactOptions(context, (order['contact'] ?? order['userPhone']).toString()),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green[50],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green[200]!),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.call_rounded,
                              size: 15,
                              color: Colors.green[600],
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 80,
                              child: Text(
                                'Contact',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                (order['contact'] ?? order['userPhone'])
                                    .toString(),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.green[700],
                                ),
                              ),
                            ),
                            Icon(
                              Icons.call_made_rounded,
                              size: 14,
                              color: Colors.green[400],
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    _infoTile(Icons.phone_outlined, 'Contact', 'N/A'),

                  // ─ Order section ─
                  const SizedBox(height: 12),
                  _sectionHeader(
                    'Order Info',
                    Icons.receipt_long_rounded,
                    _primary,
                  ),
                  if (isMultiShop && groupedShopItems.isNotEmpty)
                    _infoTile(
                      Icons.store_rounded,
                      'Shops',
                      '${groupedShopItems.length} shops in one order',
                    )
                  else
                    _infoTile(
                      Icons.store_rounded,
                      isCustom ? 'Requested Shop' : 'Shop',
                      isCustom
                          ? (order['shop'] ?? 'N/A')
                          : (order['shopName'] ?? 'N/A'),
                    ),
                  if (riderDisplayName.isNotEmpty)
                    _infoTile(
                      Icons.delivery_dining_rounded,
                      'Picked By',
                      riderDisplayName,
                    ),
                  if (isCustom)
                    _infoTile(
                      Icons.article_outlined,
                      'What they want',
                      order['whatYouWant'] ?? 'N/A',
                    ),
                  if (order['paymentMethod'] != null)
                    _infoTile(
                      Icons.payment_rounded,
                      'Payment',
                      order['paymentMethod'],
                    ),
                  if (order['urgency'] != null)
                    _infoTile(Icons.speed_rounded, 'Urgency', order['urgency']),

                  // ── Cancellation / Rejection info ──
                  if (status.toLowerCase() == 'cancelled' ||
                      status.toLowerCase() == 'canceled' ||
                      status.toLowerCase() == 'rejected') ...[
                    const SizedBox(height: 12),
                    _sectionHeader(
                      status.toLowerCase() == 'rejected' ? 'Rejected Details' : 'Cancellation Details',
                      Icons.cancel_rounded,
                      Colors.red,
                    ),
                    _infoTile(
                      Icons.report_problem_outlined,
                      'Reason',
                      order['cancelReason'] ?? 'No reason provided',
                    ),
                    _infoTile(
                      Icons.person_outline_rounded,
                      'Cancelled By',
                      _formatCancelledBy(
                        order['cancelledByRole'],
                        order['cancelledByName']?.toString(),
                      ),
                    ),
                    if (order['cancelledByEmail'] != null && order['cancelledByEmail'].toString().isNotEmpty)
                      _infoTile(
                        Icons.email_outlined,
                        'Cancel Email',
                        order['cancelledByEmail'].toString(),
                      ),
                    if (order['cancelledAt'] != null)
                      _infoTile(
                        Icons.access_time_rounded,
                        'Time',
                        formatFull(order['cancelledAt']),
                      ),
                  ],

                  // ─ Items list ─
                  if (items.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _sectionHeader(
                      isMultiShop ? 'Shop Wise Items' : 'Items',
                      Icons.shopping_bag_rounded,
                      Colors.green,
                    ),
                    if (isMultiShop && groupedShopItems.isNotEmpty)
                      ...groupedShopItems.entries.map((entry) {
                        final grouped = entry.value;
                        final groupedShopName =
                            groupedShopNames[entry.key] ?? 'Shop';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                groupedShopName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  color: _primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ...grouped.map(
                                (item) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: Colors.orange[50],
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${item['quantity'] ?? 1}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: _primary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          item['name'] ?? 'Item',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      if (item['price'] != null)
                                        Text(
                                          'Rs. ${item['price']}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13,
                                            color: _primary,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      })
                    else
                      ...items.map(
                        (item) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey[100]!),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.orange[50],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    '${item['quantity'] ?? 1}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: _primary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  item['name'] ?? 'Item',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              if (item['price'] != null)
                                Text(
                                  'Rs. ${item['price']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: _primary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],

                  // ─ Delivery section ─
                  const SizedBox(height: 12),
                  _sectionHeader(
                    'Delivery',
                    Icons.location_on_rounded,
                    Colors.red,
                  ),
                  _infoTile(
                    Icons.location_on_outlined,
                    'Address',
                    displayAddress.isNotEmpty ? displayAddress : 'N/A',
                  ),
                  if (addressLine2.isNotEmpty &&
                      hostelValue.isEmpty &&
                      roomValue.isEmpty)
                    _infoTile(
                      Icons.home_work_outlined,
                      'Hostel / Room',
                      addressLine2,
                    ),
                  if (hostelValue.isNotEmpty)
                    _infoTile(
                      Icons.apartment_rounded,
                      'Hostel No',
                      hostelValue,
                    ),
                  if (roomValue.isNotEmpty)
                    _infoTile(Icons.meeting_room_rounded, 'Room No', roomValue),
                  if (liveAddress.isNotEmpty)
                    _infoTile(
                      Icons.gps_fixed_rounded,
                      'Live GPS Address',
                      liveAddress,
                    ),
                  if (hasGpsCoords)
                    _infoTile(
                      Icons.gps_fixed_rounded,
                      'Coordinates',
                      '${navLat!.toStringAsFixed(6)}, ${navLng!.toStringAsFixed(6)}',
                    ),
                  if (deliveryInstructions.isNotEmpty)
                    _infoTile(
                      Icons.info_outline,
                      'Instructions',
                      deliveryInstructions,
                    ),

                  if (hasGpsCoords || hasAddressQuery) ...[
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () {
                        if (hasGpsCoords) {
                          final coordinateQuery =
                              '${navLat.toString()}, ${navLng.toString()}';
                          LocationService.openLocationInMaps(
                            navLat,
                            navLng,
                            label: 'GPS - $navigationAddress',
                            searchQuery: coordinateQuery,
                          );
                          return;
                        }

                        LocationService.openLocationInMaps(
                          0,
                          0,
                          label: 'Customer - $navigationAddress',
                          searchQuery: navigationAddress.isNotEmpty
                              ? navigationAddress
                              : null,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.blue[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.blue[200]!),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.my_location_rounded,
                              color: Colors.blue[700],
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Navigate to GPS',
                              style: TextStyle(
                                color: Colors.blue[700],
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // ─ Bill summary ─
                  if (total != 0) ...[
                    const SizedBox(height: 12),
                    _sectionHeader(
                      'Bill Summary',
                      Icons.account_balance_wallet_rounded,
                      const Color(0xFFFF6B00),
                    ),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.shade100),
                      ),
                      child: Column(
                        children: [
                          if (order['subtotal'] != null)
                            _billRow('Subtotal', 'Rs. ${order['subtotal']}'),
                          if (order['deliveryFee'] != null)
                            _billRow(
                              'Delivery Fee',
                              'Rs. ${order['deliveryFee']}',
                            ),
                          if (order['tax'] != null)
                            _billRow('Tax', 'Rs. ${order['tax']}'),
                          if (order['extraCharge'] != null && (order['extraCharge'] is num ? order['extraCharge'] > 0 : double.tryParse(order['extraCharge'].toString()) != null && double.parse(order['extraCharge'].toString()) > 0))
                            _billRow('Extra Charges', 'Rs. ${order['extraCharge']}'),
                          const Divider(height: 16),
                          _billRow('Grand Total', 'Rs. $total', bold: true),
                        ],
                      ),
                    ),
                  ],

                  // ─ Special instructions ─
                  if (specialInstructions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _sectionHeader(
                      'Special Instructions',
                      Icons.sticky_note_2_rounded,
                      Colors.amber,
                    ),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber[50],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber[200]!),
                      ),
                      child: Text(
                        specialInstructions,
                        style: TextStyle(
                          color: Colors.amber[900],
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],

                  if (!readOnly) ...[
                    const SizedBox(height: 20),

                    // ─ Status update ─
                    _buildStatusButtons(
                      context,
                      order['id'],
                      order['orderType'],
                      status,
                    ),

                    const SizedBox(height: 16),
                  ],

                  // Copy order ID
                  GestureDetector(
                    onTap: () => onCopyOrderId(rawId),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey[200]!),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.copy_rounded,
                            size: 14,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Copy Full Order ID',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!readOnly) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        onDeleteOrder(
                          (order['id'] ?? '').toString(),
                          (order['orderType'] ?? 'shop').toString(),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.red[50],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red[200]!),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.delete_outline_rounded,
                              size: 16,
                              color: Colors.red[600],
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Delete Order',
                              style: TextStyle(
                                color: Colors.red[600],
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _pickFirstNonEmpty(List<String> values) {
    for (final value in values) {
      final cleaned = value.trim();
      if (cleaned.isNotEmpty) return cleaned;
    }
    return '';
  }

  Map<String, String> _parseHostelRoom(String source) {
    final raw = source.trim();
    if (raw.isEmpty) {
      return const {'hostel': '', 'room': ''};
    }

    String hostel = '';
    String room = '';

    final hostelMatch = RegExp(
      r'\bhostel\s*(?:no\.?|number|#)?\s*[:\-]?\s*([^,;/|\n]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (hostelMatch != null) {
      hostel = (hostelMatch.group(1) ?? '').trim();
      hostel = hostel
          .replaceFirst(RegExp(r'\broom\b.*$', caseSensitive: false), '')
          .trim();
    }

    final roomMatch = RegExp(
      r'\broom\s*(?:no\.?|number|#)?\s*[:\-]?\s*([^,;/|\n]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (roomMatch != null) {
      room = (roomMatch.group(1) ?? '').trim();
    }

    if (hostel.isEmpty && roomMatch != null) {
      final prefix = raw.substring(0, roomMatch.start).trim();
      if (prefix.isNotEmpty) {
        hostel = prefix
            .replaceFirst(
              RegExp(
                r'^hostel\s*(?:no\.?|number|#)?\s*[:\-]?\s*',
                caseSensitive: false,
              ),
              '',
            )
            .trim();
      }
    }

    final segments = raw
        .split(RegExp(r'[,;/|]'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    if (segments.length >= 2) {
      if (hostel.isEmpty) hostel = segments[0];
      if (room.isEmpty) room = segments[1];
    }

    if (hostel == room) {
      hostel = '';
    }

    return {'hostel': hostel, 'room': room};
  }

  Widget _infoTile(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: Colors.grey[400]),
          const SizedBox(width: 10),
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _billRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: bold ? const Color(0xFF1A1A1A) : Colors.grey[600],
                fontWeight: bold ? FontWeight.w800 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: bold ? _primary : const Color(0xFF1A1A1A),
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusButtons(
    BuildContext context,
    String orderId,
    String type,
    String currentStatus,
  ) {
    final statuses = [
      'pending',
      'available',
      'picked',
      'on_the_way',
      'delivered',
      'cancelled',
    ];
    final labels = [
      'Pending',
      'Available',
      'Picked',
      'On The Way',
      'Delivered',
      'Cancelled',
    ];
    final colors = [
      const Color(0xFFF59E0B),
      const Color(0xFFFF6B00),
      const Color(0xFF8B5CF6),
      const Color(0xFF06B6D4),
      const Color(0xFF22C55E),
      const Color(0xFFEF4444),
    ];
    var normalizedCurrent = currentStatus.toLowerCase().trim();
    if (normalizedCurrent == 'on_way' ||
        normalizedCurrent == 'out_for_delivery') {
      normalizedCurrent = 'on_the_way';
    }
    if (normalizedCurrent == 'confirmed' || normalizedCurrent == 'preparing') {
      normalizedCurrent = 'available';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Update Status',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(statuses.length, (i) {
            final isSelected = normalizedCurrent == statuses[i];
            return GestureDetector(
              onTap: isSelected
                  ? null
                  : () {
                      Navigator.pop(context);
                      onUpdateStatus(orderId, type, statuses[i]);
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? colors[i]
                      : colors[i].withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? colors[i]
                        : colors[i].withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? Colors.white : colors[i],
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

void _showContactOptions(BuildContext context, String phone) {
  if (phone.isEmpty) return;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Contact Customer via', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.phone, color: Colors.blue),
              title: const Text('Sim (Call)'),
              onTap: () {
                Navigator.pop(context);
                launchUrl(Uri.parse('tel:$phone'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat, color: Colors.green),
              title: const Text('WhatsApp Business'),
              onTap: () {
                Navigator.pop(context);
                final number = phone.replaceAll(RegExp(r'[^\d+]'), '');
                launchUrl(Uri.parse('whatsapp://send?phone=$number'), mode: LaunchMode.externalApplication);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      );
    },
  );
}

String _formatCancelledBy(dynamic role, [String? name]) {
  if (role == null) return 'System / Unknown';
  final r = role.toString().toLowerCase().trim();
  String formatted = 'System / Unknown';
  if (r.isNotEmpty) {
    if (r == 'admin') {
      formatted = 'Admin';
    } else if (r == 'customer' || r == 'user') {
      formatted = 'Customer';
    } else if (r == 'rider') {
      formatted = 'Rider';
    } else if (r == 'merchant' || r == 'shop') {
      formatted = 'Merchant';
    } else {
      formatted = r[0].toUpperCase() + r.substring(1);
    }
  }
  final cleanedName = name?.trim() ?? '';
  if (cleanedName.isNotEmpty) {
    return '$formatted ($cleanedName)';
  }
  return formatted;
}
