import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:lottie/lottie.dart';
import '../services/city_scope_service.dart';
import '../services/db/app_db_client.dart';
import '../services/instant_delivery_service.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/notification_service.dart';
import '../services/cart_service.dart';
import 'user_chat_page.dart';
import 'cart_page.dart';
import '../widgets/animated_chat_icon.dart';
import '../widgets/rating_dialog.dart';

class MyOrdersPage extends StatefulWidget {
  const MyOrdersPage({super.key});

  @override
  State<MyOrdersPage> createState() => MyOrdersPageState();
}

class MyOrdersPageState extends State<MyOrdersPage>
    with TickerProviderStateMixin {
  static const Color _primary = Color(0xFFFF6B00);
  int _highQueueThreshold = 7;
  String _queuePositionText =
      'Your order is #{position} in the queue';
  String _queueUpdatingText = 'Updating your queue position...';
  String _queueActiveOrdersText = 'Active orders: {count}';
  String _queueHighLoadText =
      'Due to high demand, delivery may take 40–50 minutes.';
  String? _queueListenerUid;
  List<Map<String, dynamic>> _queueShopActive = [];

  final _database = FirebaseDatabase.instance.ref();
  final _cartService = CartService();
  late TabController _tabController;
  late final AnimationController _chefAnimCtrl;
  late final Animation<double> _chefAnim;

  List<Map<String, dynamic>> _activeOrders = [];
  List<Map<String, dynamic>> _pastOrders = [];
  List<Map<String, dynamic>> _cancelledOrders = [];
  bool _isLoading = true;
  final Map<String, Map<String, dynamic>> _orderIndex = {};

  StreamSubscription<DatabaseEvent>? _shopOrdersSub;
  StreamSubscription<DatabaseEvent>? _historyOrdersSub;
  StreamSubscription<DatabaseEvent>? _legacyShopOrdersSub;
  StreamSubscription<DatabaseEvent>? _legacyHistoryOrdersSub;
  StreamSubscription<DatabaseEvent>? _altShopOrdersSub;
  StreamSubscription<DatabaseEvent>? _altHistoryOrdersSub;
  StreamSubscription<DatabaseEvent>? _altLegacyShopOrdersSub;
  StreamSubscription<DatabaseEvent>? _altLegacyHistoryOrdersSub;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<DatabaseEvent>? _appControlSub;
  Timer? _queuePollTimer;
  final Map<String, int> _queuePositions = {};
  final Map<String, int> _instantQueuePositions = {};
  int _queueShopCount = 0;
  int _queueInstantCount = 0;
  bool _charityEnabled = false;
  String _charityMessage = '';
  double _charityAmount = 50;
  final Set<String> _charityInFlight = {};
  final Set<String> _charityDismissed = {};
  bool _isExplicitRefreshRunning = false;
  Timer? _autoRetryTimer;
  int _autoRetryAttempts = 0;
  static const int _maxAutoRetryAttempts = 6;
  final Set<String> _cancelInFlight = {};
  Timer? _cancelTicker;
  bool _useLegacyShopOrders = false;
  bool _useLegacyHistoryOrders = false;
  bool _useAltIdentifiers = false;
  String _currentUserContact = '';
  bool _showOrderQueueInfo = true;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  bool get _isIslamabadCity =>
      CityScopeService.normalizeCity(CityScopeService.currentCity) ==
      CityScopeService.islamabad;

  bool get _shouldShowQueueInfo => _showOrderQueueInfo && _isIslamabadCity;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _chefAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _chefAnim = CurvedAnimation(parent: _chefAnimCtrl, curve: Curves.easeInOut);
    _chefAnimCtrl.repeat(reverse: true);

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      if (user == null) {
        _cancelRealtimeListeners();
        _queuePollTimer?.cancel();
        setState(() {
          _activeOrders = [];
          _pastOrders = [];
          _cancelledOrders = [];
          _isLoading = false;
        });
        return;
      }
      refreshNow(showLoader: false);
    });

    _listenAppControl();
    refreshNow(showLoader: true);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _appControlSub?.cancel();
    _queuePollTimer?.cancel();
    _cancelRealtimeListeners();
    _autoRetryTimer?.cancel();
    _cancelTicker?.cancel();
    _chefAnimCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<User?> _resolveCurrentUser() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) return current;
    try {
      return await FirebaseAuth.instance.authStateChanges().first;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadUserIdentifiers(User user) async {
    _currentUserContact = (user.phoneNumber ?? '').toString().trim();
    try {
      final snap = await _database.child('users/${user.uid}').get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final phone =
            (data['phoneNumber'] ??
                    data['phone'] ??
                    data['contact'] ??
                    data['userPhone'] ??
                    '')
                .toString()
                .trim();
        if (phone.isNotEmpty) {
          _currentUserContact = phone;
        }
      }
    } catch (_) {}
  }

  int _latestTimestampFromSnapshot(DataSnapshot snapshot) {
    if (!snapshot.exists || snapshot.value is! Map) return 0;
    final raw = snapshot.value as Map<dynamic, dynamic>;
    var latest = 0;
    raw.forEach((_, value) {
      if (value is! Map) return;
      final row = Map<String, dynamic>.from(value);
      final ts = _orderTimestamp(row);
      if (ts > latest) latest = ts;
    });
    return latest;
  }

  int _snapshotSize(DataSnapshot? snapshot) {
    if (snapshot == null) return 0;
    if (!snapshot.exists || snapshot.value is! Map) return 0;
    return (snapshot.value as Map).length;
  }

  Future<DataSnapshot?> _chatMetaSnapshot(dynamic order) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final raw = (order['id'] ?? '').toString().trim();
    final chatId = raw.isEmpty ? 'general' : raw;
    try {
      return await _database
          .child(_tenantPath('chats/${user.uid}/$chatId/meta'))
          .get();
    } catch (_) {
      return null;
    }
  }

  int _orderTimestamp(Map<String, dynamic> order) {
    final candidates = [
      order['updatedAt'],
      order['deliveredAt'],
      order['cancelledAt'],
      order['archivedAt'],
      order['onTheWayAt'],
      order['pickedAt'],
      order['availableAt'],
      order['adminApprovedAt'],
      order['merchantPendingAt'],
      order['createdAt'],
      order['createdAtClient'],
      order['createdAtMs'],
      order['timestamp'],
      order['time'],
    ];
    for (final candidate in candidates) {
      final ts = _normalizeTimestamp(candidate);
      if (ts > 0) return ts;
    }
    return 0;
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _upsertOrder({
    required String type,
    required String id,
    required dynamic raw,
    required String source,
    bool rebuild = true,
  }) {
    if (id.isEmpty || raw is! Map) return;
    final data = Map<String, dynamic>.from(raw as Map);
    final orderType = (data['orderType'] ?? data['type'] ?? type)
        .toString()
        .trim();
    final resolvedId = (data['orderId'] ?? data['id'] ?? id).toString().trim();
    if (resolvedId.isEmpty) return;

    data['id'] = resolvedId;
    data['type'] = orderType.isEmpty ? type : orderType;
    data['orderType'] = orderType.isEmpty ? type : orderType;
    data['source'] = source;
    data['recordType'] = type;
    data['status'] = (data['status'] ?? 'pending').toString();

    final key = '$type:$source:$resolvedId';
    _orderIndex[key] = data;
    if (rebuild) _rebuildOrderBuckets();
  }

  void _rebuildOrderBuckets() {
    final merged = <String, Map<String, dynamic>>{};
    for (final order in _orderIndex.values) {
      final id = (order['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final type = (order['type'] ?? order['orderType'] ?? 'shop')
          .toString()
          .trim();
      final key = '$type:$id';
      final existing = merged[key];
      if (existing == null) {
        merged[key] = order;
        continue;
      }

      final currentTs = _orderTimestamp(order);
      final existingTs = _orderTimestamp(existing);
      if (currentTs > existingTs) {
        merged[key] = order;
        continue;
      }
      if (currentTs == existingTs) {
        final existingType = (existing['recordType'] ?? '').toString();
        final currentType = (order['recordType'] ?? '').toString();
        if (existingType == 'history' && currentType != 'history') {
          merged[key] = order;
        }
      }
    }

    const delivered = {'delivered', 'completed'};
    const cancelled = {
      'cancelled',
      'canceled',
      'rejected',
      'merchant_rejected',
      'merchant_cancelled',
      'timeout',
      'expired',
    };

    final activeList = <Map<String, dynamic>>[];
    final pastList = <Map<String, dynamic>>[];
    final cancelledList = <Map<String, dynamic>>[];

    for (final order in merged.values) {
      final rawStatus = (order['status'] ?? 'pending')
          .toString()
          .toLowerCase()
          .trim();
      final visibleStatus = _customerVisibleStatus(rawStatus);
      if (cancelled.contains(visibleStatus)) {
        cancelledList.add(order);
        continue;
      }
      if (delivered.contains(visibleStatus)) {
        pastList.add(order);
        continue;
      }
      activeList.add(order);
    }

    int sortByTs(Map<String, dynamic> a, Map<String, dynamic> b) {
      return _orderTimestamp(b).compareTo(_orderTimestamp(a));
    }

    activeList.sort(sortByTs);
    pastList.sort(sortByTs);
    cancelledList.sort(sortByTs);

    if (!mounted) return;
    setState(() {
      _activeOrders = activeList;
      _pastOrders = pastList;
      _cancelledOrders = cancelledList;
      _isLoading = false;
    });

    _syncCancelCountdownTicker();

    _autoRetryAttempts = 0;
    _autoRetryTimer?.cancel();
  }

  void _syncCancelCountdownTicker() {
    final hasCancelableActiveOrder = _activeOrders.any((order) {
      final status = (order['status'] ?? '').toString();
      return _isUserCancelableStatus(status) &&
          _cancelWindowSecondsLeft(order) > 0;
    });

    if (!hasCancelableActiveOrder) {
      _cancelTicker?.cancel();
      _cancelTicker = null;
      return;
    }

    _cancelTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      final stillHasCancelableActiveOrder = _activeOrders.any((order) {
        final status = (order['status'] ?? '').toString();
        return _isUserCancelableStatus(status) &&
            _cancelWindowSecondsLeft(order) > 0;
      });

      if (!stillHasCancelableActiveOrder) {
        setState(() {});
        _cancelTicker?.cancel();
        _cancelTicker = null;
        return;
      }

      setState(() {});
    });
  }

  void _scheduleAutoRetryIfNeeded() {
    // Only retry when startup race left us with zero orders — not after every
    // successful load (was causing 6 redundant full reloads every 2 seconds).
    final hasAnyOrders = _orderIndex.isNotEmpty;
    if (hasAnyOrders || _autoRetryAttempts >= _maxAutoRetryAttempts) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    _autoRetryTimer?.cancel();
    _autoRetryTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _autoRetryAttempts += 1;
      _loadOrders();
    });
  }

  Future<void> _loadOrders() async {
    final user = await _resolveCurrentUser();
    if (user == null) {
      if (mounted) setState(() => _isLoading = false);
      _scheduleAutoRetryIfNeeded();
      return;
    }

    try {
      await CityScopeService.ensureLoaded();
      await _loadUserIdentifiers(user);

      final tenantShopFuture = _database
          .child(_tenantPath('shop-orders'))
          .orderByChild('userId')
          .equalTo(user.uid)
          .get();
      final tenantHistoryFuture = _database
          .child(_tenantPath('order-history'))
          .orderByChild('userId')
          .equalTo(user.uid)
          .get();
      final legacyShopFuture = _database
          .child('shop-orders')
          .orderByChild('userId')
          .equalTo(user.uid)
          .get();
      final legacyHistoryFuture = _database
          .child('order-history')
          .orderByChild('userId')
          .equalTo(user.uid)
          .get();

      final snaps = await Future.wait<DataSnapshot>([
        tenantShopFuture,
        tenantHistoryFuture,
        legacyShopFuture,
        legacyHistoryFuture,
      ]);

      final tenantShopSnap = snaps[0];
      final tenantHistorySnap = snaps[1];
      final legacyShopSnap = snaps[2];
      final legacyHistorySnap = snaps[3];

      final tenantShopLatest = _latestTimestampFromSnapshot(tenantShopSnap);
      final tenantHistoryLatest = _latestTimestampFromSnapshot(
        tenantHistorySnap,
      );
      final legacyShopLatest = _latestTimestampFromSnapshot(legacyShopSnap);
      final legacyHistoryLatest = _latestTimestampFromSnapshot(
        legacyHistorySnap,
      );

      _useLegacyShopOrders =
          legacyShopLatest > tenantShopLatest &&
          legacyShopSnap.exists &&
          legacyShopSnap.value is Map;
      _useLegacyHistoryOrders =
          legacyHistoryLatest > tenantHistoryLatest &&
          legacyHistorySnap.exists &&
          legacyHistorySnap.value is Map;

      if ((!tenantShopSnap.exists || tenantShopSnap.value is! Map) &&
          legacyShopSnap.exists &&
          legacyShopSnap.value is Map) {
        _useLegacyShopOrders = true;
      }

      if ((!tenantHistorySnap.exists || tenantHistorySnap.value is! Map) &&
          legacyHistorySnap.exists &&
          legacyHistorySnap.value is Map) {
        _useLegacyHistoryOrders = true;
      }

      final hasUidOrders =
          (tenantShopSnap.exists && tenantShopSnap.value is Map) ||
          (tenantHistorySnap.exists && tenantHistorySnap.value is Map) ||
          (legacyShopSnap.exists && legacyShopSnap.value is Map) ||
          (legacyHistorySnap.exists && legacyHistorySnap.value is Map);

      _useAltIdentifiers = !hasUidOrders && _currentUserContact.isNotEmpty;

      DataSnapshot? altTenantShop;
      DataSnapshot? altTenantHistory;
      DataSnapshot? altLegacyShop;
      DataSnapshot? altLegacyHistory;

      if (_useAltIdentifiers) {
        final contact = _currentUserContact;
        final altSnaps = await Future.wait<DataSnapshot>([
          _database
              .child(_tenantPath('shop-orders'))
              .orderByChild('contact')
              .equalTo(contact)
              .get(),
          _database
              .child(_tenantPath('order-history'))
              .orderByChild('contact')
              .equalTo(contact)
              .get(),
          _database
              .child('shop-orders')
              .orderByChild('contact')
              .equalTo(contact)
              .get(),
          _database
              .child('order-history')
              .orderByChild('contact')
              .equalTo(contact)
              .get(),
        ]);
        altTenantShop = altSnaps[0];
        altTenantHistory = altSnaps[1];
        altLegacyShop = altSnaps[2];
        altLegacyHistory = altSnaps[3];
      }

      _orderIndex.clear();

      if (tenantShopSnap.exists && tenantShopSnap.value is Map) {
        final data = tenantShopSnap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'shop',
            id: key.toString(),
            raw: val,
            source: 'tenant',
            rebuild: false,
          );
        });
      }

      if (legacyShopSnap.exists && legacyShopSnap.value is Map) {
        final data = legacyShopSnap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'shop',
            id: key.toString(),
            raw: val,
            source: 'legacy',
            rebuild: false,
          );
        });
      }

      if (tenantHistorySnap.exists && tenantHistorySnap.value is Map) {
        final data = tenantHistorySnap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'history',
            id: key.toString(),
            raw: val,
            source: 'tenant',
            rebuild: false,
          );
        });
      }

      if (legacyHistorySnap.exists && legacyHistorySnap.value is Map) {
        final data = legacyHistorySnap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'history',
            id: key.toString(),
            raw: val,
            source: 'legacy',
            rebuild: false,
          );
        });
      }

      if (altTenantShop != null &&
          altTenantShop.exists &&
          altTenantShop.value is Map) {
        final data = altTenantShop.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'shop',
            id: key.toString(),
            raw: val,
            source: 'tenant-contact',
            rebuild: false,
          );
        });
      }

      if (altTenantHistory != null &&
          altTenantHistory.exists &&
          altTenantHistory.value is Map) {
        final data = altTenantHistory.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'history',
            id: key.toString(),
            raw: val,
            source: 'tenant-contact',
            rebuild: false,
          );
        });
      }

      if (altLegacyShop != null &&
          altLegacyShop.exists &&
          altLegacyShop.value is Map) {
        final data = altLegacyShop.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'shop',
            id: key.toString(),
            raw: val,
            source: 'legacy-contact',
            rebuild: false,
          );
        });
      }

      if (altLegacyHistory != null &&
          altLegacyHistory.exists &&
          altLegacyHistory.value is Map) {
        final data = altLegacyHistory.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          _upsertOrder(
            type: 'history',
            id: key.toString(),
            raw: val,
            source: 'legacy-contact',
            rebuild: false,
          );
        });
      }

      _rebuildOrderBuckets();
      _bindQueueListeners(user.uid);
      _bindRealtimeListeners(user.uid);
      _scheduleAutoRetryIfNeeded();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
      _scheduleAutoRetryIfNeeded();
    }
  }

  bool _hasOrderId(String id, {String? type}) {
    if (id.isEmpty) return false;
    return _orderIndex.values.any((o) {
      if ((o['id'] ?? '') != id) return false;
      if (type == null) return true;
      return (o['type'] ?? '').toString() == type;
    });
  }

  void _cancelRealtimeListeners() {
    _shopOrdersSub?.cancel();
    _historyOrdersSub?.cancel();
    _legacyShopOrdersSub?.cancel();
    _legacyHistoryOrdersSub?.cancel();
    _altShopOrdersSub?.cancel();
    _altHistoryOrdersSub?.cancel();
    _altLegacyShopOrdersSub?.cancel();
    _altLegacyHistoryOrdersSub?.cancel();

    _shopOrdersSub = null;
    _historyOrdersSub = null;
    _legacyShopOrdersSub = null;
    _legacyHistoryOrdersSub = null;
    _altShopOrdersSub = null;
    _altHistoryOrdersSub = null;
    _altLegacyShopOrdersSub = null;
    _altLegacyHistoryOrdersSub = null;
  }

  void _listenAppControl() async {
    try {
      await CityScopeService.ensureLoaded();
      _appControlSub?.cancel();
      _appControlSub = _database
          .child(_tenantPath('settings/app-control'))
          .onValue
          .listen((event) {
            if (!mounted) return;
            if (event.snapshot.exists && event.snapshot.value is Map) {
              final data = Map<String, dynamic>.from(
                event.snapshot.value as Map,
              );
              final enabled = data['showOrderQueueInfo'] != false;
              final thresholdRaw = data['highQueueThreshold'];
              final threshold = thresholdRaw is int
                  ? thresholdRaw
                  : int.tryParse(thresholdRaw?.toString() ?? '') ?? 7;
              final nextThreshold = threshold.clamp(3, 50);
              final nextPositionText =
                  (data['queuePositionText'] ?? _queuePositionText).toString().trim();
              final nextUpdatingText =
                  (data['queueUpdatingText'] ?? _queueUpdatingText).toString().trim();
              final nextActiveText =
                  (data['queueActiveOrdersText'] ?? _queueActiveOrdersText)
                      .toString()
                      .trim();
              final nextHighLoadText =
                  (data['queueHighLoadText'] ?? _queueHighLoadText).toString().trim();
              final queueSettingsChanged =
                  enabled != _showOrderQueueInfo ||
                  nextThreshold != _highQueueThreshold ||
                  nextPositionText != _queuePositionText ||
                  nextUpdatingText != _queueUpdatingText ||
                  nextActiveText != _queueActiveOrdersText ||
                  nextHighLoadText != _queueHighLoadText;
              if (queueSettingsChanged) {
                setState(() {
                  _showOrderQueueInfo = enabled;
                  _highQueueThreshold = nextThreshold;
                  if (nextPositionText.isNotEmpty) {
                    _queuePositionText = nextPositionText;
                  }
                  if (nextUpdatingText.isNotEmpty) {
                    _queueUpdatingText = nextUpdatingText;
                  }
                  if (nextActiveText.isNotEmpty) {
                    _queueActiveOrdersText = nextActiveText;
                  }
                  if (nextHighLoadText.isNotEmpty) {
                    _queueHighLoadText = nextHighLoadText;
                  }
                });
                if (!_shouldShowQueueInfo) {
                  _queuePollTimer?.cancel();
                  _queuePositions.clear();
                  _instantQueuePositions.clear();
                  _queueShopCount = 0;
                  _queueInstantCount = 0;
                  _queueShopActive = [];
                } else {
                  final user = FirebaseAuth.instance.currentUser;
                  if (user != null) {
                    _bindQueueListeners(user.uid);
                  }
                }
                if (_shouldShowQueueInfo) {
                  final user = FirebaseAuth.instance.currentUser;
                  if (user != null) unawaited(_refreshQueueStats(user.uid));
                }
              }
            } else {
              if (!_showOrderQueueInfo) {
                setState(() => _showOrderQueueInfo = true);
              }
            }
          });
    } catch (_) {}
  }

  int _normalizeTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _isQueueActiveStatus(dynamic rawStatus) {
    final status = (rawStatus ?? '').toString().toLowerCase().trim();
    const terminal = {
      'delivered',
      'cancelled',
      'canceled',
      'rejected',
      'merchant_rejected',
    };
    return !terminal.contains(status);
  }

  void _updateQueueFromSnapshot({
    required String type,
    required String currentUid,
    required DataSnapshot snapshot,
  }) {
    var activeCount = 0;
    final activeEntries = <Map<String, dynamic>>[];

    if (snapshot.exists && snapshot.value is Map) {
      final rawMap = snapshot.value as Map<dynamic, dynamic>;
      rawMap.forEach((key, value) {
        if (value is! Map) return;
        final map = Map<String, dynamic>.from(value);
        if (!_isQueueActiveStatus(map['status'])) return;
        map['id'] = key.toString();
        activeEntries.add(map);
      });

      activeEntries.sort((a, b) {
        final aTs = _normalizeTimestamp(a['createdAt']) > 0
            ? _normalizeTimestamp(a['createdAt'])
            : _normalizeTimestamp(a['createdAtClient']);
        final bTs = _normalizeTimestamp(b['createdAt']) > 0
            ? _normalizeTimestamp(b['createdAt'])
            : _normalizeTimestamp(b['createdAtClient']);
        return aTs.compareTo(bTs);
      });

      activeCount = activeEntries.length;
    }

    if (!mounted) return;
    _queueShopActive = activeEntries;
    _queueShopCount = activeCount;
    _recomputeCombinedQueuePositions(currentUid);
  }

  void _recomputeCombinedQueuePositions(String currentUid) {
    final combined = <Map<String, dynamic>>[];
    for (final entry in _queueShopActive) {
      combined.add({...entry, '_queueType': 'shop'});
    }

    combined.sort((a, b) {
      final aTs = _normalizeTimestamp(a['createdAt']) > 0
          ? _normalizeTimestamp(a['createdAt'])
          : _normalizeTimestamp(a['createdAtClient']);
      final bTs = _normalizeTimestamp(b['createdAt']) > 0
          ? _normalizeTimestamp(b['createdAt'])
          : _normalizeTimestamp(b['createdAtClient']);
      return aTs.compareTo(bTs);
    });

    final nextPositions = <String, int>{};
    for (var i = 0; i < combined.length; i++) {
      final order = combined[i];
      final uid = (order['userId'] ?? '').toString().trim();
      final id = (order['id'] ?? '').toString().trim();
      final queueType = (order['_queueType'] ?? 'shop').toString();
      if (uid == currentUid && id.isNotEmpty) {
        nextPositions['$queueType:$id'] = i + 1;
      }
    }

    if (!mounted) return;
    setState(() {
      _queuePositions
        ..clear()
        ..addAll(nextPositions);
    });
  }

  void _bindQueueListeners(String uid) {
    if (!_shouldShowQueueInfo) {
      _queuePollTimer?.cancel();
      _queueListenerUid = null;
      return;
    }
    _queueListenerUid = uid;
    _queuePollTimer?.cancel();

    unawaited(_refreshQueueStats(uid));
    _queuePollTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshQueueStats(uid),
    );
  }

  Future<Map<String, dynamic>> _computeQueueStatsFromFirebase(String uid) async {
    final snap = await _database.child(_tenantPath('shop-orders')).get();
    final combined = <Map<String, dynamic>>[];

    if (snap.exists && snap.value is Map) {
      final rawMap = snap.value as Map<dynamic, dynamic>;
      rawMap.forEach((key, value) {
        if (value is! Map) return;
        final map = Map<String, dynamic>.from(value);
        if (!_isQueueActiveStatus(map['status'])) return;
        combined.add({
          ...map,
          'id': key.toString(),
          'queueType': 'shop',
        });
      });
    }

    combined.sort((a, b) {
      final aTs = _normalizeTimestamp(a['createdAt']) > 0
          ? _normalizeTimestamp(a['createdAt'])
          : _normalizeTimestamp(a['createdAtClient']);
      final bTs = _normalizeTimestamp(b['createdAt']) > 0
          ? _normalizeTimestamp(b['createdAt'])
          : _normalizeTimestamp(b['createdAtClient']);
      return aTs.compareTo(bTs);
    });

    final positions = <String, int>{};
    final instantOnly = combined
        .where((order) => InstantDeliveryService.isInstantOrder(order))
        .toList();
    final instantPositions = <String, int>{};

    for (var i = 0; i < combined.length; i++) {
      final order = combined[i];
      final orderUid = (order['userId'] ?? '').toString().trim();
      final orderId = (order['id'] ?? '').toString().trim();
      if (orderUid == uid && orderId.isNotEmpty) {
        positions['shop:$orderId'] = i + 1;
      }
    }

    for (var i = 0; i < instantOnly.length; i++) {
      final order = instantOnly[i];
      final orderUid = (order['userId'] ?? '').toString().trim();
      final orderId = (order['id'] ?? '').toString().trim();
      if (orderUid == uid && orderId.isNotEmpty) {
        instantPositions['shop:$orderId'] = i + 1;
      }
    }

    return {
      'shopCount': combined.length,
      'activeCount': combined.length,
      'instantCount': instantOnly.length,
      'positions': positions,
      'instantPositions': instantPositions,
    };
  }

  Future<void> _refreshQueueStats(String uid) async {
    if (!_shouldShowQueueInfo) return;
    try {
      await CityScopeService.ensureLoaded();
      var stats = await AppDbClient.instance.fetchQueueStats(
        CityScopeService.tenantPath(''),
        uid,
      );
      if (stats.isEmpty) {
        stats = await _computeQueueStatsFromFirebase(uid);
      } else if (stats['instantCount'] == null) {
        final fbStats = await _computeQueueStatsFromFirebase(uid);
        stats = {
          ...stats,
          'instantCount': fbStats['instantCount'],
          'instantPositions': fbStats['instantPositions'],
        };
      }
      if (!mounted) return;
      final positionsRaw = stats['positions'];
      final instantPositionsRaw = stats['instantPositions'];
      final nextPositions = <String, int>{};
      final nextInstantPositions = <String, int>{};
      if (positionsRaw is Map) {
        positionsRaw.forEach((key, value) {
          final pos = value is int ? value : int.tryParse(value.toString()) ?? 0;
          if (pos > 0) nextPositions[key.toString()] = pos;
        });
      }
      if (instantPositionsRaw is Map) {
        instantPositionsRaw.forEach((key, value) {
          final pos = value is int ? value : int.tryParse(value.toString()) ?? 0;
          if (pos > 0) nextInstantPositions[key.toString()] = pos;
        });
      }
      setState(() {
        _queueShopCount = (stats['shopCount'] as num?)?.toInt() ??
            (stats['activeCount'] as num?)?.toInt() ??
            0;
        _queueInstantCount = (stats['instantCount'] as num?)?.toInt() ?? 0;
        _queuePositions
          ..clear()
          ..addAll(nextPositions);
        _instantQueuePositions
          ..clear()
          ..addAll(nextInstantPositions);
      });
    } catch (_) {}
  }

  void _listenOrderQueue() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _bindQueueListeners(user.uid);
    }
  }

  void _syncOrdersFromSnapshot({
    required String type,
    required DataSnapshot snapshot,
    required String source,
  }) {
    _orderIndex.removeWhere((key, _) => key.startsWith('$type:$source:'));

    if (snapshot.exists && snapshot.value is Map) {
      final data = snapshot.value as Map<dynamic, dynamic>;
      data.forEach((key, value) {
        if (type == 'history') {
          if (value is Map) {
            final row = Map<String, dynamic>.from(value);
            final archivedId = (row['orderId'] ?? row['id'] ?? '').toString();
            if (_hasOrderId(archivedId)) return;
          }
        }
        _upsertOrder(
          type: type,
          id: key.toString(),
          raw: value,
          source: source,
          rebuild: false,
        );
      });
    }

    _rebuildOrderBuckets();
  }

  void _bindRealtimeListeners(String uid) {
    _cancelRealtimeListeners();

    final tenantShopQuery = _database
        .child(_tenantPath('shop-orders'))
        .orderByChild('userId')
        .equalTo(uid);
    _shopOrdersSub = tenantShopQuery.onValue.listen((event) {
      _syncOrdersFromSnapshot(
        type: 'shop',
        snapshot: event.snapshot,
        source: 'tenant',
      );
    });

    _historyOrdersSub = _database
        .child(_tenantPath('order-history'))
        .orderByChild('userId')
        .equalTo(uid)
        .onValue
        .listen((event) {
          _syncOrdersFromSnapshot(
            type: 'history',
            snapshot: event.snapshot,
            source: 'tenant',
          );
        });

    final legacyShopQuery = _database
        .child('shop-orders')
        .orderByChild('userId')
        .equalTo(uid);
    _legacyShopOrdersSub = legacyShopQuery.onValue.listen((event) {
      _syncOrdersFromSnapshot(
        type: 'shop',
        snapshot: event.snapshot,
        source: 'legacy',
      );
    });

    _legacyHistoryOrdersSub = _database
        .child('order-history')
        .orderByChild('userId')
        .equalTo(uid)
        .onValue
        .listen((event) {
          _syncOrdersFromSnapshot(
            type: 'history',
            snapshot: event.snapshot,
            source: 'legacy',
          );
        });

    if (_useAltIdentifiers && _currentUserContact.isNotEmpty) {
      final contact = _currentUserContact;
      _altShopOrdersSub = _database
          .child(_tenantPath('shop-orders'))
          .orderByChild('contact')
          .equalTo(contact)
          .onValue
          .listen((event) {
            _syncOrdersFromSnapshot(
              type: 'shop',
              snapshot: event.snapshot,
              source: 'tenant-contact',
            );
          });

      _altHistoryOrdersSub = _database
          .child(_tenantPath('order-history'))
          .orderByChild('contact')
          .equalTo(contact)
          .onValue
          .listen((event) {
            _syncOrdersFromSnapshot(
              type: 'history',
              snapshot: event.snapshot,
              source: 'tenant-contact',
            );
          });

      _altLegacyShopOrdersSub = _database
          .child('shop-orders')
          .orderByChild('contact')
          .equalTo(contact)
          .onValue
          .listen((event) {
            _syncOrdersFromSnapshot(
              type: 'shop',
              snapshot: event.snapshot,
              source: 'legacy-contact',
            );
          });

      _altLegacyHistoryOrdersSub = _database
          .child('order-history')
          .orderByChild('contact')
          .equalTo(contact)
          .onValue
          .listen((event) {
            _syncOrdersFromSnapshot(
              type: 'history',
              snapshot: event.snapshot,
              source: 'legacy-contact',
            );
          });
    }
  }

  Future<void> refreshNow({bool showLoader = false}) async {
    if (_isExplicitRefreshRunning) return;
    _isExplicitRefreshRunning = true;
    if (showLoader && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      await _loadOrders();
      if (_shouldShowQueueInfo) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) unawaited(_refreshQueueStats(user.uid));
      }
    } finally {
      _isExplicitRefreshRunning = false;
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  String _customerVisibleStatus(dynamic rawStatus) {
    final status = (rawStatus ?? 'pending').toString().toLowerCase().trim();
    if (status == 'on_way' || status == 'out_for_delivery') {
      return 'on_the_way';
    }
    if (status == 'pending_admin' || status == 'admin_pending') {
      return 'pending';
    }
    if (status == 'available' ||
        status == 'confirmed' ||
        status == 'merchant_pending' ||
        status == 'admin_approved' ||
        status == 'ready') {
      return 'pending';
    }
    if (status == 'picked' || status == 'preparing') {
      return 'preparing';
    }
    return status;
  }

  Color _statusColor(String status) {
    switch (_customerVisibleStatus(status)) {
      case 'delivered':
        return const Color(0xFF22C55E);
      case 'cancelled':
      case 'canceled':
        return const Color(0xFFEF4444);
      case 'pending':
        return const Color(0xFFF59E0B);
      case 'merchant_pending':
        return const Color(0xFF0EA5A4);
      case 'confirmed':
        return const Color(0xFFFF6B00);
      case 'preparing':
        return const Color(0xFF8B5CF6);
      case 'on_the_way':
      case 'out_for_delivery':
        return const Color(0xFF06B6D4);
      default:
        return Colors.grey;
    }
  }

  IconData _statusIcon(String status) {
    switch (_customerVisibleStatus(status)) {
      case 'delivered':
        return Icons.check_circle_rounded;
      case 'cancelled':
      case 'canceled':
        return Icons.cancel_rounded;
      case 'pending':
        return Icons.access_time_rounded;
      case 'merchant_pending':
        return Icons.storefront_rounded;
      case 'confirmed':
        return Icons.thumb_up_rounded;
      case 'preparing':
        return Icons.restaurant_rounded;
      case 'on_the_way':
      case 'out_for_delivery':
        return Icons.moped_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  String _formatStatus(String status) {
    final visible = _customerVisibleStatus(status);
    if (visible == 'pending') return 'Order Placed';
    return visible
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  String _getOrderDate(Map<String, dynamic> order) {
    final ts = _orderTimestamp(order);
    if (ts > 0) {
      final date = DateTime.fromMillisecondsSinceEpoch(ts);
      final diff = DateTime.now().difference(date).inDays;
      if (diff == 0) return 'Today, ${_formatTime(date)}';
      if (diff == 1) return 'Yesterday, ${_formatTime(date)}';
      return '${date.day} ${_monthName(date.month)}, ${_formatTime(date)}';
    }
    return 'Recently';
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final min = dt.minute.toString().padLeft(2, '0');
    return '$hour:$min ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _monthName(int m) {
    const months = [
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
    return (m >= 1 && m <= 12) ? months[m - 1] : '';
  }

  String _getItemsText(Map<String, dynamic> order) {
    final items = order['items'];
    if (items is List && items.isNotEmpty) {
      return items
          .map((i) => '${i['quantity'] ?? 1}× ${i['name'] ?? 'Item'}')
          .join(', ');
    }
    if (order['whatYouWant'] != null) return order['whatYouWant'].toString();
    return '';
  }

  int _queuePositionForOrder(Map<String, dynamic> order) {
    final type = (order['orderType'] ?? order['type'] ?? 'shop').toString();
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return 0;
    return _queuePositions['$type:$orderId'] ?? 0;
  }

  int _instantQueuePositionForOrder(Map<String, dynamic> order) {
    final type = (order['orderType'] ?? order['type'] ?? 'shop').toString();
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return 0;
    return _instantQueuePositions['$type:$orderId'] ?? 0;
  }

  int get _globalQueueCount => _queueShopCount;

  Widget _buildInstantQueueInfo(Map<String, dynamic> order) {
    if (!_shouldShowQueueInfo) return const SizedBox.shrink();
    final visibleStatus = _customerVisibleStatus(order['status']);
    const terminal = {'delivered', 'cancelled', 'canceled'};
    if (terminal.contains(visibleStatus)) {
      return const SizedBox.shrink();
    }

    final queuePosition = _instantQueuePositionForOrder(order);
    final positionLabel = queuePosition > 0
        ? 'Your instant order is #$queuePosition in queue'
        : _queueUpdatingText;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFF7ED), Color(0xFFFFEDD5)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDBA74)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, color: _primary, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  positionLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF9A3412),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Active instant orders: $_queueInstantCount',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[700],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueInfo(Map<String, dynamic> order) {
    if (InstantDeliveryService.isInstantOrder(order)) {
      return _buildInstantQueueInfo(order);
    }
    if (!_shouldShowQueueInfo) return const SizedBox.shrink();
    final visibleStatus = _customerVisibleStatus(order['status']);
    const terminal = {'delivered', 'cancelled', 'canceled'};
    if (terminal.contains(visibleStatus)) {
      return const SizedBox.shrink();
    }

    final queuePosition = _queuePositionForOrder(order);
    final isHighLoad = _globalQueueCount >= _highQueueThreshold;
    final positionLabel = _queuePositionText
        .replaceAll('{position}', '$queuePosition')
        .replaceAll('#{position}', '$queuePosition');
    final activeLabel = _queueActiveOrdersText
        .replaceAll('{count}', '$_globalQueueCount');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.queue_rounded, color: _primary, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  queuePosition > 0 ? positionLabel : _queueUpdatingText,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF9A3412),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            activeLabel,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[700],
              fontWeight: FontWeight.w600,
            ),
          ),
          if (isHighLoad) ...[
            const SizedBox(height: 4),
            Text(
              _queueHighLoadText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.orange.shade800,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _shouldShowCharityPrompt(Map<String, dynamic> order) {
    if (!_charityEnabled) return false;
    final status = _customerVisibleStatus(order['status']);
    if (status != 'preparing' &&
        status != 'on_the_way' &&
        status != 'confirmed') {
      return false;
    }
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isNotEmpty && _charityDismissed.contains(orderId)) {
      return false;
    }
    final existing = _toDouble(order['charityDonationAmount']);
    if (existing > 0 || order['charityDonationApplied'] == true) {
      return false;
    }
    return _charityAmount > 0;
  }

  bool _isUserCancelableStatus(String status) {
    final s = (status).toLowerCase().trim();
    return s == 'pending' ||
        s == 'pending_admin' ||
        s == 'admin_pending' ||
        s == 'available' ||
        s == 'confirmed' ||
        s == 'preparing' ||
        s == 'merchant_pending';
  }

  int _cancelWindowSecondsLeft(Map<String, dynamic> order) {
    final createdMs = _orderTimestamp(order);
    if (createdMs <= 0) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = ((now - createdMs) / 1000).floor();
    final remaining = 60 - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  String _formatRemaining(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _archiveCancelledOrder(
    Map<String, dynamic> order, {
    required String reason,
    required String cancelledByRole,
    String? cancelledByName,
    String? cancelledByEmail,
    String? cancelledByUid,
  }) async {
    final orderId = (order['id'] ?? '').toString().trim();
    if (orderId.isEmpty) return;
    final orderType = (order['type'] ?? order['orderType'] ?? 'shop')
        .toString();
    final key = '${orderType}_$orderId';
    final payload = Map<String, dynamic>.from(order)
      ..['orderId'] = orderId
      ..['orderType'] = orderType
      ..['status'] = 'cancelled'
      ..['cancelReason'] = reason
      ..['cancelledByRole'] = cancelledByRole
      ..['cancelledByName'] = cancelledByName
      ..['cancelledByEmail'] = cancelledByEmail
      ..['cancelledByUid'] = cancelledByUid
      ..['cancelledAt'] = DateTime.now().millisecondsSinceEpoch
      ..['archivedAt'] = ServerValue.timestamp;

    await _database.child(_tenantPath('order-history')).child(key).set(payload);
  }

  Future<void> _cancelOrder(Map<String, dynamic> order) async {
    final orderId = (order['id'] ?? '').toString().trim();
    if (orderId.isEmpty || _cancelInFlight.contains(orderId)) return;

    final secondsLeft = _cancelWindowSecondsLeft(order);
    if (secondsLeft <= 0) return;

    final rawStatus = (order['status'] ?? '').toString();
    if (!_isUserCancelableStatus(rawStatus)) return;

    final orderType = (order['type'] ?? 'shop').toString();
    final node = orderType == 'custom' ? 'custom-orders' : 'shop-orders';
    final reason = 'Cancelled by customer';

    final user = FirebaseAuth.instance.currentUser;
    final userName = user?.displayName ?? 'Customer';
    final userEmail = user?.email ?? '';
    final userUid = user?.uid ?? '';

    setState(() => _cancelInFlight.add(orderId));
    try {
      // Primary update to the node where the order likely exists.
      await _database.child(_tenantPath(node)).child(orderId).update({
        'status': 'cancelled',
        'cancelReason': reason,
        'cancelledByRole': 'customer',
        'cancelledByName': userName,
        'cancelledByEmail': userEmail,
        'cancelledByUid': userUid,
        'cancelledAt': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': ServerValue.timestamp,
        'customerStatusMessage': 'Order cancelled by customer.',
      });

      // If the order originated from legacy source, also update the legacy root path
      // so the original record reflects cancellation and listeners there get updated.
      final src = (order['source'] ?? '').toString();
      if (src == 'legacy') {
        try {
          await _database.child(node).child(orderId).update({
            'status': 'cancelled',
            'cancelReason': reason,
            'cancelledByRole': 'customer',
            'cancelledByName': userName,
            'cancelledByEmail': userEmail,
            'cancelledByUid': userUid,
            'cancelledAt': DateTime.now().millisecondsSinceEpoch,
            'updatedAt': ServerValue.timestamp,
            'customerStatusMessage': 'Order cancelled by customer.',
          });
        } catch (e) {}
      }
      await _archiveCancelledOrder(
        order,
        reason: reason,
        cancelledByRole: 'customer',
        cancelledByName: userName,
        cancelledByEmail: userEmail,
        cancelledByUid: userUid,
      );

      // Trigger FCM notifications to Admins and Rider
      final orderCity = CityScopeService.currentCity;
      final orderCode = (order['customOrderId'] ?? orderId).toString();
      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'admin',
          city: orderCity,
          title: 'Order Cancelled',
          body: 'Order #$orderCode was cancelled by the customer.',
          data: {
            'type': 'order_cancelled',
            'orderId': orderId,
            'city': orderCity,
          },
        ).catchError((_) => {}),
      );

      final assignedRiderId = (order['assignedRider'] ?? '').toString().trim();
      if (assignedRiderId.isNotEmpty) {
        unawaited(
          NotificationService.sendToSpecificUser(
            target: assignedRiderId,
            title: 'Order Cancelled',
            body: 'Order #$orderCode assigned to you was cancelled.',
          ).catchError((_) => {}),
        );
      }

      if (mounted) {
        setState(() {
          order['status'] = 'cancelled';
          order['cancelReason'] = reason;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to cancel order right now.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _cancelInFlight.remove(orderId));
    }
  }

  Future<void> _applyCharityDonation(Map<String, dynamic> order) async {
    final orderId = (order['id'] ?? '').toString().trim();
    if (orderId.isEmpty || _charityInFlight.contains(orderId)) return;

    final amount = _charityAmount;
    if (amount <= 0) return;

    _charityInFlight.add(orderId);
    try {
      final baseTotal = _toDouble(order['grandTotal']);
      final newTotal = baseTotal + amount;
      final orderType = (order['type'] ?? 'shop').toString();
      final node = orderType == 'custom' ? 'custom-orders' : 'shop-orders';

      await _database.child(_tenantPath(node)).child(orderId).update({
        'charityDonationAmount': amount,
        'charityDonationApplied': true,
        'charityDonationMessage': _charityMessage,
        'grandTotal': newTotal,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      setState(() {
        order['charityDonationAmount'] = amount;
        order['charityDonationApplied'] = true;
        order['charityDonationMessage'] = _charityMessage;
        order['grandTotal'] = newTotal;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to add charity right now. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _charityInFlight.remove(orderId);
    }
  }

  Widget _buildStatusAnimation(String status) {
    final visible = _customerVisibleStatus(status);
    switch (visible) {
      case 'confirmed':
        return _buildStatusHero(
          asset: 'assets/order_confirmed.json',
          title: 'Order Confirmed!',
          subtitle: 'Shukriya! Aapka order accept ho gaya hai.',
          colors: const [Color(0xFFFF8A00), Color(0xFFFF6B00)],
          animHeight: 118,
        );
      case 'preparing':
        return _buildStatusHero(
          asset: 'assets/cooking.json',
          title: 'Preparing Your Order',
          subtitle: 'Chef aapka mazedaar khana bana raha hai...',
          colors: const [Color(0xFFA855F7), Color(0xFF7C3AED)],
          animHeight: 120,
        );
      case 'on_the_way':
      case 'out_for_delivery':
        return _buildStatusHero(
          asset: 'assets/rider.json',
          title: 'On The Way!',
          subtitle: 'Rider aapke order ke saath raste mein hai.',
          colors: const [Color(0xFF22D3EE), Color(0xFF06B6D4)],
          animHeight: 122,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildStatusHero({
    required String asset,
    required String title,
    required String subtitle,
    required List<Color> colors,
    double animHeight = 120,
  }) {
    return AnimatedBuilder(
      animation: _chefAnim,
      builder: (_, child) {
        final scale = 0.985 + (_chefAnim.value * 0.015);
        return Transform.scale(scale: scale, child: child);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: colors.last.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            SizedBox(
              height: animHeight,
              child: Lottie.asset(
                asset,
                fit: BoxFit.contain,
                repeat: true,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharityPrompt(Map<String, dynamic> order) {
    final message = _charityMessage.isNotEmpty
        ? _charityMessage
        : 'Aapka khana raste mein hai. Kya aap Rs. ${_charityAmount.toStringAsFixed(0)} donate kar ke kisi zaroorat mand ko khana khilana chahenge?';
    final orderId = (order['id'] ?? '').toString();
    final isBusy = orderId.isNotEmpty && _charityInFlight.contains(orderId);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FFF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFB7E4C7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.volunteer_activism_rounded,
                color: Color(0xFF22C55E),
                size: 18,
              ),
              const SizedBox(width: 6),
              const Text(
                'Share a Meal',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[700],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: isBusy ? null : () => _applyCharityDonation(order),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    isBusy
                        ? 'Adding...'
                        : 'Donate Rs. ${_charityAmount.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: orderId.isEmpty
                    ? null
                    : () {
                        setState(() {
                          _charityDismissed.add(orderId);
                        });
                      },
                child: const Text(
                  'Not now',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F4),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: _primary),
                    )
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildActiveTab(),
                        _buildHistoryTab(),
                        _buildCancelledTab(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: const Color(0xFFFCFAF8),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                const SizedBox(height: 32),
                const Text(
                  'Orders',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1D130C),
                    letterSpacing: -0.015,
                  ),
                ),
                Positioned(
                  right: 0,
                  child: IconButton(
                    onPressed: () => refreshNow(showLoader: true),
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: Color(0xFFFF6A00),
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFEAD9CD))),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: const Color(0xFF1D130C),
              unselectedLabelColor: const Color(0xFFA16B45),
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                fontFamily: 'Plus Jakarta Sans',
              ),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                fontFamily: 'Plus Jakarta Sans',
              ),
              indicatorColor: const Color(0xFFFF6A00),
              indicatorWeight: 3,
              dividerColor: Colors.transparent,
              labelPadding: EdgeInsets.zero,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Active'),
                      if (_activeOrders.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          height: 18,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF6A00),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_activeOrders.length}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              height: 1,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('History'),
                      if (_pastOrders.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[400],
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_pastOrders.length}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Cancelled'),
                      if (_cancelledOrders.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_cancelledOrders.length}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
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
        ],
      ),
    );
  }

  // ─── Active Tab ──────────────────────────────────────────────────────────────

  Widget _buildActiveTab() {
    if (_activeOrders.isEmpty &&
        _pastOrders.isEmpty &&
        _cancelledOrders.isEmpty) {
      return _buildEmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No Active Orders',
        subtitle: 'Orders you place will appear here',
      );
    }
    final recentHistory = _pastOrders.take(3).toList();
    return RefreshIndicator(
      color: _primary,
      onRefresh: () => refreshNow(showLoader: false),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          if (_activeOrders.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Center(
                child: Text(
                  'No active orders right now',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ..._activeOrders.map(
            (o) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildActiveOrderCard(o),
            ),
          ),
          if (recentHistory.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 16,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Recent History',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Colors.grey[500],
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _tabController.animateTo(1),
                    child: Text(
                      'View All',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ...recentHistory.map(
              (o) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildHistoryMiniCard(o),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── History Tab ─────────────────────────────────────────────────────────────

  Widget _buildHistoryTab() {
    if (_pastOrders.isEmpty) {
      return _buildEmptyState(
        icon: Icons.history_rounded,
        title: 'No Past Orders',
        subtitle: 'Your order history will appear here',
      );
    }
    return RefreshIndicator(
      color: _primary,
      onRefresh: () => refreshNow(showLoader: false),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: _pastOrders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _buildHistoryOrderCard(_pastOrders[i]),
      ),
    );
  }

  Widget _buildCancelledTab() {
    if (_cancelledOrders.isEmpty) {
      return _buildEmptyState(
        icon: Icons.cancel_rounded,
        title: 'No Cancelled Orders',
        subtitle: 'Cancelled orders will show here',
      );
    }
    return RefreshIndicator(
      color: _primary,
      onRefresh: () => refreshNow(showLoader: false),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: _cancelledOrders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _buildHistoryOrderCard(_cancelledOrders[i]),
      ),
    );
  }

  // ─── New Active Order Card ────────────────────────────────────────────────────

  Widget _buildActiveOrderCard(Map<String, dynamic> order) {
    final status = (order['status'] ?? 'pending').toString();
    final shopName = order['shopName'] ?? order['shop'] ?? 'Unknown Shop';
    final shopImage = order['shopImage'] ?? '';
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final deliveryFee = order['deliveryFee'] ?? 0;
    final subtotal = order['subtotal'] ?? (total - deliveryFee);
    final rawId = (order['id'] ?? '').toString();
    final isCustom = order['orderType'] == 'custom';

    // Parse Items
    List<Map<String, dynamic>> itemsList = [];
    final rawItems = order['items'];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) itemsList.add(Map<String, dynamic>.from(it));
      }
    }

    // ETA
    final createdAtMs =
        int.tryParse(order['createdAt']?.toString() ?? '0') ?? 0;
    String etaText = 'Calculating...';
    if (createdAtMs > 0) {
      final etaTime = DateTime.fromMillisecondsSinceEpoch(
        createdAtMs,
      ).add(const Duration(minutes: 45));
      etaText = 'Estimated: ${DateFormat('h:mm a').format(etaTime)}';
    }

    // Cancel Window
    final secondsLeft = _cancelWindowSecondsLeft(order);
    final isCancelWindowOpen =
        secondsLeft > 0 && _isUserCancelableStatus(status);
    final cancelProgress = (secondsLeft / 60).clamp(0.0, 1.0);
    final isCancelBusy = rawId.isNotEmpty && _cancelInFlight.contains(rawId);

    // Rider
    final assignedRider = order['assignedRider']?.toString().trim() ?? '';
    final riderName =
        (order['assignedRiderName'] ?? order['riderName'] ?? 'Your Rider')
            .toString()
            .trim();
    final riderPhone =
        (order['assignedRiderPhone'] ?? order['riderPhone'] ?? '')
            .toString()
            .trim();
    final hasRider = assignedRider.isNotEmpty;

    // Progress Bar (Order Placed -> Preparing -> On the way -> Delivered)
    // Rider "picked" => customer sees "Preparing".
    // Rider "start delivery" (on_the_way) => customer sees "On the way".
    double progressPct = 0.25;
    final visibleSt = _customerVisibleStatus(status);
    if (visibleSt == 'preparing') {
      progressPct = 0.50;
    } else if (visibleSt == 'on_the_way') {
      progressPct = 0.75;
    } else if (visibleSt == 'delivered') {
      progressPct = 1.0;
    }

    String? formatStageTime(dynamic ms) {
      if (ms == null) return null;
      int? parsed = int.tryParse(ms.toString());
      if (parsed == null || parsed <= 0) return null;
      return DateFormat(
        'h:mm a',
      ).format(DateTime.fromMillisecondsSinceEpoch(parsed));
    }

    final String? placedTime = formatStageTime(
      order['timestamp'] ?? order['createdAt'],
    );
    final String? confirmedTime = formatStageTime(
      order['confirmedAt'] ??
          order['adminApprovedAt'] ??
          order['merchantPendingAt'],
    );
    final String? pickedTime = formatStageTime(
      order['pickedAt'] ?? order['riderPickedAt'],
    );
    final String? preparingTime = formatStageTime(
      order['preparingAt'] ?? order['pickedAt'] ?? order['riderPickedAt'],
    );
    final String? onTheWayTime = formatStageTime(
      order['onTheWayAt'] ?? order['outForDeliveryAt'],
    );
    final String? deliveredTime = formatStageTime(order['deliveredAt']);

    final stages = [
      {'title': 'Order Placed', 'time': placedTime, 'pct': 0.25},
      {
        'title': 'Preparing',
        'time': preparingTime ?? confirmedTime,
        'pct': 0.50,
      },
      {'title': 'On the way', 'time': onTheWayTime, 'pct': 0.75},
      {'title': 'Delivered', 'time': deliveredTime, 'pct': 1.0},
    ];

    int currentStageIndex = 0;
    if (progressPct >= 1.0)
      currentStageIndex = 3;
    else if (progressPct >= 0.75)
      currentStageIndex = 2;
    else if (progressPct >= 0.50)
      currentStageIndex = 1;

    int startIndex = (currentStageIndex - 1).clamp(0, 3);
    int endIndex = (currentStageIndex + 1).clamp(0, 3);

    final visibleStages = [];
    for (int i = startIndex; i <= endIndex; i++) {
      visibleStages.add({...stages[i], 'index': i});
    }

    Widget buildVerticalStep(
      String title,
      String? time,
      bool isCurrent,
      bool isPast,
      bool isLastVisible,
    ) {
      final isFaded = !isCurrent;
      return Opacity(
        opacity: isFaded ? 0.4 : 1.0,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  height: 14,
                  width: 14,
                  decoration: BoxDecoration(
                    color: (isCurrent || isPast)
                        ? const Color(0xFFFF6B00)
                        : Colors.grey.shade300,
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isLastVisible)
                  Container(
                    height: 32,
                    width: 2,
                    color: (isPast || isCurrent)
                        ? const Color(0xFFFF6B00)
                        : Colors.grey.shade300,
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        color: (isCurrent || isPast)
                            ? const Color(0xFF1D130C)
                            : Colors.grey.shade600,
                        fontWeight: isCurrent
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                    if (time != null && time.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          time,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () => _showOrderDetailsSheet(order),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade100),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${(order['customOrderId'] ?? order['id'] ?? '').toString()}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFF6B00),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          shopName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1D130C),
                            fontFamily: 'Plus Jakarta Sans',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Custom Vertical Progress Timeline
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatStatus(status),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFA04100),
                          fontFamily: 'Be Vietnam Pro',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ...List.generate(visibleStages.length, (i) {
                    final s = visibleStages[i];
                    final sIndex = s['index'] as int;
                    return buildVerticalStep(
                      s['title'] as String,
                      s['time'] as String?,
                      sIndex == currentStageIndex, // isCurrent
                      sIndex < currentStageIndex, // isPast
                      i == visibleStages.length - 1, // isLastVisible
                    );
                  }),
                  Builder(
                    builder: (_) {
                      final anim = _buildStatusAnimation(status);
                      if (anim is SizedBox) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 4),
                        child: anim,
                      );
                    },
                  ),
                  _buildQueueInfo(order),
                ],
              ),
            ),

            // 1 Min Cancellation Window
            if (isCancelWindowOpen) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Cancel Order',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.red,
                            ),
                          ),
                          Text(
                            '00:${secondsLeft.toString().padLeft(2, '0')}s',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: cancelProgress,
                        backgroundColor: Colors.red.shade100,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.red.shade400,
                        ),
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: isCancelBusy
                              ? null
                              : () => _cancelOrder(order),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text(
                            isCancelBusy ? 'Cancelling...' : 'Cancel Order',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Rider message — visible as soon as order is placed
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0F7FA),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF06B6D4).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delivery_dining_rounded,
                          color: Color(0xFF06B6D4),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                hasRider ? riderName : 'Your Rider',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                hasRider && riderPhone.isNotEmpty
                                    ? riderPhone
                                    : 'Message your delivery rider anytime',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => UserChatPage(
                                  orderId: rawId,
                                  orderType: (order['orderType'] ??
                                          order['type'] ??
                                          '')
                                      .toString(),
                                  orderCode: (order['customOrderId'] ??
                                          order['id'] ??
                                          '')
                                      .toString(),
                                  isRiderChat: true,
                                  riderName:
                                      hasRider ? riderName : 'Your Rider',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.chat_bubble_rounded,
                            color: Color(0xFF06B6D4),
                          ),
                          tooltip: 'Message Rider',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserChatPage(
                              orderId: rawId,
                              orderType: (order['orderType'] ??
                                      order['type'] ??
                                      '')
                                  .toString(),
                              orderCode: (order['customOrderId'] ??
                                      order['id'] ??
                                      '')
                                  .toString(),
                              isRiderChat: true,
                              riderName: hasRider ? riderName : 'Your Rider',
                            ),
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Color(0xFF06B6D4),
                      ),
                      label: const Text(
                        'Message Rider',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF06B6D4),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Color(0xFF06B6D4)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  if (itemsList.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Order Items',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1D130C),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...itemsList.map((item) {
                        final qty = item['quantity'] ?? 1;
                        final name =
                            item['name'] ?? item['productName'] ?? 'Item';
                        final variant = item['variant'] ?? item['variation'];

                        String title = '$qty x $name';
                        if (variant != null &&
                            variant.toString().isNotEmpty &&
                            variant.toString() != 'null') {
                          title += ' ($variant)';
                        }

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.black87,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        );
                      }).toList(),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            const SizedBox(height: 16),

            // Order Details
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total Bill Price',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1D130C),
                    ),
                  ),
                  Text(
                    'Rs. $total',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFA04100),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ─── Reorder ────────────────────────────────────────────────────────────────

  Future<void> _reorderOrder(Map<String, dynamic> order) async {
    final rawItems = order['items'];
    if (rawItems is! List || rawItems.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('No items found in this order to reorder.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    if (!_cartService.isEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Replace cart?'),
          content: const Text(
            'Your cart already has items. Replace them with this order?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Replace & Reorder',
                style: TextStyle(
                  color: _primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }

    final added = _cartService.loadFromOrderItems(
      rawItems,
      orderFallback: order,
      clearFirst: true,
    );

    if (added == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Could not add items to cart. They may be unavailable.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$added item${added == 1 ? '' : 's'} added to cart'),
          backgroundColor: _primary,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'View Cart',
            textColor: Colors.white,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CartPage()),
              );
            },
          ),
        ),
      );

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CartPage()),
    );
  }

  // ─── New History Order Card ────────────────────────────────────────────────────

  Widget _buildHistoryOrderCard(Map<String, dynamic> order) {
    final status = (order['status'] ?? 'pending').toString();
    final shopName = order['shopName'] ?? order['shop'] ?? 'Unknown Shop';
    final shopImage = order['shopImage'] ?? '';
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final isCustom = order['orderType'] == 'custom';

    final isRated = order['isRated'] == true;
    final shopId = (order['shopId'] ?? '').toString();
    final orderId = (order['id'] ?? '').toString();
    final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isDelivered = status.toLowerCase() == 'delivered';

    // Parse Items for a quick summary
    String itemsSummary = '';
    if (isCustom) {
      itemsSummary = order['whatYouWant']?.toString() ?? 'Custom Order';
    } else {
      List<String> parts = [];
      final rawItems = order['items'];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is Map) {
            parts.add('${it['quantity'] ?? 1}x ${it['name'] ?? 'Item'}');
          }
        }
      }
      itemsSummary = parts.join(', ');
    }

    return GestureDetector(
      onTap: () => _showOrderDetailsSheet(order),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFEEEEEE),
          ), // surface-container
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              shopName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1D130C),
                              ),
                            ),
                          ),
                          Text(
                            _getOrderDate(order),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF5F5E5E),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        itemsSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF636262), // on-secondary-container
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Rs. $total',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFA04100), // primary
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserChatPage(
                            orderId: (order['id'] ?? '').toString(),
                            orderType:
                                (order['orderType'] ?? order['type'] ?? '')
                                    .toString(),
                            orderCode:
                                (order['customOrderId'] ?? order['id'] ?? '')
                                    .toString(),
                          ),
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFFEEEEEE),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text(
                      'Get Help',
                      style: TextStyle(
                        color: Color(0xFF1D130C),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _reorderOrder(order),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                    label: const Text('Reorder'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFA04100),
                      side: const BorderSide(color: Color(0xFFA04100)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
            if (isDelivered && !isRated && shopId.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (ctx) => RatingDialog(
                        orderId: orderId,
                        userId: userId,
                        shopId: shopId,
                        onSubmitted: () {
                          Navigator.pop(ctx);
                        },
                      ),
                    );
                  },
                  icon: const Icon(Icons.star_rounded, size: 18),
                  label: const Text(
                    'Rate Order',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B00),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Unified Order Card ───────────────────────────────────────────────────────

  Widget _buildLegacyOrderCard(
    Map<String, dynamic> order, {
    required bool isActive,
  }) {
    final status = (order['status'] ?? 'pending').toString();
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final shopName = order['shopName'] ?? order['shop'] ?? 'Unknown Shop';
    final rawId = (order['id'] ?? '').toString();
    final orderId = rawId.length >= 6
        ? rawId.substring(0, 6).toUpperCase()
        : rawId.toUpperCase();
    final itemsText = _getItemsText(order);
    final statusColor = _statusColor(status);
    final isCancelled =
        status.toLowerCase() == 'cancelled' ||
        status.toLowerCase() == 'canceled';
    final cancelReason =
        (order['cancelReason'] ?? order['cancellationReason'] ?? '')
            .toString()
            .trim();
    final secondsLeft = _cancelWindowSecondsLeft(order);
    final canCancel =
        isActive && secondsLeft > 0 && _isUserCancelableStatus(status);
    final isCancelBusy = rawId.isNotEmpty && _cancelInFlight.contains(rawId);
    final cancelProgress = (secondsLeft / 60).clamp(0.0, 1.0);

    return GestureDetector(
      onTap: () => _showOrderDetails(order),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Top row ──
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: _primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          shopName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _getOrderDate(order),
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
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_statusIcon(status), color: statusColor, size: 13),
                        const SizedBox(width: 4),
                        Text(
                          _formatStatus(status),
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Divider(color: Colors.grey[100], height: 1),
              ),
              if (isCancelled) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF1F2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        size: 16,
                        color: Color(0xFFB91C1C),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (cancelReason.isNotEmpty)
                              Text(
                                'Cancel reason: $cancelReason',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFB91C1C),
                                ),
                              ),
                            if (order['cancelledByRole'] != null) ...[
                              if (cancelReason.isNotEmpty)
                                const SizedBox(height: 4),
                              Text(
                                'Cancelled by: ${order['cancelledByName'] ?? 'Unknown'} (${order['cancelledByRole']})',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFFB91C1C),
                                ),
                              ),
                              if (order['cancelledByEmail'] != null)
                                Text(
                                  'Email: ${order['cancelledByEmail']}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFB91C1C),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // ── Order ID ──
              Row(
                children: [
                  Icon(Icons.tag_rounded, size: 14, color: Colors.grey[400]),
                  const SizedBox(width: 4),
                  Text(
                    'Order #$orderId',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (itemsText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  itemsText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ],
              // ── Status steps (active only) ──
              if (isActive) ...[
                const SizedBox(height: 14),
                _buildQueueInfo(order),
                _buildStatusSteps(status, order),
                const SizedBox(height: 10),
                _buildStatusAnimation(status),
                if (_shouldShowCharityPrompt(order)) ...[
                  const SizedBox(height: 10),
                  _buildCharityPrompt(order),
                ],
              ],
              if (canCancel) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFED7AA)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Cancel available for ${_formatRemaining(secondsLeft)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF9A3412),
                              ),
                            ),
                          ),
                          Text(
                            '${(cancelProgress * 100).round()}%',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: cancelProgress,
                        minHeight: 6,
                        backgroundColor: const Color(0xFFFFEDD5),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFF97316),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: isCancelBusy
                              ? null
                              : () => _cancelOrder(order),
                          icon: isCancelBusy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFFF97316),
                                  ),
                                )
                              : const Icon(Icons.cancel_rounded, size: 16),
                          label: Text(
                            isCancelBusy ? 'Cancelling...' : 'Cancel Order',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFF97316),
                            side: const BorderSide(color: Color(0xFFFED7AA)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              // ── Bottom row: total + action ──
              Row(
                children: [
                  Text(
                    'Rs. $total',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: isCancelled
                          ? Colors.grey[400]
                          : const Color(0xFF1A1A1A),
                      decoration: isCancelled
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                    ),
                  ),
                  const Spacer(),
                  if (isCancelled)
                    _actionButton(
                      icon: Icons.help_outline_rounded,
                      label: 'Get Help',
                      color: Colors.grey,
                      onTap: () {},
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── History Mini Card (compact style for active tab) ───────────────────────

  Widget _buildHistoryMiniCard(Map<String, dynamic> order) {
    final status = (order['status'] ?? 'delivered').toString();
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final shopName = order['shopName'] ?? order['shop'] ?? 'Unknown Shop';
    final statusColor = _statusColor(status);
    final isDelivered = status.toLowerCase() == 'delivered';

    return GestureDetector(
      onTap: () => _showOrderDetails(order),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[100]!),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: isDelivered
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isDelivered ? Icons.check_circle_rounded : Icons.cancel_rounded,
                color: statusColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shopName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Color(0xFF1A1A1A),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _getOrderDate(order),
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
            Text(
              'Rs. $total',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => _reorderOrder(order),
              icon: const Icon(Icons.replay_rounded, size: 20),
              color: _primary,
              tooltip: 'Reorder',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Status Steps ─────────────────────────────────────────────────────────────

  Widget _buildStatusSteps(String status, Map<String, dynamic> order) {
    final visibleStatus = _customerVisibleStatus(status);
    
    int stage = 0;
    if (visibleStatus == 'pending') stage = 0;
    else if (visibleStatus == 'preparing') stage = 2;
    else if (visibleStatus == 'on_the_way') stage = 3;
    else if (visibleStatus == 'delivered') stage = 4;

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDeliveryStep(Icons.check, 'Order\nPlaced', 0, stage, isFirst: true),
            _buildDeliveryStep(Icons.restaurant, 'Order\nConfirmed', 1, stage),
            _buildDeliveryStep(Icons.soup_kitchen, 'Preparing\nFood', 2, stage),
            _buildDeliveryStep(Icons.moped, 'Out for\nDelivery', 3, stage),
            _buildDeliveryStep(Icons.home_outlined, 'Delivered', 4, stage, isLast: true),
          ],
        ),
        const SizedBox(height: 24),
        _buildDeliveryInfoCard(stage, order),
      ],
    );
  }

  Widget _buildDeliveryStep(IconData icon, String title, int stepIndex, int currentStage, {bool isLast = false, bool isFirst = false}) {
    bool isCompleted = stepIndex < currentStage;
    bool isCurrent = stepIndex == currentStage;
    
    Color bgColor;
    Color iconColor;
    Color? borderColor;

    if (isCompleted) {
      bgColor = const Color(0xFF0C6B40); // Dark Green
      iconColor = Colors.white;
    } else if (isCurrent) {
      bgColor = const Color(0xFFFF6B00); // Orange
      iconColor = Colors.white;
      borderColor = const Color(0xFFFFE6D5); // Light orange
    } else {
      bgColor = Colors.grey.shade200;
      iconColor = Colors.grey.shade500;
    }

    Widget dot = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: iconColor, size: 20),
    );

    Widget wrappedDot;
    if (isCurrent) {
      wrappedDot = Container(
        width: 48,
        height: 48,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: borderColor,
          shape: BoxShape.circle,
        ),
        child: dot,
      );
    } else {
      wrappedDot = SizedBox(
        width: 48,
        height: 48,
        child: Center(child: dot),
      );
    }

    Color leftLineColor = isFirst ? Colors.transparent : (stepIndex <= currentStage ? const Color(0xFF0C6B40) : Colors.grey.shade300);
    Color rightLineColor = isLast ? Colors.transparent : (stepIndex < currentStage ? const Color(0xFF0C6B40) : Colors.grey.shade300);

    return Expanded(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Container(height: 3, color: leftLineColor)),
              wrappedDot,
              Expanded(child: Container(height: 3, color: rightLineColor)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: (isCurrent || isCompleted) ? FontWeight.bold : FontWeight.w600,
              color: isCurrent ? const Color(0xFFB54C00) : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliveryInfoCard(int stage, Map<String, dynamic> order) {
    String timeInfo = '';
    if (stage < 4) {
      int estMinutes = (order['estimatedTime'] ?? 40) as int;
      if ((order['deliveryOption'] ?? '') == 'Fast') {
        estMinutes = (estMinutes * 0.6).round();
      }
      final ts = order['timestamp'] ?? order['createdAt'] ?? DateTime.now().millisecondsSinceEpoch;
      final orderTime = DateTime.fromMillisecondsSinceEpoch(int.tryParse(ts.toString()) ?? DateTime.now().millisecondsSinceEpoch);
      final estTime = orderTime.add(Duration(minutes: estMinutes));
      timeInfo = "Estimated delivery at ${DateFormat('h:mm a').format(estTime)}.";
    }

    String message = '';
    if (stage == 0) {
      message = "Your order has been placed successfully and is waiting for confirmation. $timeInfo";
    } else if (stage == 1) {
      message = "The restaurant has confirmed your order and will start preparing it soon. $timeInfo";
    } else if (stage == 2) {
      message = "Chef is preparing your delicious meal with extra care. $timeInfo";
    } else if (stage == 3) {
      message = "Your order is out for delivery! Our rider is on the way. $timeInfo";
    } else if (stage == 4) {
      message = "Your order has been delivered successfully. Enjoy your meal!";
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF9F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: Color(0xFFB54C00), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF5A3C2A),
                fontSize: 13,
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Order Details Bottom Sheet ───────────────────────────────────────────

  void _showOrderDetails(Map<String, dynamic> order) {
    final status = (order['status'] ?? 'pending').toString();
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final shopName = order['shopName'] ?? order['shop'] ?? 'Unknown Shop';
    final rawId = (order['id'] ?? '').toString();
    final shortId = rawId.length >= 6
        ? rawId.substring(0, 6).toUpperCase()
        : rawId.toUpperCase();
    final statusColor = _statusColor(status);
    final isCustom = order['type'] == 'custom';

    List<Map<String, dynamic>> items = [];
    final rawItems = order['items'];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) items.add(Map<String, dynamic>.from(it));
      }
    }

    final groupedShopItems = <String, List<Map<String, dynamic>>>{};
    final groupedShopNames = <String, String>{};
    for (final item in items) {
      final itemShopId = (item['shopId'] ?? '').toString().trim();
      final rawItemShopName = (item['shopName'] ?? shopName).toString().trim();
      final itemShopName = rawItemShopName.isEmpty
          ? shopName.toString()
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        minChildSize: 0.35,
        expand: false,
        snap: true,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Order #$shortId',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _getOrderDate(order),
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
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _statusIcon(status),
                            color: statusColor,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatStatus(status),
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Divider(color: Colors.grey[100]),
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                  children: [
                    // Shop info
                    // Shop info, Items, and Custom Orders hidden as per request

                    // Delivery
                    if (order['address'] != null &&
                        order['address'].toString().isNotEmpty) ...[
                      _detailSection(
                        'Delivery',
                        Icons.location_on_rounded,
                        Colors.red,
                      ),
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red[50],
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.location_on_outlined,
                              size: 16,
                              color: Colors.red[400],
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                order['address'].toString(),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[700],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (order['deliverySpeed'] != null)
                      _detailRow(
                        Icons.speed,
                        'Speed',
                        order['deliverySpeed'].toString(),
                      ),
                    if (order['deliveryInstructions'] != null &&
                        order['deliveryInstructions'].toString().isNotEmpty)
                      _detailRow(
                        Icons.note_outlined,
                        'Instructions',
                        order['deliveryInstructions'].toString(),
                      ),

                    // Payment
                    _detailSection(
                      'Payment',
                      Icons.payment_rounded,
                      Colors.green,
                    ),
                    _detailRow(
                      Icons.payment_outlined,
                      'Method',
                      order['paymentMethod'] ?? 'COD',
                    ),
                    // Detailed breakdown hidden as per request

                    // Grand total
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _primary.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.receipt_long_rounded,
                            color: _primary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Grand Total',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'Rs. $total',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                              color: _primary,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Status timeline
                    if (status.toLowerCase() != 'cancelled' &&
                        status.toLowerCase() != 'canceled') ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Delivery Progress',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildStatusSteps(status, order),
                      Builder(
                        builder: (_) {
                          final anim = _buildStatusAnimation(status);
                          if (anim is SizedBox) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: anim,
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailSection(String title, IconData icon, Color color) {
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

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
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
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: Colors.orange[50],
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: Colors.orange[200]),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  void _showOrderDetailsSheet(Map<String, dynamic> order) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        expand: false,
        snap: true,
        builder: (_, scrollController) => _UserOrderDetailSheet(
          order: order,
          scrollController: scrollController,
        ),
      ),
    );
  }
}

class _UserOrderDetailSheet extends StatelessWidget {
  final Map<String, dynamic> order;
  final ScrollController scrollController;
  const _UserOrderDetailSheet({
    required this.order,
    required this.scrollController,
  });

  String _formatStatus(String status) {
    final normalized = status.toLowerCase().trim();
    if (normalized == 'on_way' || normalized == 'out_for_delivery') {
      return 'On the way';
    }
    if (normalized == 'picked' || normalized == 'preparing') {
      return 'Preparing';
    }
    if (normalized == 'delivered') return 'Delivered';
    if (normalized == 'cancelled' || normalized == 'canceled') {
      return 'Cancelled';
    }
    return 'Order Placed';
  }

  @override
  Widget build(BuildContext context) {
    final status = (order['status'] ?? 'pending').toString();
    final isCustom = order['orderType'] == 'custom';
    final shopName = order['shopName'] ?? order['shop'] ?? 'Unknown Shop';
    final customOrderId = (order['customOrderId'] ?? order['id'] ?? '')
        .toString();
    final createdAtMs =
        int.tryParse(order['createdAt']?.toString() ?? '0') ?? 0;
    final dateStr = createdAtMs > 0
        ? DateFormat(
            'dd MMM yyyy, h:mm a',
          ).format(DateTime.fromMillisecondsSinceEpoch(createdAtMs))
        : '';

    final deliveryFee = (order['deliveryFee'] ?? 0).toString();
    final grandTotal = (order['grandTotal'] ?? order['budget'] ?? 0).toString();
    final subtotal = (order['subtotal'] ?? 0).toString();

    final resolvedAddress = (order['address'] ??
            order['fullAddress'] ??
            order['manualAddress'] ??
            order['autoAddressFormatted'] ??
            order['autoAddress'] ??
            order['deliveryAddress'] ??
            '')
        .toString()
        .trim();
    final address = resolvedAddress.isEmpty
        ? 'No address provided'
        : resolvedAddress;

    List<Map<String, dynamic>> itemsList = [];
    final rawItems = order['items'];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) itemsList.add(Map<String, dynamic>.from(it));
      }
    }

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Order Details',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.grey),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                // Header Info
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '#$customOrderId',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF6B00),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _formatStatus(status),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFA04100),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  dateStr,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 24),

                // Shop Info
                const Text(
                  'Shop',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  shopName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1D130C),
                  ),
                ),

                const SizedBox(height: 24),
                const Divider(height: 1, color: Color(0xFFF0F0F0)),
                const SizedBox(height: 24),

                // Items
                const Text(
                  'Order Items',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1D130C),
                  ),
                ),
                const SizedBox(height: 12),
                if (isCustom)
                  Text(
                    order['whatYouWant']?.toString() ??
                        'Custom Order Details not available',
                    style: const TextStyle(fontSize: 15, color: Colors.black87),
                  )
                else
                  ...itemsList.map((item) {
                    final qty = item['quantity'] ?? 1;
                    final name = item['name'] ?? item['productName'] ?? 'Item';
                    final variant = item['variant'] ?? item['variation'];
                    final price = item['price'] ?? 0;
                    final totalItemPrice = price * qty;

                    String title = '$qty x $name';
                    if (variant != null &&
                        variant.toString().isNotEmpty &&
                        variant.toString() != 'null') {
                      title += ' ($variant)';
                    }

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.black87,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Text(
                            'Rs $totalItemPrice',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1D130C),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),

                const SizedBox(height: 16),
                const Divider(height: 1, color: Color(0xFFF0F0F0)),
                const SizedBox(height: 16),

                // Summary
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Subtotal',
                      style: TextStyle(fontSize: 14, color: Colors.black54),
                    ),
                    Text(
                      'Rs $subtotal',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Delivery Fee',
                      style: TextStyle(fontSize: 14, color: Colors.black54),
                    ),
                    Text(
                      'Rs $deliveryFee',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1D130C),
                      ),
                    ),
                    Text(
                      'Rs $grandTotal',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFFF6B00),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),
                const Divider(height: 1, color: Color(0xFFF0F0F0)),
                const SizedBox(height: 24),

                // Address
                const Text(
                  'Delivery Address',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.location_on_rounded,
                      size: 20,
                      color: Color(0xFFFF6B00),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        address,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
