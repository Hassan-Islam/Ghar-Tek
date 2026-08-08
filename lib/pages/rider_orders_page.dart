import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/city_scope_service.dart';
import '../services/instant_delivery_service.dart';
import '../services/notification_service.dart';
import '../services/rider_orders_loader.dart';
import 'package:permission_handler/permission_handler.dart';
import 'user_chat_page.dart';

class _RiderDeliveryPayment {
  const _RiderDeliveryPayment({
    required this.paymentType,
    required this.orderPaymentAmount,
    required this.riderCollectedAmount,
  });

  final String paymentType;
  final double orderPaymentAmount;
  final double riderCollectedAmount;
}

class RiderOrdersPage extends StatefulWidget {
  final bool isDark;
  const RiderOrdersPage({super.key, this.isDark = false});

  @override
  State<RiderOrdersPage> createState() => _RiderOrdersPageState();
}

class _RiderOrdersPageState extends State<RiderOrdersPage>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFF06B6D4);
  int _maxActiveOrdersPerRider = 3;

  Color get _bgColor =>
      widget.isDark ? const Color(0xFF0F172A) : const Color(0xFFF5F5F5);
  Color get _cardBg => widget.isDark ? const Color(0xFF1E293B) : Colors.white;
  Color get _textPrimary =>
      widget.isDark ? Colors.white : const Color(0xFF1A1A1A);
  Color get _surfaceVariant =>
      widget.isDark ? const Color(0xFF253048) : const Color(0xFFF5F5F5);
  Color get _dividerColor =>
      widget.isDark ? Colors.white12 : Colors.grey.shade100;

  final _database = FirebaseDatabase.instance.ref();
  final _auth = FirebaseAuth.instance;
  late TabController _tabController;

  List<Map<String, dynamic>> _allOrders = [];
  // Delivered orders are loaded lazily (only when the Delivered tab is opened)
  // so the screen opens instantly without downloading months of history.
  List<Map<String, dynamic>> _deliveredOrdersList = [];
  bool _deliveredLoaded = false;
  bool _deliveredLoading = false;
  bool _isLoading = true;
  String _searchNew = '';
  String _searchActive = '';
  String _searchDelivered = '';
  DateTimeRange? _deliveredDateRange;
  final Map<String, bool> _unreadChatsByOrderId = {};

  Timer? _loadOrdersDebounce;
  StreamSubscription<DatabaseEvent>? _shopOrdersSub;
  StreamSubscription<DatabaseEvent>? _unreadChatsSub;
  StreamSubscription<DatabaseEvent>? _appControlSub;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    _initTenantScope();
    Future.microtask(() {
      _checkBatteryOptimization();
      _requestOverlayPermission();
    });
  }

  Future<void> _checkBatteryOptimization() async {
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _requestOverlayPermission() async {
    final status = await Permission.systemAlertWindow.status;
    if (!status.isGranted) {
      await Permission.systemAlertWindow.request();
    }
  }

  Future<void> _initTenantScope() async {
    await CityScopeService.ensureLoaded();
    if (!mounted) return;
    _loadOrders();
    _setupRealTimeListeners();
    _loadAppControl();
  }

  void _loadAppControl() {
    _appControlSub?.cancel();
    try {
      _appControlSub = _database
          .child(_tenantPath('settings/app-control'))
          .onValue
          .listen((event) {
        if (!mounted) return;
        if (event.snapshot.exists && event.snapshot.value is Map) {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          final raw = data['maxActiveOrdersPerRider'];
          int val = 3;
          if (raw is int) {
            val = raw;
          } else if (raw != null) {
            val = int.tryParse(raw.toString()) ?? 3;
          }
          if (val == _maxActiveOrdersPerRider) return;
          setState(() {
            _maxActiveOrdersPerRider = val;
          });
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _loadOrdersDebounce?.cancel();
    _shopOrdersSub?.cancel();
    _unreadChatsSub?.cancel();
    _appControlSub?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _setupRealTimeListeners() {
    _shopOrdersSub?.cancel();
    _unreadChatsSub?.cancel();

    // Full-tree onValue + reload is the reliable path: indexed queries can
    // intermittently return empty on the Postgres backend, which is what made
    // rider orders show up only sometimes. A single subtree read always
    // returns the complete, correct set of orders.
    _shopOrdersSub = _database
        .child(_tenantPath('shop-orders'))
        .onValue
        .listen((_) => _scheduleLoadOrders());
    _unreadChatsSub = _database
        .child(_tenantPath('rider_chats'))
        .onValue
        .listen((event) => _updateUnreadChats(event.snapshot));
  }

  void _scheduleLoadOrders() {
    _loadOrdersDebounce?.cancel();
    // Short debounce so new orders and status changes surface almost instantly
    // while still coalescing rapid bursts of realtime events.
    _loadOrdersDebounce = Timer(const Duration(milliseconds: 60), () {
      if (mounted) _loadOrders();
    });
  }

  /// Immediately reflects a status change in the UI so cards move between the
  /// New / Active / Delivered tabs instantly, without waiting for the realtime
  /// round-trip + reload.
  void _applyLocalStatus(
    String orderId,
    String newStatus, {
    String? assignedRider,
  }) {
    final idx =
        _allOrders.indexWhere((o) => (o['id'] ?? '').toString() == orderId);
    if (idx == -1) return;
    final updated = Map<String, dynamic>.from(_allOrders[idx]);
    updated['status'] = newStatus;
    if (assignedRider != null) updated['assignedRider'] = assignedRider;
    if (!mounted) return;
    final normalized = _normalizeStatus(newStatus);
    setState(() {
      if (_isTerminalStatus(normalized)) {
        // Order left the active set — drop it from the active list and keep the
        // delivered cache fresh so it shows immediately when History is opened.
        _allOrders.removeAt(idx);
        if (normalized == 'delivered' && _deliveredLoaded) {
          _deliveredOrdersList.removeWhere(
            (o) => (o['id'] ?? '').toString() == orderId,
          );
          _deliveredOrdersList.insert(0, updated);
        }
      } else {
        _allOrders[idx] = updated;
      }
    });
  }

  void _updateUnreadChats(DataSnapshot snap) {
    final unread = <String, bool>{};
    if (snap.exists && snap.value is Map) {
      final data = Map<dynamic, dynamic>.from(snap.value as Map);
      data.forEach((orderId, chatData) {
        if (chatData is! Map) return;
        final meta = chatData['meta'];
        if (meta is Map && meta['unreadByRider'] == true) {
          unread[orderId.toString()] = true;
        }
      });
    }
    if (!mounted) return;
    if (_mapsEqualBool(_unreadChatsByOrderId, unread)) return;
    setState(() => _unreadChatsByOrderId
      ..clear()
      ..addAll(unread));
  }

  bool _mapsEqualBool(Map<String, bool> a, Map<String, bool> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<void> _loadOrders() async {
    try {
      final riderId = _auth.currentUser?.uid ?? '';
      // Only active orders (New + Active tabs). Delivered history loads lazily.
      final orders = await RiderOrdersLoader.fetchActiveOrders(riderId);

      if (mounted) {
        setState(() {
          _allOrders = orders;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onTabChanged() {
    // Delivered tab (index 2): load history on first open only.
    if (_tabController.index == 2 && !_deliveredLoaded && !_deliveredLoading) {
      _loadDeliveredOrders();
    }
  }

  Future<void> _loadDeliveredOrders() async {
    if (_deliveredLoading) return;
    _deliveredLoading = true;
    if (mounted) setState(() {});
    try {
      final riderId = _auth.currentUser?.uid ?? '';
      final orders = await RiderOrdersLoader.fetchDeliveredOrders(riderId);
      if (mounted) {
        setState(() {
          _deliveredOrdersList = orders;
          _deliveredLoaded = true;
        });
      }
    } catch (_) {
      // keep whatever we had; the tab shows a retry via pull-to-refresh
    } finally {
      _deliveredLoading = false;
      if (mounted) setState(() {});
    }
  }

  String _normalizeStatus(dynamic rawStatus) {
    final status = (rawStatus ?? 'pending').toString().toLowerCase().trim();
    if (status == 'on_way' || status == 'out_for_delivery') {
      return 'on_the_way';
    }
    if (status == 'confirmed' || status == 'preparing') {
      return 'available';
    }
    return status;
  }

  bool _isTerminalStatus(String status) {
    return status == 'delivered' ||
        status == 'cancelled' ||
        status == 'canceled';
  }

  int _localActiveOrderCountForRider(String riderId) {
    var count = 0;
    for (final order in _allOrders) {
      final status = _normalizeStatus(order['status']);
      if (status != 'picked' && status != 'on_the_way') continue;
      if ((order['assignedRider'] ?? '').toString().trim() == riderId) {
        count++;
      }
    }
    return count;
  }

  /// Capacity check using the already-loaded active orders (in memory), so a
  /// pickup can be reflected instantly without a network round-trip. The pickup
  /// transaction still guards against races on the server side.
  bool _hasPickupCapacity(String riderId) {
    return _localActiveOrderCountForRider(riderId) < _maxActiveOrdersPerRider;
  }

  void _showStatusSnack(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color ?? _primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── Filtered lists ──

  List<Map<String, dynamic>> get _newOrders {
    var list = _allOrders.where((o) {
      final status = _normalizeStatus(o['status']);
      if (_isTerminalStatus(status)) return false;

      if (status == 'available') return true;

      // Recovery guard: if an older record is marked picked but has no rider,
      // surface it in New so someone can claim it.
      if (status == 'picked') {
        final assignedRider = (o['assignedRider'] ?? '').toString().trim();
        return assignedRider.isEmpty;
      }

      return false;
    }).toList();

    if (_searchNew.isNotEmpty) {
      final q = _searchNew.toLowerCase();
      list = list.where((o) => _matchesSearch(o, q)).toList();
    }
    return list;
  }

  List<Map<String, dynamic>> get _activeOrders {
    final riderId = _auth.currentUser?.uid ?? '';
    var list = _allOrders.where((o) {
      final status = _normalizeStatus(o['status']);
      if (_isTerminalStatus(status)) return false;

      if (!(status == 'picked' || status == 'on_the_way')) return false;
      final assignedRider = (o['assignedRider'] ?? '').toString().trim();
      return riderId.isNotEmpty && assignedRider == riderId;
    }).toList();
    if (_searchActive.isNotEmpty) {
      final q = _searchActive.toLowerCase();
      list = list.where((o) => _matchesSearch(o, q)).toList();
    }
    return list;
  }

  List<Map<String, dynamic>> get _deliveredOrders {
    final riderId = _auth.currentUser?.uid ?? '';
    var list = _deliveredOrdersList
        .where(
          (o) =>
              _normalizeStatus(o['status']) == 'delivered' &&
              riderId.isNotEmpty &&
              (o['assignedRider'] ?? '').toString().trim() == riderId,
        )
        .toList();
    final now = DateTime.now();
    final DateTime startDate;
    final DateTime endDate;
    if (_deliveredDateRange != null) {
      startDate = DateTime(
        _deliveredDateRange!.start.year,
        _deliveredDateRange!.start.month,
        _deliveredDateRange!.start.day,
      );
      endDate = DateTime(
        _deliveredDateRange!.end.year,
        _deliveredDateRange!.end.month,
        _deliveredDateRange!.end.day,
        23,
        59,
        59,
        999,
      );
    } else {
      startDate = DateTime(now.year, now.month, now.day);
      endDate = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
    }
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
    if (_searchDelivered.isNotEmpty) {
      final q = _searchDelivered.toLowerCase();
      list = list.where((o) => _matchesSearch(o, q)).toList();
    }
    return list;
  }

  bool _matchesSearch(Map<String, dynamic> o, String q) {
    return (o['shopName'] ?? '').toString().toLowerCase().contains(q) ||
        (o['userName'] ?? '').toString().toLowerCase().contains(q) ||
        (o['userEmail'] ?? '').toString().toLowerCase().contains(q) ||
        (o['id'] ?? '').toString().toLowerCase().contains(q) ||
        (o['contact'] ?? '').toString().toLowerCase().contains(q) ||
        (o['userPhone'] ?? '').toString().toLowerCase().contains(q) ||
        (o['whatYouWant'] ?? '').toString().toLowerCase().contains(q) ||
        (o['shop'] ?? '').toString().toLowerCase().contains(q) ||
        (o['address'] ?? '').toString().toLowerCase().contains(q) ||
        (o['manualAddress'] ?? '').toString().toLowerCase().contains(q);
  }

  List<Map<String, dynamic>> _extractOrderItems(Map<String, dynamic> order) {
    final result = <Map<String, dynamic>>[];
    final rawItems = order['items'];
    if (rawItems is! List) return result;
    for (final item in rawItems) {
      if (item is Map) {
        result.add(Map<String, dynamic>.from(item));
      }
    }
    return result;
  }

  List<String> _extractOrderShopNames(
    Map<String, dynamic> order, {
    List<Map<String, dynamic>>? items,
  }) {
    final names = <String>{};

    void addName(dynamic raw) {
      final value = (raw ?? '').toString().trim();
      if (value.isEmpty) return;
      final key = value.toLowerCase();
      if (key == 'shop order' || key == 'custom order' || key == 'n/a') return;
      names.add(value);
    }

    addName(order['shopName']);
    addName(order['shop']);

    final itemList = items ?? _extractOrderItems(order);
    for (final item in itemList) {
      addName(item['shopName']);
    }

    return names.toList();
  }

  // ── Status update with rider assignment ──

  double _orderPaymentAmount(Map<String, dynamic> order) {
    final grand = order['grandTotal'] ?? order['budget'] ?? 0;
    if (grand is num) return grand.toDouble();
    return double.tryParse(grand.toString()) ?? 0;
  }

  Future<_RiderDeliveryPayment?> _promptDeliveryPayment(
    Map<String, dynamic> order,
  ) async {
    final defaultAmount = _orderPaymentAmount(order);
    final amountCtrl = TextEditingController(
      text: defaultAmount.toStringAsFixed(0),
    );
    var paymentType = 'cash';

    final result = await showDialog<_RiderDeliveryPayment>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Confirm Delivery & Payment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Order Payment (Rs.)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    prefixText: 'Rs. ',
                    border: OutlineInputBorder(),
                    hintText: 'Order total payment',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Payment received as',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('Cash'),
                        selected: paymentType == 'cash',
                        onSelected: (_) =>
                            setS(() => paymentType = 'cash'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('Online'),
                        selected: paymentType == 'online',
                        onSelected: (_) =>
                            setS(() => paymentType = 'online'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter the amount you collected from customer. You can edit if different from order total.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final collected =
                    double.tryParse(amountCtrl.text.trim()) ?? defaultAmount;
                Navigator.pop(
                  ctx,
                  _RiderDeliveryPayment(
                    paymentType: paymentType,
                    orderPaymentAmount: defaultAmount,
                    riderCollectedAmount: collected,
                  ),
                );
              },
              child: const Text('Mark Delivered'),
            ),
          ],
        ),
      ),
    );
    amountCtrl.dispose();
    return result;
  }

  Future<void> _confirmDelivered(Map<String, dynamic> order) async {
    final payment = await _promptDeliveryPayment(order);
    if (payment == null) return;
    await _updateStatus(
      order['id'].toString(),
      (order['orderType'] ?? 'shop').toString(),
      'delivered',
      deliveryPayment: payment,
    );
  }

  void _openOrderChat(Map<String, dynamic> order) {
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return;
    if (_unreadChatsByOrderId[orderId] == true) {
      setState(() => _unreadChatsByOrderId[orderId] = false);
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserChatPage(
          orderId: orderId,
          orderType: (order['orderType'] ?? order['type'] ?? '').toString(),
          orderCode: (order['customOrderId'] ?? order['id'] ?? '').toString(),
          isRiderChat: true,
          isRiderMode: true,
          riderName: (order['userName'] ?? 'Customer').toString(),
        ),
      ),
    );
  }

  Widget _buildOrderChatButton(Map<String, dynamic> order) {
    final rawId = (order['id'] ?? '').toString();
    final hasUnread = _unreadChatsByOrderId[rawId] == true;
    return GestureDetector(
      onTap: () => _openOrderChat(order),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.25)),
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 18,
              color: Colors.blue,
            ),
          ),
          if (hasUnread)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: _cardBg, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _updateStatus(
    String orderId,
    String type,
    String newStatus, {
    _RiderDeliveryPayment? deliveryPayment,
  }) async {
    try {
      final normalizedStatus = _normalizeStatus(newStatus);
      final path = _tenantPath(
        type == 'custom' ? 'custom-orders' : 'shop-orders',
      );
      final uid = _auth.currentUser?.uid;
      if (uid == null) {
        _showStatusSnack('Please sign in again', color: Colors.red);
        return;
      }

      final orderRef = _database.child(path).child(orderId);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      var rejectionReason = '';
      String riderName = '';
      String riderPhone = '';
      String customerUserId = '';
      String customerOrderCode = '';
      String customerShopName = '';

      // For pickup: check capacity (in-memory, instant) and move the card from
      // New → Active immediately, BEFORE any network call, so the rider gets an
      // instant response. The transaction below confirms the claim server-side.
      if (normalizedStatus == 'picked') {
        if (!_hasPickupCapacity(uid)) {
          _showStatusSnack(
            'You already have $_maxActiveOrdersPerRider active orders. Deliver one before picking another.',
            color: Colors.red,
          );
          return;
        }
        _applyLocalStatus(orderId, 'picked', assignedRider: uid);
      }

      if (normalizedStatus == 'picked' ||
          normalizedStatus == 'on_the_way' ||
          normalizedStatus == 'delivered') {
        try {
          final riderSnap = await _database.child('users/$uid').get();
          if (riderSnap.exists && riderSnap.value is Map) {
            final riderData = Map<String, dynamic>.from(riderSnap.value as Map);
            riderName = (riderData['name'] ?? riderData['displayName'] ?? '')
                .toString()
                .trim();
            riderPhone = (riderData['phoneNumber'] ?? riderData['phone'] ?? '')
                .toString()
                .trim();
          }
        } catch (_) {
          // Keep rider metadata optional and proceed with status update.
        }
      }

      if (normalizedStatus == 'picked') {
        final tx = await orderRef.runTransaction((current) {
          if (current is! Map) {
            rejectionReason = 'Order not found.';
            return Transaction.abort();
          }

          final data = Map<String, dynamic>.from(current);
          final currentStatus = _normalizeStatus(data['status']);
          final assignedRider = (data['assignedRider'] ?? '').toString().trim();
          customerUserId = (data['userId'] ?? '').toString().trim();
          customerOrderCode = (data['customOrderId'] ?? orderId).toString().trim();
          customerShopName = (data['shopName'] ?? data['shop'] ?? '').toString().trim();

          final alreadyMine =
              (currentStatus == 'picked' || currentStatus == 'on_the_way') &&
              assignedRider == uid;
          final claimable = currentStatus == 'available';

          if (!claimable && !alreadyMine) {
            rejectionReason = currentStatus == 'pending'
                ? 'Order is not available for pickup yet.'
                : 'Another rider already picked this order.';
            return Transaction.abort();
          }

          if (assignedRider.isNotEmpty && assignedRider != uid) {
            rejectionReason = 'Another rider already picked this order.';
            return Transaction.abort();
          }

          data['status'] = 'picked';
          data['assignedRider'] = uid;
          if (riderName.isNotEmpty) {
            data['assignedRiderName'] = riderName;
          }
          if (riderPhone.isNotEmpty) {
            data['assignedRiderPhone'] = riderPhone;
          }
          data['pickedAt'] ??= nowMs;
          data['riderPickedAt'] = nowMs;
          data['updatedAt'] = nowMs;
          return Transaction.success(data);
        });

        if (!tx.committed) {
          // Revert the optimistic move back into the New pool.
          _applyLocalStatus(orderId, 'available', assignedRider: '');
          _showStatusSnack(
            rejectionReason.isEmpty
                ? 'Unable to pick this order right now.'
                : rejectionReason,
            color: Colors.red,
          );
          return;
        }

        _applyLocalStatus(orderId, 'picked', assignedRider: uid);

        _showStatusSnack(
          'Order picked successfully',
          color: _statusColor('picked'),
        );

        if (customerUserId.isNotEmpty) {
          unawaited(
            NotificationService.sendOrderStatusNotification(
              targetUserId: customerUserId,
              status: 'picked',
              orderId: orderId,
              orderCode: customerOrderCode,
              shopName: customerShopName,
            ).catchError((_) => {}),
          );
        }
        return;
      }

      if (normalizedStatus == 'on_the_way' || normalizedStatus == 'delivered') {
        final allowedCurrent = normalizedStatus == 'on_the_way'
            ? <String>{'picked'}
            : <String>{'on_the_way'};

        final tx = await orderRef.runTransaction((current) {
          if (current is! Map) {
            rejectionReason = 'Order not found.';
            return Transaction.abort();
          }

          final data = Map<String, dynamic>.from(current);
          final currentStatus = _normalizeStatus(data['status']);
          final assignedRider = (data['assignedRider'] ?? '').toString().trim();

          if (assignedRider.isNotEmpty && assignedRider != uid) {
            rejectionReason = 'This order is assigned to another rider.';
            return Transaction.abort();
          }
          if (assignedRider.isEmpty) {
            rejectionReason = 'Pick this order first.';
            return Transaction.abort();
          }

          if (currentStatus == normalizedStatus) {
            data['updatedAt'] = nowMs;
            return Transaction.success(data);
          }

          if (!allowedCurrent.contains(currentStatus)) {
            rejectionReason =
                'Order status changed. Please refresh and try again.';
            return Transaction.abort();
          }

          customerUserId = (data['userId'] ?? '').toString().trim();
          customerOrderCode = (data['customOrderId'] ?? orderId).toString().trim();
          customerShopName = (data['shopName'] ?? data['shop'] ?? '').toString().trim();

          data['assignedRider'] = uid;
          if (riderName.isNotEmpty) {
            data['assignedRiderName'] = riderName;
          }
          if (riderPhone.isNotEmpty) {
            data['assignedRiderPhone'] = riderPhone;
          }
          data['status'] = normalizedStatus;
          data['updatedAt'] = nowMs;
          if (normalizedStatus == 'on_the_way') {
            data['onTheWayAt'] = nowMs;
          }
          if (normalizedStatus == 'delivered') {
            data['deliveredAt'] = nowMs;
            if (deliveryPayment != null) {
              data['riderPaymentType'] = deliveryPayment.paymentType;
              data['orderPaymentAmount'] = deliveryPayment.orderPaymentAmount;
              data['riderCollectedAmount'] =
                  deliveryPayment.riderCollectedAmount;
              data['paymentDifference'] =
                  deliveryPayment.riderCollectedAmount -
                  deliveryPayment.orderPaymentAmount;
            }
          }
          return Transaction.success(data);
        });

        if (!tx.committed) {
          _showStatusSnack(
            rejectionReason.isEmpty
                ? 'Unable to update status right now.'
                : rejectionReason,
            color: Colors.red,
          );
          return;
        }

        _applyLocalStatus(orderId, normalizedStatus, assignedRider: uid);

        _showStatusSnack(
          'Status updated to ${_formatStatus(normalizedStatus)}',
          color: _statusColor(normalizedStatus),
        );

        if (customerUserId.isNotEmpty) {
          unawaited(
            NotificationService.sendOrderStatusNotification(
              targetUserId: customerUserId,
              status: normalizedStatus,
              orderId: orderId,
              orderCode: customerOrderCode,
              shopName: customerShopName,
            ).catchError((_) => {}),
          );
        }
        return;
      }

      await orderRef.update({
        'status': normalizedStatus,
        'updatedAt': ServerValue.timestamp,
      });
      _applyLocalStatus(orderId, normalizedStatus);
      _showStatusSnack(
        'Status updated to ${_formatStatus(normalizedStatus)}',
        color: _statusColor(normalizedStatus),
      );
    } catch (e) {
      _showStatusSnack('Error: $e', color: Colors.red);
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

  void _navigateToCustomer(Map<String, dynamic> order) {
    final lat = order['autoLatitude'] ?? order['latitude'];
    final lng = order['autoLongitude'] ?? order['longitude'];
    if (lat != null && lng != null) {
      launchUrl(
        Uri.parse('google.navigation:q=$lat,$lng&mode=d'),
        mode: LaunchMode.externalApplication,
      );
    } else if (order['address'] != null &&
        order['address'].toString().isNotEmpty) {
      final encoded = Uri.encodeComponent(order['address'].toString());
      launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded'),
        mode: LaunchMode.externalApplication,
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

  Future<Map<String, String>> _getRiderCancelDetails() async {
    String riderName = 'Rider';
    String riderEmail = '';
    String riderUid = '';

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        riderUid = user.uid;
        riderEmail = user.email ?? '';
        riderName = user.displayName ?? '';
        
        final snap = await FirebaseDatabase.instance.ref('users/${user.uid}').get();
        if (snap.exists && snap.value is Map) {
          final data = Map<String, dynamic>.from(snap.value as Map);
          if (riderName.isEmpty) {
            riderName = (data['name'] ?? '').toString().trim();
          }
          if (riderEmail.isEmpty) {
            riderEmail = (data['email'] ?? '').toString().trim();
          }
          if (riderEmail.isEmpty) {
            riderEmail = (data['phoneNumber'] ?? '').toString().trim();
          }
        }
        
        if (riderName.isEmpty) {
          riderName = riderEmail;
        }
        if (riderName.isEmpty) {
          riderName = 'Rider';
        }
      }
    } catch (_) {}
    
    return {
      'name': riderName,
      'email': riderEmail,
      'uid': riderUid,
    };
  }

  Future<void> _cancelOrderWithReason(Map<String, dynamic> order) async {
    final reasons = [
      'Customer not reachable',
      'Address issue',
      'Order issue from shop',
      'Unable to deliver',
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
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel Order'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;

    final orderId = (order['id'] ?? '').toString();
    final type = (order['orderType'] ?? 'shop').toString();
    if (orderId.isEmpty) return;

    final path = _tenantPath(
      type == 'custom' ? 'custom-orders' : 'shop-orders',
    );
    final details = await _getRiderCancelDetails();
    final uid = details['uid'];
    final riderName = details['name'];
    final riderEmail = details['email'];

    final reason = customCtrl.text.trim().isNotEmpty
        ? '$selected: ${customCtrl.text.trim()}'
        : selected;

    await _database.child(path).child(orderId).update({
      'status': 'cancelled',
      'cancelReason': reason,
      'cancelledAt': DateTime.now().millisecondsSinceEpoch,
      'cancelledByRole': 'rider',
      'cancelledByName': riderName,
      'cancelledByEmail': riderEmail,
      'cancelledByUid': uid,
      'updatedAt': ServerValue.timestamp,
    });

    _showStatusSnack('Order cancelled', color: Colors.red);
  }

  // ── Helpers ──

  Color _statusColor(String status) {
    switch (_normalizeStatus(status)) {
      case 'pending':
        return const Color(0xFFF59E0B);
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
    switch (_normalizeStatus(status)) {
      case 'pending':
        return Icons.access_time_rounded;
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

  String _formatStatus(String s) => _normalizeStatus(s)
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

  // ── BUILD ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        titleSpacing: 16,
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
        ],
        bottom: TabBar(
          controller: _tabController,
          onTap: (_) => setState(() {}),
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fiber_new_rounded, size: 18),
                  const SizedBox(width: 6),
                  const Text('New'),
                  if (_newOrders.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_newOrders.length}',
                        style: const TextStyle(fontSize: 11),
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
                  const Icon(Icons.pending_actions_rounded, size: 18),
                  const SizedBox(width: 6),
                  const Text('Active'),
                  if (_activeOrders.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_activeOrders.length}',
                        style: const TextStyle(fontSize: 11),
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
                  const Icon(Icons.check_circle_outline_rounded, size: 18),
                  const SizedBox(width: 6),
                  const Text('Delivered'),
                  if (_deliveredOrders.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_deliveredOrders.length}',
                        style: const TextStyle(fontSize: 11),
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
                _buildNewTab(),
                _buildActiveTab(),
                _buildDeliveredTab(),
              ],
            ),
    );
  }

  // ── NEW TAB ──

  Widget _buildNewTab() {
    final orders = _newOrders;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          color: _cardBg,
          child: TextField(
            onChanged: (v) => setState(() => _searchNew = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search new orders...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: Colors.grey[400],
                size: 18,
              ),
              filled: true,
              fillColor: _surfaceVariant,
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
              ? _buildEmpty('No new orders')
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

  // ── ACTIVE TAB ──

  Widget _buildActiveTab() {
    final orders = _activeOrders;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          color: _cardBg,
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
              fillColor: _surfaceVariant,
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

  // ── DELIVERED TAB ──

  Widget _buildDeliveredTab() {
    final orders = _deliveredOrders;
    final isToday = _deliveredDateRange == null;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          color: _cardBg,
          child: Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 16, color: _primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isToday
                      ? "Today's Deliveries"
                      : '${_formatDateShort(_deliveredDateRange!.start)} - ${_formatDateShort(_deliveredDateRange!.end)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isToday ? _textPrimary : _primary,
                  ),
                ),
              ),
              if (!isToday)
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
          color: _cardBg,
          child: TextField(
            onChanged: (v) => setState(() => _searchDelivered = v),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search delivered orders...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: Colors.grey[400],
                size: 18,
              ),
              filled: true,
              fillColor: _surfaceVariant,
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
                          isToday
                              ? 'No deliveries today'
                              : 'No deliveries in selected range',
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

  Widget _buildEmpty(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: Colors.cyan[50],
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.delivery_dining_outlined,
              size: 40,
              color: Colors.cyan[200],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _textPrimary,
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

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final status = (order['status'] ?? 'pending').toString();
    final statusC = _statusColor(status);
    final isCustom = order['orderType'] == 'custom';
    final isInstant = InstantDeliveryService.isInstantOrder(order);
    final fallbackShopTitle =
        (isCustom
                ? (order['shop'] ?? 'Custom Order')
                : (order['shopName'] ?? 'Shop Order'))
            .toString();
    final itemList = _extractOrderItems(order);
    final orderShopNames = _extractOrderShopNames(order, items: itemList);
    final isMultiShopOrder =
        !isCustom &&
        (orderShopNames.length > 1 || order['isMultiShopOrder'] == true);
    final shopName = isCustom
        ? fallbackShopTitle
        : isMultiShopOrder
        ? 'Multi-shop Order'
        : (orderShopNames.isNotEmpty
              ? orderShopNames.first
              : fallbackShopTitle);
    final customer = order['userName'] ?? order['userEmail'] ?? 'Unknown';
    final contact = (order['contact']?.toString() ?? '').isNotEmpty
        ? order['contact'].toString()
        : (order['userPhone']?.toString() ?? '');
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final rawId = (order['id'] ?? '').toString();
    final shortId = rawId.length >= 8
        ? rawId.substring(0, 8).toUpperCase()
        : rawId.toUpperCase();

    String itemsText = '';
    if (itemList.isNotEmpty) {
      itemsText = itemList
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
                order['manualAddress'] ??
                '')
            .toString()
            .trim();

    return GestureDetector(
      onTap: () => _showOrderDetails(order),
      child: Container(
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
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
                  // ── Row 1: Shop name + Message + Price ──
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          shopName,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: _textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildOrderChatButton(order),
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
                  const SizedBox(height: 4),
                  // ── Row 2: Order ID (long press copy) + time + status chip + type badge ──
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
                    ],
                  ),
                  const SizedBox(height: 8),
                  Divider(height: 1, color: _dividerColor),
                  const SizedBox(height: 8),
                  if (isMultiShopOrder && orderShopNames.isNotEmpty) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.storefront_outlined,
                          size: 14,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'Shops: ${orderShopNames.join(' • ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
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
                          onTap: () => launchUrl(Uri.parse('tel:$contact')),
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
                  // ── Address ──
                  if (displayAddress.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(width: 5),
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
                  if (status.toLowerCase() == 'cancelled' ||
                      status.toLowerCase() == 'canceled' ||
                      status.toLowerCase() == 'rejected') ...[
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
                                status.toLowerCase() == 'rejected' ? 'Rejected Details' : 'Cancellation Details',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.red[700],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if ((order['cancelReason'] ?? '').toString().isNotEmpty)
                            Text(
                              'Reason: ${order['cancelReason']}',
                              style: TextStyle(fontSize: 11, color: Colors.red[700], fontWeight: FontWeight.w500),
                            ),
                          if (order['cancelledByRole'] != null || order['cancelledByName'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                'Cancelled By: ${order['cancelledByName'] ?? 'Unknown'} (${order['cancelledByRole'] ?? order['cancelledBy'] ?? 'Unknown'})',
                                style: TextStyle(fontSize: 11, color: Colors.red[700], fontWeight: FontWeight.w500),
                              ),
                            ),
                          if (order['cancelledByEmail'] != null && order['cancelledByEmail'].toString().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                'Email: ${order['cancelledByEmail']}',
                                style: TextStyle(fontSize: 11, color: Colors.red[700], fontWeight: FontWeight.w500),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  // ── Quick Actions ──
                  _buildQuickActions(order, status),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions(Map<String, dynamic> order, String status) {
    final st = _normalizeStatus(status);
    final assignedRider = (order['assignedRider'] ?? '').toString().trim();
    final riderId = _auth.currentUser?.uid ?? '';
    final localActiveCount = riderId.isEmpty
        ? 0
        : _localActiveOrderCountForRider(riderId);
    final canPickMore = localActiveCount < _maxActiveOrdersPerRider;
    List<Widget> actions = [];

    if (st == 'available' || (st == 'picked' && assignedRider.isEmpty)) {
      actions = [
        _actionBtn(
          canPickMore ? 'Pick Order' : 'Limit Reached',
          Icons.backpack_rounded,
          canPickMore ? const Color(0xFF8B5CF6) : Colors.grey,
          () {
            if (!canPickMore) {
              _showStatusSnack(
                'You already have $_maxActiveOrdersPerRider active orders.',
                color: Colors.red,
              );
              return;
            }
            _updateStatus(order['id'], order['orderType'], 'picked');
          },
        ),
      ];
    } else if (st == 'picked') {
      actions = [
        _actionBtn(
          'Start Delivery',
          Icons.local_shipping_rounded,
          const Color(0xFF06B6D4),
          () => _updateStatus(order['id'], order['orderType'], 'on_the_way'),
        ),
      ];
    } else if (st == 'on_the_way') {
      actions = [
        _actionBtn(
          'Delivered',
          Icons.check_circle_rounded,
          const Color(0xFF22C55E),
          () => _confirmDelivered(order),
        ),
      ];
    }

    // Navigate button for orders with location
    if (order['autoLatitude'] != null ||
        order['latitude'] != null ||
        (order['address'] ?? '').toString().isNotEmpty) {
      actions.add(
        _actionBtn(
          'Navigate',
          Icons.navigation_rounded,
          Colors.blue,
          () => _navigateToCustomer(order),
        ),
      );
    }

    actions.add(
      _actionBtn(
        'Details',
        Icons.info_outline_rounded,
        _primary,
        () => _showOrderDetails(order),
      ),
    );

    if (!(st == 'delivered' || st == 'cancelled' || st == 'canceled')) {
      actions.add(
        _actionBtn(
          'Cancel',
          Icons.cancel_rounded,
          Colors.red,
          () => _cancelOrderWithReason(order),
        ),
      );
    }

    return Row(
      children: actions
          .map(
            (w) => Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: w,
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _actionBtn(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOrderDetails(Map<String, dynamic> order) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RiderOrderDetailSheet(
        order: order,
        isDark: widget.isDark,
        onUpdateStatus: _updateStatus,
        onConfirmDelivered: _confirmDelivered,
        onCancelOrder: _cancelOrderWithReason,
        onCopyOrderId: _copyOrderId,
        onNavigate: _navigateToCustomer,
        statusColor: _statusColor,
        formatStatus: _formatStatus,
        formatFull: _formatFull,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RIDER ORDER DETAIL BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _RiderOrderDetailSheet extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool isDark;
  final Future<void> Function(String, String, String) onUpdateStatus;
  final Future<void> Function(Map<String, dynamic>) onConfirmDelivered;
  final Future<void> Function(Map<String, dynamic>) onCancelOrder;
  final void Function(String) onCopyOrderId;
  final void Function(Map<String, dynamic>) onNavigate;
  final Color Function(String) statusColor;
  final String Function(String) formatStatus;
  final String Function(dynamic) formatFull;

  const _RiderOrderDetailSheet({
    required this.order,
    this.isDark = false,
    required this.onUpdateStatus,
    required this.onConfirmDelivered,
    required this.onCancelOrder,
    required this.onCopyOrderId,
    required this.onNavigate,
    required this.statusColor,
    required this.formatStatus,
    required this.formatFull,
  });

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

  @override
  Widget build(BuildContext context) {
    final status = (order['status'] ?? 'pending').toString();
    var normalizedStatus = status.toLowerCase().trim();
    if (normalizedStatus == 'on_way' ||
        normalizedStatus == 'out_for_delivery') {
      normalizedStatus = 'on_the_way';
    }
    if (normalizedStatus == 'confirmed' || normalizedStatus == 'preparing') {
      normalizedStatus = 'available';
    }
    final sc = statusColor(status);
    final isCustom = order['orderType'] == 'custom';
    final isInstant = InstantDeliveryService.isInstantOrder(order);
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final rawId = (order['id'] ?? '').toString();
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
            .toString()
            .trim()
            .isEmpty
        ? (isCustom ? 'Custom Order' : 'Shop Order')
        : (isCustom
                  ? (order['shop'] ?? 'Custom Order')
                  : (order['shopName'] ?? 'Shop Order'))
              .toString()
              .trim();

    final groupedShopItems = <String, List<Map<String, dynamic>>>{};
    final groupedShopNames = <String, String>{};
    final uniqueShopNames = <String>{};

    void addShopName(dynamic raw) {
      final value = (raw ?? '').toString().trim();
      if (value.isEmpty) return;
      final key = value.toLowerCase();
      if (key == 'shop order' || key == 'custom order' || key == 'n/a') return;
      uniqueShopNames.add(value);
    }

    addShopName(order['shopName']);
    addShopName(order['shop']);

    for (final item in items) {
      final itemShopId = (item['shopId'] ?? '').toString().trim();
      final rawItemShopName = (item['shopName'] ?? '').toString().trim();
      final itemShopName = rawItemShopName.isEmpty
          ? fallbackShopName
          : rawItemShopName;
      addShopName(itemShopName);
      final groupKey = itemShopId.isNotEmpty
          ? 'id:$itemShopId'
          : 'name:${itemShopName.toLowerCase()}';
      groupedShopNames[groupKey] = itemShopName;
      groupedShopItems
          .putIfAbsent(groupKey, () => <Map<String, dynamic>>[])
          .add(item);
    }

    if (groupedShopItems.isEmpty && items.isNotEmpty) {
      final fallbackKey = 'name:${fallbackShopName.toLowerCase()}';
      groupedShopNames[fallbackKey] = fallbackShopName;
      groupedShopItems[fallbackKey] = List<Map<String, dynamic>>.from(items);
      addShopName(fallbackShopName);
    }

    final shopNames = uniqueShopNames.toList();
    final isMultiShopOrder =
        !isCustom &&
        (shopNames.length > 1 ||
            groupedShopItems.length > 1 ||
            order['isMultiShopOrder'] == true);

    final primaryAddress = _pickFirstNonEmpty([
      (order['fullAddress'] ?? '').toString(),
      (order['address'] ?? '').toString(),
      (order['manualAddress'] ?? '').toString(),
      (order['autoAddressFormatted'] ?? '').toString(),
      (order['autoAddress'] ?? '').toString(),
    ]);
    final liveAddress = _pickFirstNonEmpty([
      (order['autoAddressFormatted'] ?? '').toString(),
      (order['autoAddress'] ?? '').toString(),
    ]);
    final manualAddress = (order['manualAddress'] ?? '').toString().trim();
    final address2 = (order['address2'] ?? '').toString().trim();
    final deliveryInstructions = _pickFirstNonEmpty([
      (order['deliveryInstructions'] ?? '').toString(),
      (order['specialInstructions'] ?? '').toString(),
      (order['specialNotes'] ?? '').toString(),
    ]);

    final parsedFromAddress2 = _parseHostelRoom(address2);
    final parsedFallback = _parseHostelRoom(
      _pickFirstNonEmpty([primaryAddress, manualAddress, liveAddress]),
    );

    final hostel = _pickFirstNonEmpty([
      (order['hostelNo'] ?? '').toString(),
      (order['hostel'] ?? '').toString(),
      (order['hostelNumber'] ?? '').toString(),
      parsedFromAddress2['hostel'] ?? '',
      parsedFallback['hostel'] ?? '',
    ]);
    final room = _pickFirstNonEmpty([
      (order['roomNo'] ?? '').toString(),
      (order['room'] ?? '').toString(),
      (order['roomNumber'] ?? '').toString(),
      parsedFromAddress2['room'] ?? '',
      parsedFallback['room'] ?? '',
    ]);
    final hasAddressDetails =
        primaryAddress.isNotEmpty ||
        liveAddress.isNotEmpty ||
        manualAddress.isNotEmpty ||
        address2.isNotEmpty ||
        hostel.isNotEmpty ||
        room.isNotEmpty ||
        deliveryInstructions.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey[300],
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
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF1A1A1A),
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
                  // ── Navigate to Customer (prominent button) ──
                  if (order['autoLatitude'] != null ||
                      order['latitude'] != null ||
                      (order['address'] ?? '').toString().isNotEmpty) ...[
                    GestureDetector(
                      onTap: () => onNavigate(order),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF06B6D4), Color(0xFF0891B2)],
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.navigation_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Navigate to Customer',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],

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
                      onTap: () {
                        try {
                          launchUrl(
                            Uri.parse('tel:${(order['contact'] ?? order['userPhone']).toString()}'),
                            mode: LaunchMode.externalApplication,
                          );
                        } catch (_) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Could not launch dialer')),
                          );
                        }
                      },
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
                              Icons.phone_rounded,
                              size: 16,
                              color: Colors.green[700],
                            ),
                            const SizedBox(width: 10),
                            Text(
                              (order['contact'] ?? order['userPhone'])
                                  .toString(),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.green[700],
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'Tap to call',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.green[400],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if ((order['contact'] ?? order['userPhone'] ?? '').toString().isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserChatPage(
                              orderId: (order['id'] ?? '').toString(),
                              orderType: (order['orderType'] ?? order['type'] ?? '').toString(),
                              orderCode: (order['customOrderId'] ?? order['id'] ?? '').toString(),
                              isRiderChat: true,
                              isRiderMode: true,
                              riderName: 'Customer', // The rider sees this as customer chat
                            ),
                          ),
                        );
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue[50],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.blue[200]!),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.chat_bubble_rounded,
                              size: 16,
                              color: Colors.blue[700],
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Message Customer',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.blue[700],
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'Tap to chat',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.blue[400],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  if (hasAddressDetails) ...[
                    _sectionHeader(
                      'Delivery Address',
                      Icons.location_on_rounded,
                      Colors.red,
                    ),
                    if (primaryAddress.isNotEmpty)
                      _infoTile(
                        Icons.location_on_outlined,
                        'Primary Address',
                        primaryAddress,
                      ),
                    if (address2.isNotEmpty && hostel.isEmpty && room.isEmpty)
                      _infoTile(
                        Icons.home_work_outlined,
                        'Address 2',
                        address2,
                      ),
                    if (hostel.isNotEmpty)
                      _infoTile(Icons.apartment_rounded, 'Hostel No', hostel),
                    if (room.isNotEmpty)
                      _infoTile(Icons.meeting_room_rounded, 'Room No', room),
                    if (manualAddress.isNotEmpty &&
                        manualAddress != primaryAddress)
                      _infoTile(
                        Icons.edit_location_alt_outlined,
                        'Manual Address',
                        manualAddress,
                      ),
                    if (liveAddress.isNotEmpty && liveAddress != primaryAddress)
                      _infoTile(
                        Icons.gps_fixed_rounded,
                        'Live GPS Address',
                        liveAddress,
                      ),
                    if (deliveryInstructions.isNotEmpty)
                      _infoTile(
                        Icons.info_outline_rounded,
                        'Instructions',
                        deliveryInstructions,
                      ),
                  ],

                  if (!isCustom) ...[
                    _sectionHeader(
                      isMultiShopOrder ? 'Shops' : 'Shop',
                      Icons.store_rounded,
                      const Color(0xFFFF6B00),
                    ),
                    _infoTile(
                      Icons.storefront_outlined,
                      isMultiShopOrder ? 'Shop Names' : 'Shop',
                      shopNames.isNotEmpty
                          ? shopNames.join(' • ')
                          : fallbackShopName,
                    ),
                  ],

                  if (isCustom) ...[
                    _sectionHeader(
                      'Custom Order',
                      Icons.edit_note_rounded,
                      Colors.purple,
                    ),
                    _infoTile(
                      Icons.shopping_bag_outlined,
                      'What they want',
                      order['whatYouWant'] ?? 'N/A',
                    ),
                    _infoTile(
                      Icons.store_outlined,
                      'Preferred shop',
                      order['shop'] ?? 'N/A',
                    ),
                    _infoTile(
                      Icons.attach_money,
                      'Budget',
                      'Rs. ${order['budget'] ?? 0}',
                    ),
                  ],

                  if (items.isNotEmpty) ...[
                    _sectionHeader(
                      isMultiShopOrder ? 'Shop Wise Items' : 'Order Items',
                      Icons.receipt_long_rounded,
                      Colors.blue,
                    ),
                    if (isMultiShopOrder && groupedShopItems.isNotEmpty)
                      ...groupedShopItems.entries.map((entry) {
                        final groupedItems = entry.value;
                        final groupedShopName =
                            groupedShopNames[entry.key] ?? fallbackShopName;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF253048)
                                : Colors.grey[50],
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white10
                                  : Colors.grey[200]!,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                groupedShopName,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  color: Colors.blue[700],
                                ),
                              ),
                              const SizedBox(height: 8),
                              ...groupedItems.map(
                                (item) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? Colors.blue.withValues(
                                                  alpha: 0.2,
                                                )
                                              : Colors.blue[50],
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${item['quantity'] ?? 1}×',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.blue[700],
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
                                      Text(
                                        'Rs. ${item['price'] ?? 0}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
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
                            color: isDark
                                ? const Color(0xFF253048)
                                : Colors.grey[50],
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.blue.withValues(alpha: 0.2)
                                      : Colors.blue[50],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    '${item['quantity'] ?? 1}×',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.blue[700],
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
                              Text(
                                'Rs. ${item['price'] ?? 0}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],

                  _sectionHeader(
                    'Payment',
                    Icons.payment_rounded,
                    Colors.green,
                  ),
                  _infoTile(
                    Icons.payment_outlined,
                    'Method',
                    order['paymentMethod'] ?? 'COD',
                  ),
                  if (order['subtotal'] != null)
                    _infoTile(
                      Icons.receipt_outlined,
                      'Subtotal',
                      'Rs. ${order['subtotal']}',
                    ),
                  if (order['deliveryFee'] != null)
                    _infoTile(
                      Icons.delivery_dining,
                      'Delivery Fee',
                      'Rs. ${order['deliveryFee']}',
                    ),
                  if (order['tax'] != null)
                    _infoTile(
                      Icons.percent_rounded,
                      'Tax',
                      'Rs. ${order['tax']}',
                    ),
                  if (order['extraCharge'] != null && (order['extraCharge'] is num ? order['extraCharge'] > 0 : double.tryParse(order['extraCharge'].toString()) != null && double.parse(order['extraCharge'].toString()) > 0))
                    _infoTile(
                      Icons.add_card_rounded,
                      'Extra Charges',
                      'Rs. ${order['extraCharge']}',
                    ),
                  Container(
                    margin: const EdgeInsets.only(top: 4, bottom: 8),
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
                          Icons.account_balance_wallet_rounded,
                          size: 16,
                          color: Colors.green[700],
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Grand Total',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Rs. $total',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: Colors.green[700],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),
                  _buildStatusActions(context, status),

                  if (!(normalizedStatus == 'delivered' ||
                      normalizedStatus == 'cancelled' ||
                      normalizedStatus == 'canceled')) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await onCancelOrder(order);
                          if (context.mounted) Navigator.pop(context);
                        },
                        icon: const Icon(Icons.cancel_rounded, size: 17),
                        label: const Text('Cancel Order'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => onCopyOrderId(rawId),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF253048)
                            : Colors.grey[50],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark ? Colors.white12 : Colors.grey[200]!,
                        ),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusActions(BuildContext context, String status) {
    final raw = status.toLowerCase().trim();
    String st = raw;
    if (st == 'on_way' || st == 'out_for_delivery') {
      st = 'on_the_way';
    }
    if (st == 'confirmed' || st == 'preparing') {
      st = 'available';
    }

    if (st == 'delivered' || st == 'cancelled' || st == 'canceled') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: statusColor(status).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              st == 'delivered'
                  ? Icons.check_circle_rounded
                  : Icons.cancel_rounded,
              color: statusColor(status),
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              st == 'delivered'
                  ? 'Order Delivered Successfully'
                  : 'Order Cancelled',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: statusColor(status),
              ),
            ),
          ],
        ),
      );
    }

    if (st == 'pending') {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.hourglass_top_rounded,
              color: Colors.amber,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Order is being processed. It will appear here once available for pickup.',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.amber[800],
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );
    }

    String nextLabel = '';
    String nextStatus = '';
    Color nextColor = Colors.grey;
    IconData nextIcon = Icons.arrow_forward_rounded;
    final assignedRider = (order['assignedRider'] ?? '').toString().trim();

    if (st == 'available' || (st == 'picked' && assignedRider.isEmpty)) {
      nextLabel = 'Pick Order';
      nextStatus = 'picked';
      nextColor = const Color(0xFF8B5CF6);
      nextIcon = Icons.backpack_rounded;
    } else if (st == 'picked') {
      nextLabel = 'Start Delivery';
      nextStatus = 'on_the_way';
      nextColor = const Color(0xFF06B6D4);
      nextIcon = Icons.local_shipping_rounded;
    } else if (st == 'on_the_way') {
      nextLabel = 'Mark as Delivered';
      nextStatus = 'delivered';
      nextColor = const Color(0xFF22C55E);
      nextIcon = Icons.check_circle_rounded;
    }

    if (nextStatus.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            icon: Icon(nextIcon, size: 20),
            label: Text(
              nextLabel,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: nextColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            onPressed: () {
              if (nextStatus == 'picked') {
                onUpdateStatus(order['id'], order['orderType'], nextStatus);
                Navigator.pop(context);
                return;
              }

              if (nextStatus == 'on_the_way' || nextStatus == 'delivered') {
                if (nextStatus == 'delivered') {
                  onConfirmDelivered(order).then((_) {
                    if (context.mounted) Navigator.pop(context);
                  });
                  return;
                }
                showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Start Delivery'),
                    content: const Text(
                      'Confirm you are now heading to customer?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('No'),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Yes'),
                      ),
                    ],
                  ),
                ).then((ok) {
                  if (ok == true) {
                    onUpdateStatus(order['id'], order['orderType'], nextStatus);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  }
                });
              } else {
                onUpdateStatus(order['id'], order['orderType'], nextStatus);
                Navigator.pop(context);
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoTile(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: Colors.grey[400]),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
