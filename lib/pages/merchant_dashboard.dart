import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import '../services/city_scope_service.dart';
import '../services/merchant_notification_service.dart';
import 'login_page.dart';

enum _MerchantOrderView {
  live,
  history,
}

class MerchantDashboard extends StatefulWidget {
  const MerchantDashboard({super.key});

  @override
  State<MerchantDashboard> createState() => _MerchantDashboardState();
}

class _MerchantDashboardState extends State<MerchantDashboard>
    with WidgetsBindingObserver {
  static const Color _primary = Color(0xFFFF6B00);
  static const String _fallbackAdminPhone = '03131426498';
  static const String _fallbackAdminEmail = 'ghartekinfo@gmail.com';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _loading = true;
  bool _merchantActive = true;
  int _currentIndex = 0;

  String _merchantName = 'Merchant';
  String _merchantEmail = '';
  String _merchantPhone = '';

  String _shopId = '';
  String _shopName = 'Shop';
  String _shopCategory = '';
  bool _shopOpen = true;
  bool _shopStatusUpdating = false;

  String _adminPhone = _fallbackAdminPhone;
  String _adminEmail = _fallbackAdminEmail;

  _MerchantOrderView _orderView = _MerchantOrderView.live;
  final Set<String> _updatingProductIds = <String>{};

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MerchantNotificationService().stopListening();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    await CityScopeService.ensureLoaded();
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);

    try {
      final results = await Future.wait([
        _db.child('users/$uid').get(),
        _db.child(_tenantPath('merchant_profiles/$uid')).get(),
        _db.child('merchant_profiles/$uid').get(),
        _db.child(_tenantPath('shops')).get(),
        _db.child(_tenantPath('settings/app-control')).get(),
      ]);

      final userSnap = results[0];
      final tenantProfileSnap = results[1];
      final globalProfileSnap = results[2];
      final shopsSnap = results[3];
      final appControlSnap = results[4];

      final user = userSnap.exists && userSnap.value is Map
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};
        final profileSource = tenantProfileSnap.exists
          ? tenantProfileSnap
          : globalProfileSnap;
        final profile = profileSource.exists && profileSource.value is Map
          ? Map<String, dynamic>.from(profileSource.value as Map)
          : <String, dynamic>{};

      final shopsMap = <String, Map<String, dynamic>>{};
      if (shopsSnap.exists && shopsSnap.value is Map) {
        final raw = shopsSnap.value as Map<dynamic, dynamic>;
        raw.forEach((key, value) {
          if (value is! Map) return;
          shopsMap[key.toString()] = Map<String, dynamic>.from(value);
        });
      }

      String linkedShopId = (user['shopId'] ?? '').toString();
      if (linkedShopId.isEmpty) {
        linkedShopId = (profile['primaryShopId'] ?? '').toString();
      }

      if (linkedShopId.isEmpty) {
        for (final entry in shopsMap.entries) {
          final merchantId = (entry.value['merchantId'] ?? '').toString();
          if (merchantId == uid) {
            linkedShopId = entry.key;
            break;
          }
        }
      }

      if (linkedShopId.isEmpty && profile['assignedShopIds'] is Map) {
        final assigned = profile['assignedShopIds'] as Map<dynamic, dynamic>;
        for (final entry in assigned.entries) {
          if (entry.value == true) {
            linkedShopId = entry.key.toString();
            break;
          }
        }
      }

      final linkedShop = linkedShopId.isNotEmpty ? shopsMap[linkedShopId] : null;

      final appControl = appControlSnap.exists && appControlSnap.value is Map
          ? Map<String, dynamic>.from(appControlSnap.value as Map)
          : <String, dynamic>{};

      final supportPhone = _firstNonEmpty(<String?>[
        appControl['adminPhone']?.toString(),
        appControl['supportPhone']?.toString(),
        appControl['contactPhone']?.toString(),
      ]);

      final supportEmail = _firstNonEmpty(<String?>[
        appControl['adminEmail']?.toString(),
        appControl['supportEmail']?.toString(),
        appControl['contactEmail']?.toString(),
      ]);

      if (!mounted) return;
      setState(() {
        _merchantName = (profile['ownerName'] ?? user['name'] ?? 'Merchant').toString();
        _merchantEmail = (profile['email'] ?? user['email'] ?? _auth.currentUser?.email ?? '').toString();
        _merchantPhone = (profile['phoneNumber'] ?? user['phoneNumber'] ?? '').toString();

        _merchantActive = (profile['isActive'] ?? user['isMerchantActive'] ?? true) == true;

        _shopId = linkedShopId;
        _shopName = (linkedShop?['name'] ?? 'Shop').toString();
        _shopCategory = (linkedShop?['category'] ?? '').toString();
        _shopOpen = linkedShop != null
          ? (linkedShop['isOpen'] != false &&
            (linkedShop['status'] ?? '').toString().toLowerCase() != 'closed')
          : true;

        _adminPhone = supportPhone.isEmpty ? _fallbackAdminPhone : supportPhone;
        _adminEmail = supportEmail.isEmpty ? _fallbackAdminEmail : supportEmail;

        _loading = false;
      });

      if (_shopId.isNotEmpty) {
        unawaited(
          MerchantNotificationService().startListening(
            merchantUid: uid,
            assignedShopIds: {_shopId},
          ),
        );
      } else {
        MerchantNotificationService().stopListening();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final text = (value ?? '').trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  Stream<DatabaseEvent> _ordersStream() {
    if (_shopId.isEmpty) {
      return _db.child(_tenantPath('shop-orders')).limitToFirst(0).onValue;
    }
    return _db.child(_tenantPath('shop-orders')).onValue;
  }

  bool _belongsToCurrentShop(Map<String, dynamic> order) {
    if (_shopId.isEmpty) return false;

    final directShopId = (order['shopId'] ?? '').toString().trim();
    if (directShopId == _shopId) return true;

    if (order['items'] is List) {
      for (final raw in order['items'] as List) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final itemShopId = (item['shopId'] ?? '').toString().trim();
        if (itemShopId == _shopId) return true;
      }
    }

    return false;
  }

  Stream<DatabaseEvent> _productsStream() {
    if (_shopId.isEmpty) {
      return _db.child(_tenantPath('shops')).limitToFirst(0).onValue;
    }
    return _db.child(_tenantPath('shops/$_shopId/menu')).onValue;
  }

  int _toTimestamp(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '0') ?? 0;
  }

  bool _isDelivered(String status) {
    return status == 'delivered';
  }

  bool _isCancelled(String status) {
    return status == 'cancelled' || status == 'canceled' || status == 'rejected';
  }

  bool _isPendingAdmin(String status) {
    return status == 'pending' || status == 'pending_admin' || status == 'admin_pending';
  }

  String _formatStatus(String status) {
    final normalized = status.trim().toLowerCase();
    switch (normalized) {
      case 'on_the_way':
        return 'On The Way';
      case 'merchant_pending':
        return 'Waiting For Merchant';
      case 'merchant_cancel_requested':
        return 'Cancel Requested';
      default:
        if (normalized.isEmpty) return 'Unknown';
        return normalized
            .split('_')
            .map((e) => e.isEmpty ? e : '${e[0].toUpperCase()}${e.substring(1)}')
            .join(' ');
    }
  }

  Color _statusColor(String status) {
    final normalized = status.toLowerCase();
    if (_isDelivered(normalized)) return const Color(0xFF16A34A);
    if (_isCancelled(normalized)) return const Color(0xFFDC2626);
    if (_isPendingAdmin(normalized)) return const Color(0xFFF59E0B);
    if (normalized == 'preparing') return const Color(0xFF7C3AED);
    if (normalized == 'confirmed') return const Color(0xFF0EA5E9);
    if (normalized == 'on_the_way' || normalized == 'out_for_delivery') {
      return const Color(0xFF0284C7);
    }
    return const Color(0xFF6B7280);
  }

  Future<void> _setProductActive({
    required String productId,
    required bool active,
    required bool outOfStock,
  }) async {
    if (_shopId.isEmpty || productId.isEmpty) return;

    setState(() => _updatingProductIds.add(productId));
    try {
      await _db.child(_tenantPath('shops/$_shopId/menu/$productId')).update({
        'isVisible': active,
        'available': active && !outOfStock,
        'isAvailable': active && !outOfStock,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } finally {
      if (mounted) {
        setState(() => _updatingProductIds.remove(productId));
      }
    }
  }

  Future<void> _setOutOfStock({
    required String productId,
    required bool outOfStock,
    required bool active,
  }) async {
    if (_shopId.isEmpty || productId.isEmpty) return;

    setState(() => _updatingProductIds.add(productId));
    try {
      await _db.child(_tenantPath('shops/$_shopId/menu/$productId')).update({
        'outOfStock': outOfStock,
        'available': active && !outOfStock,
        'isAvailable': active && !outOfStock,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } finally {
      if (mounted) {
        setState(() => _updatingProductIds.remove(productId));
      }
    }
  }

  Future<void> _setShopOpenStatus(bool open) async {
    if (_shopId.isEmpty || _shopStatusUpdating) return;

    setState(() => _shopStatusUpdating = true);
    try {
      await _db.child(_tenantPath('shops/$_shopId')).update({
        'isOpen': open,
        'status': open ? 'open' : 'closed',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });

      if (!mounted) return;
      setState(() => _shopOpen = open);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(open
              ? 'Shop is now OPEN for customers.'
              : 'Shop is now CLOSED for customers.'),
          backgroundColor: open ? const Color(0xFF16A34A) : Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _shopStatusUpdating = false);
      }
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout', style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text('Are you sure you want to logout from merchant account?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Logout', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    await AuthService().signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  Future<void> _callAdmin() async {
    final digits = _adminPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) return;
    final uri = Uri.parse('tel:$digits');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _emailAdmin() async {
    if (_adminEmail.trim().isEmpty) return;
    final uri = Uri.parse('mailto:${_adminEmail.trim()}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Widget _buildSuspendedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.block_rounded, color: Colors.orange, size: 62),
            const SizedBox(height: 12),
            const Text(
              'Merchant account is disabled',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Contact admin: $_adminPhone',
              style: TextStyle(color: Colors.grey.shade700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Logout'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrdersTab() {
    return StreamBuilder<DatabaseEvent>(
      stream: _ordersStream(),
      builder: (context, snapshot) {
        final orders = <Map<String, dynamic>>[];

        if (snapshot.hasData && snapshot.data!.snapshot.exists) {
          final raw = snapshot.data!.snapshot.value;
          if (raw is Map) {
            final data = raw;
            data.forEach((key, value) {
              if (value is! Map) return;
              final order = Map<String, dynamic>.from(value);
              final status = (order['status'] ?? '').toString().toLowerCase();
              if (_isPendingAdmin(status)) return;
              if (!_belongsToCurrentShop(order)) return;

              order['id'] = key.toString();
              orders.add(order);
            });
          }
        }

        orders.sort((a, b) {
          final at = _toTimestamp(a['createdAt']);
          final bt = _toTimestamp(b['createdAt']);
          return bt.compareTo(at);
        });

        final visibleOrders = _orderView == _MerchantOrderView.live
            ? orders.where((o) {
                final st = (o['status'] ?? '').toString().toLowerCase();
                return !_isDelivered(st) && !_isCancelled(st);
              }).toList()
            : orders.where((o) {
                final st = (o['status'] ?? '').toString().toLowerCase();
                return _isDelivered(st);
              }).toList();

        return RefreshIndicator(
          onRefresh: _bootstrap,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.orange.shade100),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _shopName,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    if (_shopCategory.trim().isNotEmpty)
                      Text(
                        _shopCategory,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _orderModeButton(
                            title: 'Active Orders',
                            active: _orderView == _MerchantOrderView.live,
                            onTap: () => setState(() => _orderView = _MerchantOrderView.live),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _orderModeButton(
                            title: 'History',
                            active: _orderView == _MerchantOrderView.history,
                            onTap: () => setState(() => _orderView = _MerchantOrderView.history),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (visibleOrders.isEmpty)
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Text(
                    _orderView == _MerchantOrderView.live
                        ? 'No confirmed orders yet.'
                        : 'No delivered orders in history yet.',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
              ...visibleOrders.map(_orderCard),
            ],
          ),
        );
      },
    );
  }

  Widget _orderModeButton({
    required String title,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? _primary : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? Colors.white : Colors.grey.shade800,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> order) {
    final status = (order['status'] ?? '').toString().toLowerCase();
    final statusColor = _statusColor(status);
    final orderId = (order['customOrderId'] ?? order['id'] ?? '').toString();
    final createdAt = _toTimestamp(order['createdAt']);
    final when = createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(createdAt)
        : DateTime.now();

    final allItems = <Map<String, dynamic>>[];
    if (order['items'] is List) {
      for (final raw in order['items'] as List) {
        if (raw is Map) {
          allItems.add(Map<String, dynamic>.from(raw));
        }
      }
    }

    final hasMixedShopItems = allItems.any((item) {
      final itemShopId = (item['shopId'] ?? '').toString().trim();
      return itemShopId.isNotEmpty && itemShopId != _shopId;
    });

    final items = hasMixedShopItems
        ? allItems.where((item) {
            final itemShopId = (item['shopId'] ?? '').toString().trim();
            return itemShopId.isEmpty || itemShopId == _shopId;
          }).toList()
        : allItems;

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final scopedSubtotal = items.fold<double>(0.0, (sum, item) {
      final price = double.tryParse((item['price'] ?? 0).toString()) ?? 0.0;
      final qty = double.tryParse((item['quantity'] ?? 1).toString()) ?? 1.0;
      return sum + (price * qty);
    });

    final totalValue = hasMixedShopItems && scopedSubtotal > 0
        ? scopedSubtotal
        : (double.tryParse((order['grandTotal'] ?? order['budget'] ?? 0).toString()) ?? 0);
    final total = totalValue.toStringAsFixed(0);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Order #${orderId.length > 8 ? orderId.substring(0, 8) : orderId}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _formatStatus(status),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Customer: ${(order['userName'] ?? order['userEmail'] ?? '-').toString()}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          Text(
            'Phone: ${(order['userPhone'] ?? order['contact'] ?? '-').toString()}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          Text(
            'Address: ${(order['fullAddress'] ?? order['address'] ?? '-').toString()}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 6),
          Text(
            'Placed: ${when.day}/${when.month}/${when.year} ${_two(when.hour)}:${_two(when.minute)}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          if (items.isNotEmpty)
            ...items.take(4).map((item) {
              final qty = item['quantity'] ?? 1;
              final name = (item['name'] ?? 'Item').toString();
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '$qty x $name',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                ),
              );
            }),
          const SizedBox(height: 8),
          Text(
            'Total: Rs. $total',
            style: const TextStyle(fontWeight: FontWeight.w800, color: _primary),
          ),
        ],
      ),
    );
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  Widget _buildProductsTab() {
    return StreamBuilder<DatabaseEvent>(
      stream: _productsStream(),
      builder: (context, snapshot) {
        final products = <Map<String, dynamic>>[];

        if (snapshot.hasData && snapshot.data!.snapshot.exists) {
          final raw = snapshot.data!.snapshot.value;
          if (raw is Map) {
            final map = raw;
            map.forEach((key, value) {
              if (value is! Map) return;
              final item = Map<String, dynamic>.from(value);
              item['id'] = key.toString();
              products.add(item);
            });
          }
        }

        products.sort((a, b) {
          final an = (a['name'] ?? '').toString().toLowerCase();
          final bn = (b['name'] ?? '').toString().toLowerCase();
          return an.compareTo(bn);
        });

        return RefreshIndicator(
          onRefresh: _bootstrap,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.orange.shade100),
                ),
                child: const Text(
                  'Inactive product customer ko show nahi hoga. Out of stock product show hoga, lekin unavailable label ke saath.',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 12),
              if (products.isEmpty)
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Text(
                    'No products found in this shop menu.',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
              ...products.map((item) {
                final id = (item['id'] ?? '').toString();
                final active = item['isVisible'] != false;
                final outOfStock = item['outOfStock'] == true;
                final updating = _updatingProductIds.contains(id);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              (item['name'] ?? 'Product').toString(),
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                            ),
                          ),
                          if (outOfStock)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'Out of Stock',
                                style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.w700),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Rs. ${(item['price'] ?? 0).toString()}',
                        style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                const Text('Active', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                const Spacer(),
                                Switch(
                                  value: active,
                                  activeThumbColor: _primary,
                                  onChanged: updating
                                      ? null
                                      : (v) => _setProductActive(
                                            productId: id,
                                            active: v,
                                            outOfStock: outOfStock,
                                          ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Row(
                              children: [
                                const Text('Out of Stock', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                                const Spacer(),
                                Switch(
                                  value: outOfStock,
                                  activeThumbColor: Colors.red,
                                  onChanged: updating
                                      ? null
                                      : (v) => _setOutOfStock(
                                            productId: id,
                                            outOfStock: v,
                                            active: active,
                                          ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Merchant Profile', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Name: $_merchantName'),
              Text('Email: ${_merchantEmail.isEmpty ? '-' : _merchantEmail}'),
              Text('Phone: ${_merchantPhone.isEmpty ? '-' : _merchantPhone}'),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Text('Shop: $_shopName', style: const TextStyle(fontWeight: FontWeight.w700)),
              if (_shopCategory.trim().isNotEmpty)
                Text('Category: $_shopCategory'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Contact Admin', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Phone: $_adminPhone'),
              Text('Email: $_adminEmail'),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _callAdmin,
                      icon: const Icon(Icons.call_rounded),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _emailAdmin,
                      icon: const Icon(Icons.email_outlined),
                      label: const Text('Email'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _logout,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            label: const Text('Logout', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _buildShopStatusControlBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: (_shopOpen ? const Color(0xFF16A34A) : Colors.red)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _shopOpen ? Icons.storefront_rounded : Icons.store_mall_directory_outlined,
              size: 18,
              color: _shopOpen ? const Color(0xFF16A34A) : Colors.red,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Shop Visibility',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
                Text(
                  _shopOpen ? 'OPEN - customers can place orders' : 'CLOSED - ordering is blocked',
                  style: TextStyle(
                    fontSize: 11,
                    color: _shopOpen ? const Color(0xFF16A34A) : Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (_shopStatusUpdating)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch(
              value: _shopOpen,
              activeThumbColor: _primary,
              onChanged: _setShopOpenStatus,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _primary)),
      );
    }

    if (!_merchantActive) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Merchant Account'),
          backgroundColor: _primary,
          foregroundColor: Colors.white,
        ),
        body: _buildSuspendedView(),
      );
    }

    if (_shopId.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Merchant Dashboard'),
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          actions: [
            IconButton(onPressed: _bootstrap, icon: const Icon(Icons.refresh_rounded)),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.store_mall_directory_outlined, size: 62, color: Colors.grey),
                const SizedBox(height: 12),
                const Text(
                  'No shop linked to this merchant account yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please contact admin on $_adminPhone',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Logout'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final pages = [
      _buildOrdersTab(),
      _buildProductsTab(),
      _buildSettingsTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentIndex == 0
              ? 'Orders • $_shopName'
              : _currentIndex == 1
                  ? 'Products • $_shopName'
                  : 'Settings',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: _bootstrap, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: Column(
        children: [
          _buildShopStatusControlBar(),
          Expanded(child: pages[_currentIndex]),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: _primary,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_rounded), label: 'Orders'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2_rounded), label: 'Products'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
      ),
    );
  }
}