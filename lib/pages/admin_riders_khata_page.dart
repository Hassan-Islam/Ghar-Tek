import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';

import '../services/city_scope_service.dart';
import 'admin_chats_page.dart';

class AdminRidersKhataPage extends StatefulWidget {
  const AdminRidersKhataPage({super.key, this.selectedRange});

  final DateTimeRange? selectedRange;

  @override
  State<AdminRidersKhataPage> createState() => _AdminRidersKhataPageState();
}

class _AdminRidersKhataPageState extends State<AdminRidersKhataPage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const double _normalEarning = 50;
  static const double _fastEarning = 100;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _loading = true;
  final List<_RiderKhata> _riders = [];
  String? _expandedRiderId;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  double _toDouble(dynamic v, {double fallback = 0}) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? fallback;
  }

  int? _toMs(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  bool _isFastDelivery(Map<String, dynamic> order) {
    final speed = (order['deliverySpeed'] ?? '').toString().toLowerCase();
    if (speed == 'fast') return true;
    return _toDouble(order['deliveryFee']) >= 75;
  }

  bool _isOnlineAppPayment(String method) {
    final m = method.toLowerCase();
    return m.contains('jazz') ||
        m.contains('easy') ||
        m.contains('bank') ||
        m.contains('online') ||
        m.contains('card') ||
        m.contains('transfer');
  }

  bool _riderCollectedOnline(String type) {
    return type.toLowerCase() == 'online';
  }

  String _fmtRs(double v) => 'Rs. ${v.toStringAsFixed(0)}';

  ({DateTime start, DateTime end}) _window() {
    if (widget.selectedRange != null) {
      final s = DateTime(
        widget.selectedRange!.start.year,
        widget.selectedRange!.start.month,
        widget.selectedRange!.start.day,
      );
      final e = DateTime(
        widget.selectedRange!.end.year,
        widget.selectedRange!.end.month,
        widget.selectedRange!.end.day,
        23,
        59,
        59,
        999,
      );
      return (start: s, end: e);
    }
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return (start: start, end: start.add(const Duration(days: 1)));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final window = _window();
      final startMs = window.start.millisecondsSinceEpoch;
      final endMs = window.end.millisecondsSinceEpoch;
      final riderMap = <String, _RiderKhata>{};

      void ingest(dynamic key, dynamic raw, {required String type}) {
        if (raw is! Map) return;
        final order = Map<String, dynamic>.from(raw);
        if ((order['status'] ?? '').toString().toLowerCase() != 'delivered') {
          return;
        }
        final riderId = (order['assignedRider'] ?? '').toString().trim();
        if (riderId.isEmpty) return;

        final deliveredAt = _toMs(order['deliveredAt']) ??
            _toMs(order['updatedAt']) ??
            _toMs(order['createdAt']);
        if (deliveredAt == null ||
            deliveredAt < startMs ||
            deliveredAt >= endMs) {
          return;
        }

        final rider = riderMap.putIfAbsent(
          riderId,
          () => _RiderKhata(
            riderId: riderId,
            riderName: (order['assignedRiderName'] ?? 'Rider').toString(),
            riderPhone: (order['assignedRiderPhone'] ?? '').toString(),
          ),
        );

        final isFast = _isFastDelivery(order);
        final earning = isFast ? _fastEarning : _normalEarning;
        final appPayment = _toDouble(
          order['orderPaymentAmount'] ??
              order['grandTotal'] ??
              order['budget'],
        );
        final appMethod =
            (order['paymentMethod'] ?? 'Cash on Delivery').toString();
        final riderType =
            (order['riderPaymentType'] ?? 'cash').toString().toLowerCase();
        final collected = _toDouble(
          order['riderCollectedAmount'],
          fallback: appPayment,
        );

        final expectedCash =
            _isOnlineAppPayment(appMethod) ? 0.0 : appPayment;
        final expectedOnline =
            _isOnlineAppPayment(appMethod) ? appPayment : 0.0;
        final collectedCash =
            _riderCollectedOnline(riderType) ? 0.0 : collected;
        final collectedOnline =
            _riderCollectedOnline(riderType) ? collected : 0.0;

        rider.totalOrders++;
        if (isFast) {
          rider.fastOrders++;
        } else {
          rider.normalOrders++;
        }
        rider.totalEarnings += earning;
        rider.expectedCash += expectedCash;
        rider.expectedOnline += expectedOnline;
        rider.collectedCash += collectedCash;
        rider.collectedOnline += collectedOnline;

        rider.orders.add(
          _RiderOrderKhata(
            id: key.toString(),
            orderType: type,
            orderCode: (order['customOrderId'] ?? key).toString(),
            shopName:
                (order['shopName'] ?? order['shop'] ?? 'Order').toString(),
            userId: (order['userId'] ?? '').toString(),
            userName:
                (order['userName'] ?? order['userEmail'] ?? 'Customer').toString(),
            userPhone:
                (order['contact'] ?? order['userPhone'] ?? '').toString(),
            isFast: isFast,
            earning: earning,
            appPayment: appPayment,
            appPaymentMethod: appMethod,
            riderCollected: collected,
            riderPaymentType: riderType,
            expectedCash: expectedCash,
            expectedOnline: expectedOnline,
            collectedCash: collectedCash,
            collectedOnline: collectedOnline,
            paymentDiff: collected - appPayment,
            deliveredAt: deliveredAt,
          ),
        );
      }

      final results = await Future.wait([
        _db.child(_tenantPath('shop-orders')).get(),
      ]);
      if (results[0].exists && results[0].value is Map) {
        (results[0].value as Map).forEach((k, v) => ingest(k, v, type: 'shop'));
      }

      final list = riderMap.values.toList()
        ..sort((a, b) => b.totalOrders.compareTo(a.totalOrders));

      if (mounted) {
        setState(() {
          _riders
            ..clear()
            ..addAll(list);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openAdminChat(_RiderOrderKhata order) {
    if (order.userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminChatDetailPage(
          userId: order.userId,
          userName: order.userName,
          userPhone: order.userPhone,
          orderId: order.id,
          orderType: order.orderType,
          orderCode: order.orderCode,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Riders Hisab',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _load,
              child: _riders.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('No rider deliveries in range')),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                      itemCount: _riders.length,
                      itemBuilder: (ctx, i) => _buildRiderCard(_riders[i]),
                    ),
            ),
    );
  }

  Widget _buildRiderCard(_RiderKhata rider) {
    final expanded = _expandedRiderId == rider.riderId;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() {
              _expandedRiderId = expanded ? null : rider.riderId;
            }),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0F2FE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.delivery_dining_rounded,
                          color: Color(0xFF0284C7),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rider.riderName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                              ),
                            ),
                            if (rider.riderPhone.isNotEmpty)
                              Text(
                                rider.riderPhone,
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: Colors.grey[500],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chip('Orders: ${rider.totalOrders}', Colors.blue),
                      _chip('Normal: ${rider.normalOrders}', Colors.green),
                      _chip('Fast: ${rider.fastOrders}', Colors.orange),
                      _chip(
                        'Earnings: ${_fmtRs(rider.totalEarnings)}',
                        _primary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _paymentSummaryBox(
                    title: 'App mein payment (expected)',
                    cash: rider.expectedCash,
                    online: rider.expectedOnline,
                    color: const Color(0xFF6366F1),
                  ),
                  const SizedBox(height: 8),
                  _paymentSummaryBox(
                    title: 'Rider ne li (actual)',
                    cash: rider.collectedCash,
                    online: rider.collectedOnline,
                    color: const Color(0xFF16A34A),
                  ),
                  if ((rider.collectedCash + rider.collectedOnline -
                              rider.expectedCash -
                              rider.expectedOnline)
                          .abs() >
                      0.5) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        'Total farq: ${_fmtRs((rider.collectedCash + rider.collectedOnline) - (rider.expectedCash + rider.expectedOnline))}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.red.shade700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Orders Detail',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  ...rider.orders.map(_buildOrderCard),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _paymentSummaryBox({
    required String title,
    required double cash,
    required double online,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text('Cash: ${_fmtRs(cash)}', style: const TextStyle(fontSize: 13))),
              Expanded(child: Text('Online: ${_fmtRs(online)}', style: const TextStyle(fontSize: 13))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOrderCard(_RiderOrderKhata order) {
    final diff = order.paymentDiff;
    final diffOk = diff.abs() < 0.5;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  order.shopName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: order.isFast
                      ? Colors.orange.shade50
                      : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  order.isFast ? 'Fast' : 'Normal',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: order.isFast ? Colors.orange : Colors.green,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Order #${order.orderCode}',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 10),
          _detailLine('App payment (show)', _fmtRs(order.appPayment)),
          _detailLine('App method', order.appPaymentMethod),
          _detailLine('Rider collected', _fmtRs(order.riderCollected)),
          _detailLine(
            'Rider ne li',
            order.riderPaymentType == 'online' ? 'Online' : 'Cash',
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Hona chahiye Cash', style: TextStyle(fontSize: 12)),
                    ),
                    Text(
                      _fmtRs(order.expectedCash),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Hona chahiye Online', style: TextStyle(fontSize: 12)),
                    ),
                    Text(
                      _fmtRs(order.expectedOnline),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Rider li Cash', style: TextStyle(fontSize: 12)),
                    ),
                    Text(
                      _fmtRs(order.collectedCash),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Rider li Online', style: TextStyle(fontSize: 12)),
                    ),
                    Text(
                      _fmtRs(order.collectedOnline),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'Farq: ${_fmtRs(diff)}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: diffOk ? Colors.green : Colors.red,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                'Earning: ${_fmtRs(order.earning)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _primary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _openAdminChat(order),
              icon: const Icon(Icons.chat_bubble_outline, size: 16),
              label: const Text('Message'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _RiderKhata {
  _RiderKhata({
    required this.riderId,
    required this.riderName,
    required this.riderPhone,
  });

  final String riderId;
  final String riderName;
  final String riderPhone;
  int totalOrders = 0;
  int normalOrders = 0;
  int fastOrders = 0;
  double totalEarnings = 0;
  double expectedCash = 0;
  double expectedOnline = 0;
  double collectedCash = 0;
  double collectedOnline = 0;
  final List<_RiderOrderKhata> orders = [];
}

class _RiderOrderKhata {
  _RiderOrderKhata({
    required this.id,
    required this.orderType,
    required this.orderCode,
    required this.shopName,
    required this.userId,
    required this.userName,
    required this.userPhone,
    required this.isFast,
    required this.earning,
    required this.appPayment,
    required this.appPaymentMethod,
    required this.riderCollected,
    required this.riderPaymentType,
    required this.expectedCash,
    required this.expectedOnline,
    required this.collectedCash,
    required this.collectedOnline,
    required this.paymentDiff,
    required this.deliveredAt,
  });

  final String id;
  final String orderType;
  final String orderCode;
  final String shopName;
  final String userId;
  final String userName;
  final String userPhone;
  final bool isFast;
  final double earning;
  final double appPayment;
  final String appPaymentMethod;
  final double riderCollected;
  final String riderPaymentType;
  final double expectedCash;
  final double expectedOnline;
  final double collectedCash;
  final double collectedOnline;
  final double paymentDiff;
  final int deliveredAt;
}
