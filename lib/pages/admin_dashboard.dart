import 'dart:async';
import 'dart:math' show sin, pi;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'admin_shops_page.dart';
import 'admin_orders_page.dart';
import 'admin_users_page.dart';
import 'admin_khata_page.dart';
import 'admin_notifications_page.dart';
import 'admin_chats_page.dart';
import 'admin_settings_page.dart';
import 'admin_app_settings_page.dart';
import 'admin_category_images_page.dart';
import 'admin_merchant_management_page.dart';
import 'login_page.dart';
import '../services/auth_service.dart';
import '../services/city_scope_service.dart';

String _tenantPath(String path) => CityScopeService.tenantPath(path);

class _AdminTabConfig {
  final IconData icon;
  final String label;
  final Widget page;
  final int badge;

  const _AdminTabConfig({
    required this.icon,
    required this.label,
    required this.page,
    this.badge = 0,
  });
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  static const Color _primary = Color(0xFFFF6B00);
  static const Set<String> _superAdminEmails = {
    'qa568581@gmail.com',
    'arshadahsan77900@gmail.com',
    'raf451810@gmail.com',
    'waqaraliwebs@gmail.com',
  };

  int _currentIndex = 0;

  final Widget _khataPage = const AdminKhataPage();
  final Widget _ordersPage = const AdminOrdersPage();
  final Widget _shopsPage = const AdminShopsPage();
  final Widget _morePage = const _AdminMorePage();

  Map<String, dynamic> _permissions = {};
  bool _isSuperAdmin = false;
  bool _permissionsLoaded = false;
  StreamSubscription<DatabaseEvent>? _unreadAdminChatsSub;
  int _unreadAdminChatCount = 0;

  @override
  void initState() {
    super.initState();
    _initTenantScope();
  }

  Future<void> _initTenantScope() async {
    await CityScopeService.ensureLoaded();
    await _loadPermissions();
    if (!mounted) return;
    _listenUnreadAdminChats();
  }

  Future<void> _loadPermissions() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _permissions = {};
          _isSuperAdmin = false;
          _permissionsLoaded = true;
        });
      }
      return;
    }

    final isSuperAdmin = _superAdminEmails.contains(
      (user.email ?? '').toLowerCase(),
    );
    Map<String, dynamic> perms = {};

    if (!isSuperAdmin) {
      try {
        final snap = await FirebaseDatabase.instance
            .ref('users/${user.uid}')
            .get();
        if (snap.exists && snap.value is Map) {
          final userData = Map<String, dynamic>.from(snap.value as Map);
          if (userData['permissions'] is Map) {
            perms = Map<String, dynamic>.from(userData['permissions'] as Map);
          }
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _isSuperAdmin = isSuperAdmin;
      _permissions = perms;
      _permissionsLoaded = true;
      final tabs = _visibleTabs();
      if (_currentIndex >= tabs.length) {
        _currentIndex = tabs.length - 1;
      }
      if (_currentIndex < 0) {
        _currentIndex = 0;
      }
    });
  }

  bool _hasPerm(String key) =>
      _isSuperAdmin || (_permissions[key] as bool? ?? false);

  List<_AdminTabConfig> _visibleTabs() {
    final tabs = <_AdminTabConfig>[];

    if (_hasPerm('finance')) {
      tabs.add(
        _AdminTabConfig(
          icon: Icons.menu_book_rounded,
          label: 'Khata',
          page: _khataPage,
        ),
      );
    }

    if (_hasPerm('orders')) {
      tabs.add(
        _AdminTabConfig(
          icon: Icons.receipt_long_rounded,
          label: 'Orders',
          page: _ordersPage,
        ),
      );
    }

    if (_hasPerm('shops')) {
      tabs.add(
        _AdminTabConfig(
          icon: Icons.store_rounded,
          label: 'Shops',
          page: _shopsPage,
        ),
      );
    }

    tabs.add(
      _AdminTabConfig(
        icon: Icons.more_horiz_rounded,
        label: 'More',
        page: _morePage,
      ),
    );

    return tabs;
  }

  void _listenUnreadAdminChats() {
    _unreadAdminChatsSub?.cancel();
    _unreadAdminChatsSub = FirebaseDatabase.instance
        .ref(_tenantPath('chats'))
        .onValue
        .listen((event) {
      if (!mounted) return;
      int count = 0;
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        
        int getUnreadMessagesCount(Map chatData) {
          final meta = chatData['meta'];
          if (meta is Map && meta['unreadByAdmin'] == true) {
            final messages = chatData['messages'];
            if (messages is Map) {
              final msgsList = messages.values.toList();
              msgsList.sort((a, b) {
                final tA = (a is Map) ? (a['createdAt'] ?? a['createdAtClient'] ?? 0) : 0;
                final tB = (b is Map) ? (b['createdAt'] ?? b['createdAtClient'] ?? 0) : 0;
                int valA = 0, valB = 0;
                if (tA is int) valA = tA;
                else if (tA is double) valA = tA.toInt();
                else if (tA is String) valA = int.tryParse(tA) ?? 0;
                if (tB is int) valB = tB;
                else if (tB is double) valB = tB.toInt();
                else if (tB is String) valB = int.tryParse(tB) ?? 0;
                return valB.compareTo(valA);
              });
              int threadCount = 0;
              for (var msg in msgsList) {
                if (msg is Map && msg['senderRole'] == 'user') {
                  threadCount++;
                } else if (msg is Map && msg['senderRole'] != 'user') {
                  break;
                }
              }
              return threadCount > 0 ? threadCount : 1;
            }
            return 1;
          }
          return 0;
        }

        data.forEach((uid, userChats) {
          if (userChats is Map) {
            if (userChats.containsKey('meta') || userChats.containsKey('messages')) {
              count += getUnreadMessagesCount(userChats);
            } else {
              userChats.forEach((k, v) {
                if (v is Map) {
                  count += getUnreadMessagesCount(v);
                }
              });
            }
          }
        });
      }
      setState(() => _unreadAdminChatCount = count);
    });
  }

  @override
  void dispose() {
    _unreadAdminChatsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsLoaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _primary)),
      );
    }

    final tabs = _visibleTabs();
    final safeIndex = _currentIndex.clamp(0, tabs.length - 1);

    if (safeIndex != _currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _currentIndex = safeIndex);
      });
    }

    return Scaffold(
      floatingActionButton: Stack(
        clipBehavior: Clip.none,
        children: [
          FloatingActionButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AdminChatsPage(),
                ),
              );
            },
            backgroundColor: Colors.white,
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.support_agent_rounded, color: Colors.blue, size: 32),
          ),
          if (_unreadAdminChatCount > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  _unreadAdminChatCount > 9 ? '9+' : _unreadAdminChatCount.toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
      body: IndexedStack(
        index: safeIndex,
        children: tabs.map((t) => t.page).toList(),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 64,
            child: Row(
              children: List.generate(tabs.length, (index) {
                final tab = tabs[index];
                if (tab.badge > 0) {
                  return _navItemBadge(index, tab.icon, tab.label, tab.badge);
                }
                return _navItem(index, tab.icon, tab.label);
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _currentIndex = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? _primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                icon,
                color: isSelected ? _primary : Colors.grey[400],
                size: 22,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? _primary : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navItemBadge(int index, IconData icon, String label, int badge) {
    final isSelected = _currentIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _currentIndex = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? _primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    icon,
                    color: isSelected ? _primary : Colors.grey[400],
                    size: 22,
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: const TextStyle(
                          fontSize: 8,
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? _primary : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Dashboard Home Tab
class _DashboardHome extends StatefulWidget {
  const _DashboardHome();

  @override
  State<_DashboardHome> createState() => _DashboardHomeState();
}

class _DashboardHomeState extends State<_DashboardHome> {
  static const Color _primary = Color(0xFFFF6B00);
  final _db = FirebaseDatabase.instance.ref();

  bool _isLoading = true;
  int _totalShops = 0;
  int _pendingOrders = 0;
  int _deliveredOrders = 0;
  int _deliveredTodayOrders = 0;
  double _totalRevenue = 0;
  int _pendingDeletions = 0;
  List<Map<String, dynamic>> _allOrders = [];

  // Daily khata overview (today: 12 AM to next 12 AM)
  double _khataProfitWithDelivery = 0;
  double _khataProfitWithoutDelivery = 0;
  double _khataDeliveryRevenue = 0;
  int _khataDeliveredToday = 0;
  bool _khataStatsLoaded = false;

  // Track known order IDs to detect new arrivals
  final Set<String> _knownOrderIds = {};
  bool _initialLoadDone = false;

  double _toDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  int? _toEpochMs(dynamic value) {
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num) {
      parsed = value.toInt();
    } else {
      final raw = value?.toString().trim() ?? '';
      if (raw.isNotEmpty) {
        parsed = int.tryParse(raw);
        if (parsed == null) {
          final dt = DateTime.tryParse(raw);
          if (dt != null) parsed = dt.millisecondsSinceEpoch;
        }
      }
    }

    if (parsed == null) return null;

    // Normalize epoch seconds to milliseconds for older records.
    if (parsed > 0 && parsed < 1000000000000) {
      parsed *= 1000;
    }
    return parsed;
  }

  int? _orderDeliveredAtMs(Map<String, dynamic> order) {
    return _toEpochMs(order['deliveredAt']) ??
        _toEpochMs(order['updatedAt']) ??
        _toEpochMs(order['createdAt']) ??
        _toEpochMs(order['timestamp']);
  }

  @override
  void initState() {
    super.initState();
    _initTenantScope();
  }

  Future<void> _initTenantScope() async {
    await CityScopeService.ensureLoaded();
    if (!mounted) return;
    _load();
    _loadKhataStats();
    _setupNewOrderListeners();
  }

  void _setupNewOrderListeners() {
    // Listen for new shop-orders
    _db.child(_tenantPath('shop-orders')).onChildAdded.listen((event) {
      final key = event.snapshot.key ?? '';
      if (_initialLoadDone && !_knownOrderIds.contains(key)) {
        _knownOrderIds.add(key);
        // Notification display is handled centrally by NotificationService
        // via notifications/admin/inbox RTDB listener.
        if (mounted) _load(showLoader: false);
      } else {
        _knownOrderIds.add(key);
      }
    });

    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    if (showLoader && mounted) setState(() => _isLoading = true);
    try {
      // Fast path: only shops count + pending orders so the dashboard shows
      // instantly. Delivered history / revenue aggregate loads in the background.
      final results = await Future.wait([
        _db.child(_tenantPath('shops')).get(),
        _db
            .child(_tenantPath('shop-orders'))
            .orderByChild('status')
            .equalTo('pending')
            .get(),
        _db.child('account-deletion-requests').get(),
      ]);

      final shopsSnap = results[0];
      final pendingSnap = results[1];
      final delSnap = results[2];

      int shops = shopsSnap.exists && shopsSnap.value is Map
          ? (shopsSnap.value as Map).length
          : 0;

      int pending = pendingSnap.exists && pendingSnap.value is Map
          ? (pendingSnap.value as Map).length
          : 0;

      // Count pending deletion requests
      int pendingDel = 0;
      if (delSnap.exists && delSnap.value is Map) {
        (delSnap.value as Map).forEach((_, v) {
          if (v is Map && v['status'] == 'pending') pendingDel++;
        });
      }

      if (mounted) {
        setState(() {
          _totalShops = shops;
          _pendingOrders = pending;
          _pendingDeletions = pendingDel;
          _isLoading = false;
          _initialLoadDone = true;
        });
      }

      unawaited(_loadDeliveredAggregate());
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
    unawaited(_loadKhataStats());
  }

  // Heavier delivered-history aggregate (count + revenue + analytics). Loaded in
  // the background so it never delays the dashboard from appearing.
  Future<void> _loadDeliveredAggregate() async {
    try {
      final snap = await _db
          .child(_tenantPath('shop-orders'))
          .orderByChild('status')
          .equalTo('delivered')
          .get();

      int delivered = 0;
      int deliveredToday = 0;
      double revenue = 0;
      final all = <Map<String, dynamic>>[];
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day)
          .millisecondsSinceEpoch;
      final dayEnd = DateTime(now.year, now.month, now.day + 1)
          .millisecondsSinceEpoch;

      if (snap.exists && snap.value is Map) {
        (snap.value as Map).forEach((key, val) {
          if (val is! Map) return;
          final order = Map<String, dynamic>.from(val);
          delivered++;
          revenue += double.tryParse(
                (order['grandTotal'] ?? order['budget'] ?? 0).toString(),
              ) ??
              0;
          final deliveredAt = _orderDeliveredAtMs(order);
          if (deliveredAt != null &&
              deliveredAt >= dayStart &&
              deliveredAt < dayEnd) {
            deliveredToday++;
          }
          all.add({...order, 'orderId': key.toString().substring(0, 8)});
        });
      }

      all.sort((a, b) => (b['createdAt'] ?? 0).compareTo(a['createdAt'] ?? 0));

      if (mounted) {
        setState(() {
          _deliveredOrders = delivered;
          _deliveredTodayOrders = deliveredToday;
          _totalRevenue = revenue;
          _allOrders = all;
        });
      }
    } catch (_) {}
  }

  // Loads daily khata summary for dashboard card (today midnight to next midnight)
  Future<void> _loadKhataStats() async {
    try {
      final results = await Future.wait([
        _db.child(_tenantPath('shop-orders')).get(),
        _db.child(_tenantPath('settings/fees')).get(),
      ]);
      double commRate = 10.0, delivFee = 50.0;
      if (results[1].exists && results[1].value is Map) {
        final d = Map<String, dynamic>.from(results[1].value as Map);
        commRate = _toDouble(
          d['commissionRate'] ?? d['taxPercent'] ?? 10,
          fallback: 10,
        );
        delivFee = _toDouble(d['deliveryFee'] ?? 50, fallback: 50);
      }

      final now = DateTime.now();
      final dayStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).millisecondsSinceEpoch;
      final dayEnd = DateTime(
        now.year,
        now.month,
        now.day + 1,
      ).millisecondsSinceEpoch;

      double deliveryRevenue = 0;
      double profitWithoutDelivery = 0;
      double profitWithDelivery = 0;
      int deliveredCount = 0;

      void processSnapshot(DataSnapshot snap) {
        if (!snap.exists || snap.value is! Map) return;
        (snap.value as Map).forEach((_, v) {
          if (v is! Map) return;
          final o = Map<String, dynamic>.from(v);
          if ((o['status'] ?? '').toString().toLowerCase() != 'delivered')
            return;

          final deliveredAt = _orderDeliveredAtMs(o);
          if (deliveredAt == null ||
              deliveredAt < dayStart ||
              deliveredAt >= dayEnd) {
            return;
          }

          final sub =
              double.tryParse(
                (o['subtotal'] ?? o['grandTotal'] ?? 0).toString(),
              ) ??
              0;
          final df =
              double.tryParse((o['deliveryFee'] ?? delivFee).toString()) ??
              delivFee;
          final commission = sub * commRate / 100;
          deliveredCount++;
          deliveryRevenue += df;
          profitWithoutDelivery += commission;
          profitWithDelivery += commission + df;
        });
      }

      processSnapshot(results[0]);

      if (mounted) {
        setState(() {
          _khataDeliveredToday = deliveredCount;
          _khataDeliveryRevenue = deliveryRevenue;
          _khataProfitWithoutDelivery = profitWithoutDelivery;
          _khataProfitWithDelivery = profitWithDelivery;
          _khataStatsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _khataDeliveredToday = 0;
          _khataDeliveryRevenue = 0;
          _khataProfitWithoutDelivery = 0;
          _khataProfitWithDelivery = 0;
          _khataStatsLoaded = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  _buildSliverHeader(),
                  SliverToBoxAdapter(
                    child: Transform.translate(
                      offset: const Offset(0, -40),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildStatsGridNew(),
                            if (_pendingDeletions > 0) ...[
                              const SizedBox(height: 16),
                              _buildDeletionRequestsBanner(),
                            ],
                            const SizedBox(height: 16),
                            _buildRevenueInsightsCard(),
                            const SizedBox(height: 16),
                            _buildKhataOverviewCard(),
                            const SizedBox(height: 16),
                            _buildTopShopsSection(),
                            const SizedBox(height: 16),
                            _buildQuickActions(),
                            const SizedBox(height: 100),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  SliverAppBar _buildSliverHeader() {
    final user = FirebaseAuth.instance.currentUser;
    return SliverAppBar(
      expandedHeight: 160,
      floating: false,
      pinned: true,
      snap: false,
      backgroundColor: _primary,
      elevation: 0,
      automaticallyImplyLeading: false,
      actions: [
        StreamBuilder<DatabaseEvent>(
          stream: FirebaseDatabase.instance
              .ref(_tenantPath('settings/app-control/temporarilyClosed'))
              .onValue,
          builder: (context, snapshot) {
            bool isClosed = false;
            if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
              final val = snapshot.data!.snapshot.value;
              isClosed = val == true || val.toString() == 'true';
            }
            final isAppOn = !isClosed;
            return Row(
              children: [
                Text(
                  isAppOn ? 'App ON' : 'App OFF',
                  style: TextStyle(
                    color: isAppOn ? Colors.greenAccent : Colors.redAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                Switch(
                  value: isAppOn,
                  activeColor: Colors.greenAccent,
                  inactiveThumbColor: Colors.redAccent,
                  inactiveTrackColor: Colors.red.withValues(alpha: 0.3),
                  onChanged: (val) async {
                    await FirebaseDatabase.instance
                        .ref(_tenantPath('settings/app-control/temporarilyClosed'))
                        .set(!val);
                  },
                ),
              ],
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Stack(
            children: [
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
                  child: const Icon(
                    Icons.notifications_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AdminNotificationsPage(),
                  ),
                ),
              ),
              if (_pendingOrders > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: Colors.yellow[400],
                      shape: BoxShape.circle,
                      border: Border.all(color: _primary, width: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
              ),
              child: const Icon(
                Icons.refresh_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
            onPressed: _load,
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          children: [
            // Background accents
            Positioned(
              top: -40,
              right: -40,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: -30,
              left: -20,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Icon(
                      Icons.admin_panel_settings_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Executive Suite',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Admin Dashboard',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user?.email ?? '',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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

  Widget _buildStatsGridNew() {
    final stats = [
      {
        'title': 'PENDING',
        'value': '$_pendingOrders',
        'icon': Icons.pending_actions_rounded,
        'color': _primary,
        'bg': const Color(0xFFFF6B00),
      },
      {
        'title': 'REVENUE',
        'value': 'Rs.${_formatCompact(_totalRevenue)}',
        'icon': Icons.payments_rounded,
        'color': const Color(0xFF10B981),
        'bg': const Color(0xFF10B981),
      },
      {
        'title': 'DELIVERED',
        'value': '$_deliveredOrders',
        'hint': 'Today $_deliveredTodayOrders',
        'icon': Icons.local_shipping_rounded,
        'color': const Color(0xFF3B82F6),
        'bg': const Color(0xFF3B82F6),
      },
      {
        'title': 'SHOPS',
        'value': '$_totalShops',
        'icon': Icons.storefront_rounded,
        'color': const Color(0xFFA855F7),
        'bg': const Color(0xFFA855F7),
      },
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.35,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: stats.length,
      itemBuilder: (_, i) {
        final s = stats[i];
        final color = s['color'] as Color;
        final bgColor = s['bg'] as Color;
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: bgColor.withValues(alpha: 0.12),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(s['icon'] as IconData, color: color, size: 22),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s['title'] as String,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey[500],
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      s['value'] as String,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F1115),
                        height: 1,
                      ),
                    ),
                  ),
                  if (s['hint'] != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      s['hint'] as String,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatCompact(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  Widget _buildRevenueInsightsCard() {
    // Weekly buckets from recent orders (Mon–Sun relative to today)
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final buckets = List.filled(7, 0.0);
    for (final o in _allOrders) {
      final ts = o['createdAt'];
      if (ts == null) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(
        int.tryParse(ts.toString()) ?? 0,
      );
      final diff = dt.difference(weekStart).inDays;
      if (diff >= 0 &&
          diff < 7 &&
          (o['status'] ?? '').toString().toLowerCase() == 'delivered') {
        buckets[diff] +=
            double.tryParse((o['grandTotal'] ?? o['budget'] ?? 0).toString()) ??
            0;
      }
    }
    final maxVal = buckets.reduce((a, b) => a > b ? a : b);
    const days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final todayIdx = now.weekday - 1;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Revenue Insights',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.trending_up_rounded,
                      size: 14,
                      color: Color(0xFF059669),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Rs.${_formatCompact(_totalRevenue)}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF059669),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 100,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final frac = maxVal > 0 ? buckets[i] / maxVal : 0.1;
                final isToday = i == todayIdx;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Flexible(
                          child: FractionallySizedBox(
                            heightFactor: frac.clamp(0.05, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: isToday
                                    ? _primary
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: isToday
                                    ? [
                                        BoxShadow(
                                          color: _primary.withValues(
                                            alpha: 0.4,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 4),
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: List.generate(7, (i) {
              final isToday = i == todayIdx;
              return Expanded(
                child: Text(
                  days[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: isToday ? _primary : Colors.grey[400],
                    letterSpacing: 0.5,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildTopShopsSection() {
    // Sort all orders by shop revenue
    final shopTotals = <String, double>{};
    for (final o in _allOrders) {
      final shop = (o['shopName'] ?? o['shop'] ?? 'Custom').toString();
      if ((o['status'] ?? '').toString().toLowerCase() != 'delivered') continue;
      shopTotals[shop] =
          (shopTotals[shop] ?? 0) +
          (double.tryParse((o['grandTotal'] ?? o['budget'] ?? 0).toString()) ??
              0);
    }
    final sorted = shopTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(3).toList();

    if (top.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Top Performing Shops',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        ...List.generate(top.length, (i) {
          final e = top[i];
          final rankColors = [
            _primary,
            const Color(0xFF6B7280),
            const Color(0xFFB45309),
          ];
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      '#${i + 1}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: rankColors[i],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.key,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        '${top.length - i} orders this week',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
                Text(
                  'Rs.${_formatCompact(e.value)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: i == 0 ? _primary : const Color(0xFF0F1115),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // Tappable finance card on dashboard that opens Khata page
  Widget _buildKhataOverviewCard() {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AdminKhataPage()),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF0F1115),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DAILY KHATA',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Colors.grey[400],
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Today 12AM - 12AM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.analytics_rounded,
                    color: _primary,
                    size: 22,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Minimal spark line
            SizedBox(
              height: 60,
              child: CustomPaint(
                size: const Size(double.infinity, 60),
                painter: _SparkLinePainter(
                  _khataProfitWithDelivery,
                  _khataProfitWithoutDelivery,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_khataStatsLoaded) ...[
                        Text(
                          'Rs.${_formatCompact(_khataProfitWithDelivery)}',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Profit + Delivery (Today)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ] else
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _primary,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_khataStatsLoaded)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.delivery_dining_rounded,
                          size: 14,
                          color: const Color(0xFF10B981),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$_khataDeliveredToday delivered today',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Colors.grey[200],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_khataStatsLoaded)
              Row(
                children: [
                  _khataStatPill(
                    'Profit - Delivery',
                    _khataProfitWithoutDelivery,
                    const Color(0xFF10B981),
                  ),
                  const SizedBox(width: 8),
                  _khataStatPill(
                    'Delivery Total',
                    _khataDeliveryRevenue,
                    const Color(0xFFF59E0B),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _khataStatPill(String label, double value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              child: Text(
                'Rs.${_formatCompact(value)}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Actions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _quickActionCard(
                Icons.add_business_rounded,
                'Add Shop',
                const Color(0xFF10B981),
                () {
                  final state = context
                      .findAncestorStateOfType<_AdminDashboardState>();
                  state?.setState(() => state._currentIndex = 2);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _quickActionCard(
                Icons.campaign_rounded,
                'Broadcast',
                const Color(0xFFFF6B00),
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminNotificationsPage(),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _quickActionCard(
                Icons.tune_rounded,
                'Settings',
                _primary,
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AdminAppSettingsPage(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _quickActionCard(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.grey[700],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeletionRequestsBanner() {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AdminSettingsPage()),
      ).then((_) => _load()),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.red[50],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.red[200]!),
        ),
        child: Row(
          children: [
            Stack(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.red[100],
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.person_remove_rounded,
                    color: Colors.red,
                    size: 20,
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '$_pendingDeletions',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$_pendingDeletions Account Deletion Request${_pendingDeletions != 1 ? 's' : ''}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Colors.red,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Pending admin review • Tap to manage',
                    style: TextStyle(fontSize: 12, color: Colors.red[400]),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.red[300]),
          ],
        ),
      ),
    );
  }
}

class _SparkLinePainter extends CustomPainter {
  final double revenue;
  final double expenses;
  _SparkLinePainter(this.revenue, this.expenses);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFF6B00)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final points = List.generate(20, (i) {
      final t = i / 19;
      final y =
          size.height * 0.5 +
          size.height *
              0.35 *
              sin(t * pi * 2 - pi / 2) *
              (revenue > 0 ? -1 : 1);
      return Offset(t * size.width, y.clamp(0, size.height));
    });

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      final cp = Offset(
        (points[i - 1].dx + points[i].dx) / 2,
        points[i - 1].dy,
      );
      path.quadraticBezierTo(cp.dx, cp.dy, points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);

    // Fill gradient
    final fillPath = Path()
      ..addPath(path, Offset.zero)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFFF6B00).withValues(alpha: 0.25),
            const Color(0xFFFF6B00).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    // End dot
    canvas.drawCircle(points.last, 4, Paint()..color = const Color(0xFFFF6B00));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// More Tab
class _AdminMorePage extends StatefulWidget {
  const _AdminMorePage();

  @override
  State<_AdminMorePage> createState() => _AdminMorePageState();
}

class _AdminMorePageState extends State<_AdminMorePage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const Set<String> _superAdminEmails = {
    'qa568581@gmail.com',
    'arshadahsan77900@gmail.com',
    'raf451810@gmail.com',
    'waqaraliwebs@gmail.com',
  };

  Map<String, dynamic> _permissions = {};
  bool _isSuperAdmin = false;
  String _activeCity = CityScopeService.defaultCity;

  @override
  void initState() {
    super.initState();
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    _isSuperAdmin = _superAdminEmails.contains(
      (user.email ?? '').toLowerCase(),
    );

    await CityScopeService.ensureLoaded();
    _activeCity = CityScopeService.currentCity;

    try {
      final snap = await FirebaseDatabase.instance
          .ref('users/${user.uid}')
          .get();
      if (snap.exists && snap.value is Map) {
        final userData = Map<String, dynamic>.from(snap.value as Map);
        if (userData['permissions'] is Map) {
          _permissions = Map<String, dynamic>.from(
            userData['permissions'] as Map,
          );
        }

        final role = (userData['role'] ?? 'admin').toString().toLowerCase();
        final rawCity = role == 'admin'
            ? (userData['adminCity'] ?? '').toString()
            : (userData['userCity'] ?? '').toString();
        if (rawCity.trim().isNotEmpty) {
          _activeCity = CityScopeService.normalizeCity(rawCity);
        }
      }
    } catch (_) {}

    await CityScopeService.setSelectedCity(_activeCity);

    if (mounted) setState(() {});
  }

  bool _hasPerm(String key) =>
      _isSuperAdmin || (_permissions[key] as bool? ?? false);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'More',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.location_city_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      CityScopeService.cityLabel(_activeCity),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          if (_hasPerm('finance')) ...[
            _sectionTitle('Finance'),
            _buildSettingsGroup([
              _buildSettingsRow(
                context: context,
                icon: Icons.menu_book_rounded,
                title: 'Khata (Ledger)',
                subtitle: 'Shop khata, kharcha & owner hissa',
                color: Colors.teal,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminKhataPage()),
                  );
                },
              ),
            ]),
          ],
          if (_hasPerm('users')) ...[
            _sectionTitle('Users'),
            _buildSettingsGroup([
              _buildSettingsRow(
                context: context,
                icon: Icons.people_rounded,
                title: 'User Management',
                subtitle: 'View, ban & manage users',
                color: Colors.purple,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminUsersPage()),
                  );
                },
              ),
              _buildSettingsRow(
                context: context,
                icon: Icons.store_mall_directory_rounded,
                title: 'Merchant Management',
                subtitle: 'Create merchant accounts and assign shops',
                color: const Color(0xFF0E7A6C),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminMerchantManagementPage(),
                    ),
                  );
                },
              ),
            ]),
          ],
          if (_hasPerm('notifications')) ...[
            _sectionTitle('Communication'),
            _buildSettingsGroup([
              _buildSettingsRow(
                context: context,
                icon: Icons.campaign_rounded,
                title: 'Push Notifications',
                subtitle: 'Broadcast or send to a specific user',
                color: const Color(0xFFFF6B00),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminNotificationsPage(),
                    ),
                  );
                },
              ),
              _buildSettingsRow(
                context: context,
                icon: Icons.chat_bubble_rounded,
                title: 'Chats',
                subtitle: 'Message users and view conversations',
                color: const Color(0xFF0EA5A4),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminChatsPage(),
                    ),
                  );
                },
              ),
            ]),
          ],
          if (_hasPerm('finance')) ...[
            _sectionTitle('Content'),
            _buildSettingsGroup([
              _buildSettingsRow(
                context: context,
                icon: Icons.image_rounded,
                title: 'Home Categories',
                subtitle: 'Add & manage Islamabad dashboard categories',
                color: const Color(0xFF2563EB),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminCategoryImagesPage(),
                    ),
                  );
                },
              ),
            ]),
          ],
          if (_isSuperAdmin || _hasPerm('finance')) ...[
            _sectionTitle('Admin Control'),
            _buildSettingsGroup([
              if (_isSuperAdmin)
                _buildSettingsRow(
                  context: context,
                  icon: Icons.admin_panel_settings_rounded,
                  title: 'Admin Settings',
                  subtitle: 'Manage admins & permissions',
                  color: const Color(0xFFFF6B00),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminSettingsPage(),
                      ),
                    );
                  },
                ),
              if (_hasPerm('finance'))
                _buildSettingsRow(
                  context: context,
                  icon: Icons.tune_rounded,
                  title: 'App Settings',
                  subtitle: 'Fees, promo codes, payments & ads',
                  color: const Color(0xFFFF6B00),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AdminAppSettingsPage(),
                      ),
                    );
                  },
                ),
            ]),
          ],
          _sectionTitle('Account'),
          _buildSettingsGroup([
            _buildSettingsRow(
              context: context,
              icon: Icons.logout_rounded,
              title: 'Logout',
              subtitle: 'Sign out of admin panel',
              color: Colors.red,
              onTap: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Logout'),
                    content: const Text('Are you sure you want to logout?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Logout',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  await AuthService().signOut();
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                      (r) => false,
                    );
                  }
                }
              },
            ),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          t.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.grey[500],
            letterSpacing: 1.0,
          ),
        ),
      );

  Widget _buildSettingsGroup(List<Widget> children) {
    final visibleChildren = children.where((child) {
      if (child is SizedBox) {
        return child.width != 0.0 || child.height != 0.0;
      }
      return true;
    }).toList();
    if (visibleChildren.isEmpty) return const SizedBox.shrink();

    final List<Widget> itemsWithDividers = [];
    for (int i = 0; i < visibleChildren.length; i++) {
      itemsWithDividers.add(visibleChildren[i]);
      if (i < visibleChildren.length - 1) {
        itemsWithDividers.add(
          const Divider(
            height: 1,
            thickness: 0.5,
            color: Color(0xFFE2E8F0),
            indent: 56,
          ),
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: itemsWithDividers,
        ),
      ),
    );
  }

  Widget _buildSettingsRow({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14.5,
          color: Color(0xFF1E293B),
        ),
      ),
      subtitle: subtitle.isNotEmpty
          ? Text(
              subtitle,
              style: TextStyle(color: Colors.grey[500], fontSize: 11.5),
            )
          : null,
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: Colors.grey[400],
      ),
      onTap: onTap,
    );
  }
}
