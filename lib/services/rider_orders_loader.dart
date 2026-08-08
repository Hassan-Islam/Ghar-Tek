import 'package:ghartek_flutter_app/services/db/app_database.dart';

import 'city_scope_service.dart';

/// Fast rider order reads — uses indexed child queries instead of full trees.
class RiderOrdersLoader {
  static String _tenantPath(String path) => CityScopeService.tenantPath(path);

  static String normalizeStatus(dynamic rawStatus) {
    final status = (rawStatus ?? 'pending').toString().toLowerCase().trim();
    if (status == 'on_way' || status == 'out_for_delivery') {
      return 'on_the_way';
    }
    if (status == 'confirmed' || status == 'preparing') {
      return 'available';
    }
    return status;
  }

  static bool _isTerminalStatus(String status) {
    return status == 'delivered' ||
        status == 'cancelled' ||
        status == 'canceled';
  }

  static bool _cityScopeSynced = false;

  /// Ensures rider UI reads `tenants/{userCity}/...`, not a stale prefs city.
  ///
  /// The profile city is fetched from the network only once per session; every
  /// later call just loads the cached city locally. This avoids an extra
  /// `users/$uid` network round-trip on every order refresh (which was making
  /// the rider dashboard slow).
  static Future<void> ensureRiderCityScope(String riderId) async {
    if (_cityScopeSynced || riderId.trim().isEmpty) {
      await CityScopeService.ensureLoaded();
      return;
    }
    await CityScopeService.syncCityFromUserProfile(riderId, role: 'rider');
    _cityScopeSynced = true;
  }

  static bool isRelevantForRider(
    Map<String, dynamic> order,
    String riderId,
  ) {
    final status = normalizeStatus(order['status']);
    final assigned = (order['assignedRider'] ?? '').toString().trim();

    if (status == 'available' ||
        status == 'confirmed' ||
        status == 'preparing') {
      return true;
    }
    if (status == 'picked' && assigned.isEmpty) return true;
    if (riderId.isNotEmpty && assigned == riderId) {
      return !_isTerminalStatus(status) || status == 'delivered';
    }
    return false;
  }

  /// Active statuses that belong in the rider "New" / "Active" tabs. Delivered
  /// and cancelled orders are intentionally excluded — those load on demand.
  static const List<String> _activeStatuses = <String>[
    'available',
    'confirmed',
    'preparing',
    'picked',
    'on_the_way',
    'out_for_delivery',
    'on_way',
  ];

  static void _mergeSnapshotInto(
    Map<String, Map<String, dynamic>> byId,
    DataSnapshot snap,
  ) {
    if (!snap.exists || snap.value is! Map) return;
    (snap.value as Map).forEach((key, val) {
      if (val is! Map) return;
      final order = Map<String, dynamic>.from(val);
      order['id'] = key.toString();
      order['orderType'] = 'shop';
      byId[key.toString()] = order;
    });
  }

  static void _sortByCreatedDesc(List<Map<String, dynamic>> orders) {
    orders.sort((a, b) {
      final at = a['createdAtClient'] ?? a['createdAt'];
      final bt = b['createdAtClient'] ?? b['createdAt'];
      if (at is int && bt is int) return bt.compareTo(at);
      return 0;
    });
  }

  /// Loads ONLY active orders for the rider (pool + this rider's active
  /// assignments). Delivered/cancelled orders are excluded so the screen opens
  /// fast — they are fetched separately via [fetchDeliveredOrders] only when the
  /// rider opens the Delivered tab.
  ///
  /// Uses server-side indexed queries (small payload) instead of downloading the
  /// entire `shop-orders` tree. This is safe now that the data layer never falls
  /// back to Firebase — an empty result means genuinely no matching orders.
  static Future<List<Map<String, dynamic>>> fetchActiveOrders(
    String riderId,
  ) async {
    await ensureRiderCityScope(riderId);
    final base = FirebaseDatabase.instance.ref().child(_tenantPath('shop-orders'));

    final queries = <Query>[
      for (final s in _activeStatuses) base.orderByChild('status').equalTo(s),
      if (riderId.isNotEmpty)
        base.orderByChild('assignedRider').equalTo(riderId),
    ];

    final byId = <String, Map<String, dynamic>>{};
    await Future.wait(queries.map((q) async {
      try {
        _mergeSnapshotInto(byId, await q.get());
      } catch (_) {}
    }));

    final orders = <Map<String, dynamic>>[];
    for (final order in byId.values) {
      final status = normalizeStatus(order['status']);
      if (_isTerminalStatus(status)) continue; // no delivered/cancelled here
      if (!isRelevantForRider(order, riderId)) continue;
      orders.add(order);
    }
    _sortByCreatedDesc(orders);
    return orders;
  }

  /// Loads this rider's delivered orders on demand (Delivered tab / earnings).
  static Future<List<Map<String, dynamic>>> fetchDeliveredOrders(
    String riderId,
  ) async {
    if (riderId.trim().isEmpty) return <Map<String, dynamic>>[];
    await ensureRiderCityScope(riderId);
    final base = FirebaseDatabase.instance.ref().child(_tenantPath('shop-orders'));

    final byId = <String, Map<String, dynamic>>{};
    try {
      _mergeSnapshotInto(
        byId,
        await base.orderByChild('assignedRider').equalTo(riderId).get(),
      );
    } catch (_) {}

    final orders = <Map<String, dynamic>>[];
    for (final order in byId.values) {
      if (normalizeStatus(order['status']) == 'delivered') orders.add(order);
    }
    _sortByCreatedDesc(orders);
    return orders;
  }

  /// Loads all orders relevant to the rider UI including delivered assignments.
  ///
  /// Kept for callers that still need the full relevant set in one shot.
  static Future<List<Map<String, dynamic>>> fetchRelevantOrders(
    String riderId,
  ) async {
    await ensureRiderCityScope(riderId);
    final db = FirebaseDatabase.instance.ref();

    final byId = <String, Map<String, dynamic>>{};
    final fullSnap = await db.child(_tenantPath('shop-orders')).get();
    if (fullSnap.exists && fullSnap.value is Map) {
      final data = fullSnap.value as Map<dynamic, dynamic>;
      data.forEach((key, val) {
        if (val is! Map) return;
        final order = Map<String, dynamic>.from(val);
        if (!isRelevantForRider(order, riderId)) return;
        order['id'] = key.toString();
        order['orderType'] = 'shop';
        byId[key.toString()] = order;
      });
    }

    final orders = byId.values.toList();
    _sortByCreatedDesc(orders);
    return orders;
  }

  /// Seeds notification listener with current available order ids only.
  static Future<Set<String>> fetchAvailableOrderIds({String? riderId}) async {
    if (riderId != null && riderId.isNotEmpty) {
      await ensureRiderCityScope(riderId);
    } else {
      await CityScopeService.ensureLoaded();
    }
    final db = FirebaseDatabase.instance.ref();
    final ids = <String>{};
    final fullSnap = await db.child(_tenantPath('shop-orders')).get();
    if (fullSnap.exists && fullSnap.value is Map) {
      (fullSnap.value as Map).forEach((key, val) {
        if (val is! Map) return;
        final status = normalizeStatus(val['status']);
        if (status == 'available') ids.add(key.toString());
      });
    }
    return ids;
  }
}
