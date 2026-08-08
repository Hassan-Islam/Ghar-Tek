import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';

class AdminCashPage extends StatefulWidget {
  const AdminCashPage({super.key});

  @override
  State<AdminCashPage> createState() => _AdminCashPageState();
}

class _AdminCashPageState extends State<AdminCashPage> {
  static const Color _primary = Color(0xFFFF6B00);
  // Platform commission rate (10%)
  static const double _commissionRate = 0.10;
  // Delivery fee kept by platform
  static const double _deliveryFee = 50.0;

  final _database = FirebaseDatabase.instance.ref();
  bool _isLoading = true;

  double _totalDeliveryFees = 0;
  double _platformProfit = 0;
  double _totalOrderValue = 0;
  int _totalOrders = 0;
  int _deliveredOrders = 0;
  int _cancelledOrders = 0;

  // Daily breakdown
  List<Map<String, dynamic>> _recentTransactions = [];

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      await CityScopeService.ensureLoaded();
      final shopSnap = await _database.child(_tenantPath('shop-orders')).get();

      double totalRevenue = 0;
      double totalDelivery = 0;
      double totalOrderValue = 0;
      int total = 0, delivered = 0, cancelled = 0;
      List<Map<String, dynamic>> transactions = [];

      void processOrder(dynamic key, dynamic val) {
        final order = Map<String, dynamic>.from(val);
        final status = (order['status'] ?? 'pending').toString().toLowerCase();
        final grand = (order['grandTotal'] ?? order['budget'] ?? 0);
        final amount =
            grand is int ? grand.toDouble() : (grand as num).toDouble();
        final isShopOrder = order['shopName'] != null;

        total++;
        if (status == 'delivered') {
          delivered++;
          totalOrderValue += amount;
          final delivery = isShopOrder ? _deliveryFee : 0.0;
          final commission = amount * _commissionRate;
          totalDelivery += delivery;
          totalRevenue += delivery + commission;
          transactions.add({
            'orderId': key.toString().substring(0, 6),
            'orderValue': amount,
            'deliveryFee': delivery,
            'commission': commission,
            'profit': delivery + commission,
            'shopName': order['shopName'] ?? order['shop'] ?? 'Custom Order',
            'status': status,
            'timestamp': order['createdAt'] ?? 0,
          });
        } else if (status == 'cancelled') {
          cancelled++;
        }
      }

      if (shopSnap.exists) {
        final data = shopSnap.value as Map<dynamic, dynamic>;
        data.forEach(processOrder);
      }

      transactions.sort((a, b) =>
          (b['timestamp'] as int).compareTo(a['timestamp'] as int));

      setState(() {
        _totalDeliveryFees = totalDelivery;
        _platformProfit = totalRevenue;
        _totalOrderValue = totalOrderValue;
        _totalOrders = total;
        _deliveredOrders = delivered;
        _cancelledOrders = cancelled;
        _recentTransactions = transactions.take(50).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F0),
      appBar: AppBar(
        title: const Text('Cash Management',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadData),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _loadData,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Summary card
                    _buildSummaryCard(),
                    const SizedBox(height: 16),

                    // Order stats
                    _buildOrderStats(),
                    const SizedBox(height: 16),

                    // Revenue breakdown
                    _buildRevenueBreakdown(),
                    const SizedBox(height: 16),

                    // Recent transactions
                    if (_recentTransactions.isNotEmpty) ...[
                      const Text('Recent Revenue',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      ..._recentTransactions.map(_buildTransactionCard),
                    ],
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Total Platform Profit',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            'Rs. ${_platformProfit.toStringAsFixed(0)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _pillStat('Orders', '$_deliveredOrders delivered'),
              const SizedBox(width: 12),
              _pillStat('GMV',
                  'Rs. ${_totalOrderValue.toStringAsFixed(0)}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pillStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 10)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildOrderStats() {
    return Row(
      children: [
        _statCard('Total Orders', '$_totalOrders', Icons.receipt_long,
            const Color(0xFFFF6B00)),
        const SizedBox(width: 10),
        _statCard('Delivered', '$_deliveredOrders', Icons.check_circle,
            Colors.green),
        const SizedBox(width: 10),
        _statCard('Cancelled', '$_cancelledOrders', Icons.cancel,
            Colors.red),
      ],
    );
  }

  Widget _statCard(
      String title, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
            )
          ],
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: color)),
            Text(title,
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildRevenueBreakdown() {
    final items = [
      {
        'label': 'Delivery Fees',
        'value': _totalDeliveryFees,
        'color': Colors.green,
        'icon': Icons.delivery_dining
      },
      {
        'label': 'Commissions (10%)',
        'value': _platformProfit - _totalDeliveryFees,
        'color': _primary,
        'icon': Icons.percent
      },
      {
        'label': 'Total Platform Revenue',
        'value': _platformProfit,
        'color': Colors.purple,
        'icon': Icons.account_balance_wallet
      },
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Revenue Breakdown',
              style:
                  TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: (item['color'] as Color).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(item['icon'] as IconData,
                          color: item['color'] as Color, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(item['label'] as String,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                    Text(
                      'Rs. ${(item['value'] as double).toStringAsFixed(0)}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: item['color'] as Color,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildTransactionCard(Map<String, dynamic> tx) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.trending_up,
                color: Colors.green, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tx['shopName'],
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
                Text('Order Value: Rs. ${tx['orderValue'].toStringAsFixed(0)}',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '+Rs. ${tx['profit'].toStringAsFixed(0)}',
                style: const TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              Text('Profit',
                  style:
                      TextStyle(fontSize: 10, color: Colors.grey[400])),
            ],
          ),
        ],
      ),
    );
  }
}
