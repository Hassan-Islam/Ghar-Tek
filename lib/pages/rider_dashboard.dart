import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'rider_orders_page.dart';
import 'login_page.dart';
import '../services/auth_service.dart';
import '../services/city_scope_service.dart';
import '../services/rider_notification_service.dart';
import '../services/rider_orders_loader.dart';

class RiderDashboard extends StatefulWidget {
  const RiderDashboard({super.key});

  @override
  State<RiderDashboard> createState() => _RiderDashboardState();
}

class _RiderDashboardState extends State<RiderDashboard> {
  static const Color _primary = Color(0xFF06B6D4);

  final _db = FirebaseDatabase.instance.ref();
  final _auth = FirebaseAuth.instance;

  int _currentIndex = 0;
  String _riderName = 'Rider';
  int _totalOrders = 0;
  int _pendingOrders = 0;
  int _onWayOrders = 0;
  int _deliveredOrders = 0;
  double _deliveredBillWithDelivery = 0;
  double _deliveredBillWithoutDelivery = 0;
  bool _isLoading = false;
  bool _statsLoading = false;
  bool _ordersTabReady = false;
  Widget? _ordersPage;

  String _normalizeRiderStatus(dynamic rawStatus) =>
      RiderOrdersLoader.normalizeStatus(rawStatus);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '0') ?? 0.0;
  }

  Map<String, double> _deliveredBillTotals(Map<String, dynamic> order) {
    final subtotal = _toDouble(order['subtotal']);
    final deliveryFee = _toDouble(order['deliveryFee']);
    final grandTotal = _toDouble(order['grandTotal']);
    final budget = _toDouble(order['budget']);

    final withDelivery = grandTotal > 0
        ? grandTotal
        : ((subtotal + deliveryFee) > 0 ? (subtotal + deliveryFee) : budget);

    final withoutDelivery = subtotal > 0
        ? subtotal
        : ((withDelivery - deliveryFee) > 0
              ? (withDelivery - deliveryFee)
              : withDelivery);

    return {'withDelivery': withDelivery, 'withoutDelivery': withoutDelivery};
  }

  String _formatMoney(double value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.01) {
      return rounded.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }

  static ThemeData _lightTheme() => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF5F5F5),
    cardColor: Colors.white,
    colorScheme: const ColorScheme.light(primary: Color(0xFF06B6D4)),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF06B6D4),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
  );

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    unawaited(_loadRiderData());
    unawaited(_loadStats());
    Future.microtask(_initNotifications);
  }

  Future<void> _initNotifications() async {
    final svc = RiderNotificationService();
    await svc.initialize();
    RiderNotificationService.onNewOrderForRider = (order) {
      if (mounted) _showNewOrderAlert(order);
    };
    await svc.startListening();
  }

  @override
  void dispose() {
    RiderNotificationService.onNewOrderForRider = null;
    super.dispose();
  }

  Future<void> _loadRiderData() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await _db.child('users/$uid').get();
      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        if (mounted) {
          setState(() {
            _riderName = data['name'] ?? data['displayName'] ?? 'Rider';
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadStats() async {
    if (_statsLoading) return;
    _statsLoading = true;
    if (mounted) setState(() => _isLoading = true);
    try {
      await CityScopeService.ensureLoaded();
      final uid = _auth.currentUser?.uid ?? '';
      // Active stats load first so the dashboard opens instantly.
      final orders = await RiderOrdersLoader.fetchActiveOrders(uid);

      int available = 0, activeMine = 0;
      for (final o in orders) {
        final s = _normalizeRiderStatus(o['status']);
        final assignedRider = (o['assignedRider'] ?? '').toString().trim();

        if (s == 'available' || (s == 'picked' && assignedRider.isEmpty)) {
          available++;
        }
        if (uid.isNotEmpty &&
            assignedRider == uid &&
            (s == 'picked' || s == 'on_the_way')) {
          activeMine++;
        }
      }

      if (mounted) {
        setState(() {
          _pendingOrders = available;
          _onWayOrders = activeMine;
          _isLoading = false;
        });
      }

      // Delivered totals (count + earnings) are heavier history — load them in
      // the background so they don't delay the dashboard from appearing.
      unawaited(_loadDeliveredStats(uid, activeMine));
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    } finally {
      _statsLoading = false;
    }
  }

  Future<void> _loadDeliveredStats(String uid, int activeMine) async {
    try {
      final delivered = await RiderOrdersLoader.fetchDeliveredOrders(uid);
      double deliveredWithDelivery = 0;
      double deliveredWithoutDelivery = 0;
      for (final o in delivered) {
        final totals = _deliveredBillTotals(o);
        deliveredWithDelivery += totals['withDelivery'] ?? 0;
        deliveredWithoutDelivery += totals['withoutDelivery'] ?? 0;
      }
      if (mounted) {
        setState(() {
          _deliveredOrders = delivered.length;
          _totalOrders = activeMine + delivered.length;
          _deliveredBillWithDelivery = deliveredWithDelivery;
          _deliveredBillWithoutDelivery = deliveredWithoutDelivery;
        });
      }
    } catch (_) {}
  }

  Future<void> _logout() async {
    RiderNotificationService().stopListening();
    await AuthService().signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (_) => false,
      );
    }
  }

  // ── In-app new order alert ─────────────────────────────────────────────────

  void _showNewOrderAlert(Map<String, dynamic> order) {
    HapticFeedback.heavyImpact();
    final shopName = order['shopName'] ?? order['shop'] ?? 'New Order';
    final customer = order['userName'] ?? order['userEmail'] ?? 'Customer';
    final total = order['grandTotal'] ?? order['budget'] ?? 0;
    final rawId = (order['id'] ?? '').toString();
    final shortId = rawId.length >= 8
        ? rawId.substring(0, 8).toUpperCase()
        : rawId.toUpperCase();

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _primary, width: 2),
              boxShadow: [
                BoxShadow(
                  color: _primary.withValues(alpha: 0.3),
                  blurRadius: 30,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF06B6D4), Color(0xFF0891B2)],
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(22),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.delivery_dining_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'New Order Received!',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Tap to manage',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _alertRow(Icons.store_rounded, 'Shop', shopName),
                      const SizedBox(height: 10),
                      _alertRow(Icons.person_rounded, 'Customer', customer),
                      const SizedBox(height: 10),
                      _alertRow(
                        Icons.receipt_long_rounded,
                        'Order ID',
                        '#$shortId',
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _primary.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Grand Total',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                            Text(
                              'Rs. $total',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF06B6D4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.grey,
                                side: BorderSide(color: Colors.grey[300]!),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Later',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              icon: const Icon(
                                Icons.visibility_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                'View Order',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              onPressed: () {
                                Navigator.pop(context);
                                setState(() => _currentIndex = 1);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _alertRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: _primary),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1A1A1A),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _lightTheme(),
      child: Builder(
        builder: (themeCtx) => Scaffold(
          backgroundColor: Theme.of(themeCtx).scaffoldBackgroundColor,
          body: IndexedStack(
            index: _currentIndex,
            children: [
              _buildHome(themeCtx),
              _ordersTabReady
                  ? (_ordersPage ?? const SizedBox.shrink())
                  : const SizedBox.shrink(),
            ],
          ),
          bottomNavigationBar: _buildNavBar(themeCtx),
        ),
      ),
    );
  }

  Widget _buildNavBar(BuildContext ctx) {
    const bg = Colors.white;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _navItem(0, Icons.dashboard_rounded, 'Dashboard'),
              _navItem(1, Icons.delivery_dining_rounded, 'Orders'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index;
    final color = isSelected ? _primary : Colors.grey[400]!;

    return Expanded(
      child: InkWell(
        onTap: () {
          if (index == 1 && !_ordersTabReady) {
            _ordersTabReady = true;
            _ordersPage = const RiderOrdersPage();
          }
          setState(() => _currentIndex = index);
        },
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
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dashboard home tab ────────────────────────────────────────────────────

  Widget _buildHome(BuildContext themeCtx) {
    final bg = Theme.of(themeCtx).scaffoldBackgroundColor;
    final cardBg = Theme.of(themeCtx).cardColor;
    const textPrimary = Color(0xFF1A1A1A);

    return Scaffold(
      backgroundColor: bg,
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _loadStats,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 160,
              pinned: true,
              backgroundColor: _primary,
              automaticallyImplyLeading: false,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: const [Color(0xFF06B6D4), Color(0xFF0891B2)],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.delivery_dining_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Welcome, $_riderName',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const Text(
                                  'Rider Dashboard',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.logout_rounded,
                              color: Colors.white,
                            ),
                            onPressed: _logout,
                            tooltip: 'Logout',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _isLoading
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(40),
                          child: CircularProgressIndicator(color: _primary),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Stats grid ──
                          Row(
                            children: [
                              Expanded(
                                child: _statCard(
                                  'My Orders',
                                  _totalOrders.toString(),
                                  Icons.receipt_long_rounded,
                                  Colors.blue,
                                  cardBg,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _statCard(
                                  'Available',
                                  _pendingOrders.toString(),
                                  Icons.pending_actions_rounded,
                                  Colors.orange,
                                  cardBg,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _statCard(
                                  'On the Way',
                                  _onWayOrders.toString(),
                                  Icons.moped_rounded,
                                  _primary,
                                  cardBg,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _statCard(
                                  'Delivered',
                                  _deliveredOrders.toString(),
                                  Icons.check_circle_rounded,
                                  Colors.green,
                                  cardBg,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _statCard(
                                  'Bill (With Delivery)',
                                  'Rs. ${_formatMoney(_deliveredBillWithDelivery)}',
                                  Icons.account_balance_wallet_rounded,
                                  const Color(0xFF2563EB),
                                  cardBg,
                                  compactValue: true,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _statCard(
                                  'Bill (Without Delivery)',
                                  'Rs. ${_formatMoney(_deliveredBillWithoutDelivery)}',
                                  Icons.receipt_long_rounded,
                                  const Color(0xFF0EA5A3),
                                  cardBg,
                                  compactValue: true,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),

                          // ── Quick actions ──
                          Text(
                            'Quick Actions',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _quickAction(
                            icon: Icons.pending_actions_rounded,
                            title: 'Available Orders',
                            subtitle: '$_pendingOrders need attention',
                            color: Colors.orange,
                            cardBg: cardBg,
                            textPrimary: textPrimary,
                            onTap: () => setState(() => _currentIndex = 1),
                          ),
                          const SizedBox(height: 10),
                          _quickAction(
                            icon: Icons.moped_rounded,
                            title: 'My Active Orders',
                            subtitle: '$_onWayOrders in progress',
                            color: _primary,
                            cardBg: cardBg,
                            textPrimary: textPrimary,
                            onTap: () => setState(() => _currentIndex = 1),
                          ),
                          const SizedBox(height: 10),
                          _quickAction(
                            icon: Icons.history_rounded,
                            title: 'Delivery History',
                            subtitle: '$_deliveredOrders delivered today',
                            color: Colors.green,
                            cardBg: cardBg,
                            textPrimary: textPrimary,
                            onTap: () => setState(() => _currentIndex = 1),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(
    String label,
    String value,
    IconData icon,
    Color color,
    Color cardBg, {
    bool compactValue = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: compactValue ? 20 : 28,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[500],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required Color cardBg,
    required Color textPrimary,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 16,
              color: Colors.grey[400],
            ),
          ],
        ),
      ),
    );
  }
}
