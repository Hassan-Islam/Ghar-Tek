import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter/material.dart';

import '../services/city_scope_service.dart';
import 'admin_shops_khata_page.dart';
import 'admin_riders_khata_page.dart';

class AdminKhataPage extends StatefulWidget {
  const AdminKhataPage({super.key});

  @override
  State<AdminKhataPage> createState() => _AdminKhataPageState();
}

class _AdminKhataPageState extends State<AdminKhataPage> {
  static const Color _primary = Color(0xFFFF6B00);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _activeCity = CityScopeService.defaultCity;
  bool _loading = true;

  // Null means "today" (midnight to next midnight).
  DateTimeRange? _selectedRange;

  double _commissionRate = 10.0;
  double _defaultDeliveryFee = 50.0;

  int _deliveredCount = 0;
  double _totalSales = 0;
  double _totalSaleWithDelivery = 0;
  double _deliveryRevenue = 0;
  double _profitExcludingDelivery = 0;
  double _profitIncludingDelivery = 0;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _initTenantScope();
  }

  Future<void> _initTenantScope() async {
    await _syncAdminCityContext();
    if (!mounted) return;
    await _loadKhataSummary();
  }

  Future<void> _syncAdminCityContext() async {
    await CityScopeService.ensureLoaded();
    _activeCity = CityScopeService.currentCity;

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final userSnap = await _db.child('users/${user.uid}').get();
        if (userSnap.exists && userSnap.value is Map) {
          final data = Map<String, dynamic>.from(userSnap.value as Map);
          final role = (data['role'] ?? 'admin').toString().toLowerCase();
          final rawCity = role == 'admin'
              ? (data['adminCity'] ?? '').toString()
              : (data['userCity'] ?? '').toString();
          if (rawCity.trim().isNotEmpty) {
            _activeCity = CityScopeService.normalizeCity(rawCity);
          }
        }
      } catch (_) {
        // Keep default city scope if user city lookup fails.
      }
    }

    await CityScopeService.setSelectedCity(_activeCity);
    if (mounted) setState(() {});
  }

  double _toDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  int? _toEpochMs(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  DateTime _startOfDay(DateTime date) => DateTime(date.year, date.month, date.day);

  DateTime _endExclusiveOfDay(DateTime date) => _startOfDay(date).add(const Duration(days: 1));

  ({DateTime start, DateTime endExclusive}) _activeWindow() {
    if (_selectedRange == null) {
      final now = DateTime.now();
      final start = _startOfDay(now);
      return (start: start, endExclusive: start.add(const Duration(days: 1)));
    }

    final start = _startOfDay(_selectedRange!.start);
    final endExclusive = _endExclusiveOfDay(_selectedRange!.end);
    return (start: start, endExclusive: endExclusive);
  }

  String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yy = d.year.toString();
    return '$dd/$mm/$yy';
  }

  String _rangeLabel() {
    if (_selectedRange == null) {
      final today = _startOfDay(DateTime.now());
      return '${_fmtDate(today)} (12:00 AM - 11:59 PM)';
    }
    return '${_fmtDate(_selectedRange!.start)} - ${_fmtDate(_selectedRange!.end)}';
  }

  int? _resolveDeliveredAtMs(Map<String, dynamic> order) {
    return _toEpochMs(order['deliveredAt']) ??
        _toEpochMs(order['updatedAt']) ??
        _toEpochMs(order['createdAt']) ??
        _toEpochMs(order['timestamp']);
  }

  Future<void> _loadSettings() async {
    try {
      final snap = await _db.child(_tenantPath('settings/fees')).get();
      if (snap.exists && snap.value is Map) {
        final fees = Map<String, dynamic>.from(snap.value as Map);
        _commissionRate = _toDouble(fees['commissionRate'] ?? fees['taxPercent'] ?? 10, fallback: 10);
        _defaultDeliveryFee = _toDouble(fees['deliveryFee'] ?? 50, fallback: 50);
      }
    } catch (_) {
      // Keep defaults if settings are unavailable.
    }
  }

  Future<void> _loadKhataSummary() async {
    if (mounted) setState(() => _loading = true);

    try {
      await _loadSettings();

      final results = await Future.wait([
        _db.child(_tenantPath('shop-orders')).get(),
      ]);

      final window = _activeWindow();
      final startMs = window.start.millisecondsSinceEpoch;
      final endMs = window.endExclusive.millisecondsSinceEpoch;

      int deliveredCount = 0;
      double totalSales = 0;
      double totalSaleWithDelivery = 0;
      double deliveryRevenue = 0;
      double profitExcludingDelivery = 0;
      double profitIncludingDelivery = 0;

      void processOrders(DataSnapshot snapshot) {
        if (!snapshot.exists || snapshot.value is! Map) return;

        (snapshot.value as Map).forEach((_, raw) {
          if (raw is! Map) return;
          final order = Map<String, dynamic>.from(raw);

          final status = (order['status'] ?? '').toString().toLowerCase();
          if (status != 'delivered') return;

          final deliveredAt = _resolveDeliveredAtMs(order);
          if (deliveredAt == null) return;
          if (deliveredAt < startMs || deliveredAt >= endMs) return;

          deliveredCount++;

          final subtotal = _toDouble(
            order['subtotal'] ?? order['grandTotal'] ?? order['budget'],
          );
          final deliveryFee = _toDouble(
            order['deliveryFee'] ?? _defaultDeliveryFee,
            fallback: _defaultDeliveryFee,
          );

          final commission = subtotal * (_commissionRate / 100);

          totalSales += subtotal;
          totalSaleWithDelivery += subtotal + deliveryFee;
          deliveryRevenue += deliveryFee;
          profitExcludingDelivery += commission;
          profitIncludingDelivery += commission + deliveryFee;
        });
      }

      processOrders(results[0]);

      if (!mounted) return;
      setState(() {
        _deliveredCount = deliveredCount;
        _totalSales = totalSales;
        _totalSaleWithDelivery = totalSaleWithDelivery;
        _deliveryRevenue = deliveryRevenue;
        _profitExcludingDelivery = profitExcludingDelivery;
        _profitIncludingDelivery = profitIncludingDelivery;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _selectedRange ?? DateTimeRange(start: now, end: now),
      helpText: 'Select khata date range',
    );

    if (picked == null) return;

    setState(() {
      _selectedRange = picked;
    });
    await _loadKhataSummary();
  }

  Future<void> _resetToToday() async {
    setState(() {
      _selectedRange = null;
    });
    await _loadKhataSummary();
  }

  Widget _metricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    String? subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[700],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        title: const Text(
          'Khata (Daily Summary)',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadKhataSummary,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _loadKhataSummary,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
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
                        Row(
                          children: [
                            const Icon(Icons.location_city_rounded, size: 16, color: _primary),
                            const SizedBox(width: 6),
                            Text(
                              'City: ${CityScopeService.cityLabel(_activeCity)}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Date Window: ${_rangeLabel()}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _pickDateRange,
                              icon: const Icon(Icons.calendar_today_rounded, size: 16),
                              label: const Text('Filter by Date'),
                            ),
                            if (_selectedRange != null)
                              OutlinedButton.icon(
                                onPressed: _resetToToday,
                                icon: const Icon(Icons.today_rounded, size: 16),
                                label: const Text('Today'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AdminShopsKhataPage(
                                  selectedRange: _selectedRange,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.storefront_rounded),
                          label: const Text('Shops Hisab'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AdminRidersKhataPage(
                                  selectedRange: _selectedRange,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.delivery_dining_rounded),
                          label: const Text('Riders Hisab'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0EA5E9),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _metricCard(
                    title: 'Delivered Orders',
                    value: '$_deliveredCount',
                    icon: Icons.delivery_dining_rounded,
                    color: const Color(0xFF0EA5E9),
                    subtitle: 'Total deliveries in selected day/date range',
                  ),
                  const SizedBox(height: 10),
                  _metricCard(
                    title: 'Total Sales',
                    value: 'Rs. ${_totalSales.toStringAsFixed(0)}',
                    icon: Icons.storefront_rounded,
                    color: const Color(0xFFF59E0B),
                    subtitle: 'Order amounts excluding delivery charges',
                  ),
                  const SizedBox(height: 10),
                  _metricCard(
                    title: 'Delivery Profit',
                    value: 'Rs. ${_deliveryRevenue.toStringAsFixed(0)}',
                    icon: Icons.local_shipping_rounded,
                    color: const Color(0xFFE11D48),
                    subtitle: 'Total delivery fees collected',
                  ),
                  const SizedBox(height: 10),
                  _metricCard(
                    title: 'Sales Commission',
                    value: 'Rs. ${_profitExcludingDelivery.toStringAsFixed(0)}',
                    icon: Icons.percent_rounded,
                    color: const Color(0xFF7C3AED),
                    subtitle: 'Commission earned from order sales',
                  ),
                  const SizedBox(height: 10),
                  _metricCard(
                    title: 'Total Revenue (Sales + Delivery)',
                    value: 'Rs. ${_totalSaleWithDelivery.toStringAsFixed(0)}',
                    icon: Icons.payments_rounded,
                    color: const Color(0xFF0369A1),
                    subtitle:
                        'Sales: Rs. ${_totalSales.toStringAsFixed(0)} + Delivery: Rs. ${_deliveryRevenue.toStringAsFixed(0)}',
                  ),
                  const SizedBox(height: 10),
                  _metricCard(
                    title: 'Total Profit',
                    value: 'Rs. ${_profitIncludingDelivery.toStringAsFixed(0)}',
                    icon: Icons.account_balance_wallet_rounded,
                    color: const Color(0xFF16A34A),
                    subtitle: 'Earned Commission + Delivery Profit',
                  ),
                ],
              ),
            ),
    );
  }
}
