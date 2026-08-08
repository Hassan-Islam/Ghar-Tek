import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';

import '../services/city_scope_service.dart';

class AdminShopsKhataPage extends StatefulWidget {
  const AdminShopsKhataPage({super.key, this.selectedRange});

  final DateTimeRange? selectedRange;

  @override
  State<AdminShopsKhataPage> createState() => _AdminShopsKhataPageState();
}

class _AdminShopsKhataPageState extends State<AdminShopsKhataPage> {
  static const Color _primary = Color(0xFFFF6B00);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _loading = true;
  double _commissionRate = 10;
  final List<_ShopKhata> _shops = [];
  String? _expandedShop;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  double _toDouble(dynamic v, {double fallback = 0}) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? fallback;
  }

  int _toInt(dynamic v, {int fallback = 1}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  int? _toMs(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

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

  List<Map<String, dynamic>> _extractItems(Map<String, dynamic> order) {
    final raw = order['items'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (order['whatYouWant'] != null) {
      return [
        {
          'name': order['whatYouWant'].toString(),
          'quantity': 1,
          'price': _toDouble(order['budget'] ?? order['grandTotal']),
          'shopName': order['shop'] ?? 'Custom Order',
        },
      ];
    }
    return const [];
  }

  void _addItemCount(Map<String, int> counts, String name, int qty) {
    final key = name.trim();
    if (key.isEmpty) return;
    counts[key] = (counts[key] ?? 0) + qty;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final feesSnap = await _db.child(_tenantPath('settings/fees')).get();
      if (feesSnap.exists && feesSnap.value is Map) {
        final fees = Map<String, dynamic>.from(feesSnap.value as Map);
        _commissionRate = _toDouble(
          fees['commissionRate'] ?? fees['taxPercent'] ?? 10,
          fallback: 10,
        );
      }

      final window = _window();
      final startMs = window.start.millisecondsSinceEpoch;
      final endMs = window.end.millisecondsSinceEpoch;
      final shopMap = <String, _ShopKhata>{};

      _ShopKhata shopBucket(String shopName) {
        return shopMap.putIfAbsent(
          shopName,
          () => _ShopKhata(shopName: shopName),
        );
      }

      void ingest(dynamic key, dynamic raw, {required bool isCustom}) {
        if (raw is! Map) return;
        final order = Map<String, dynamic>.from(raw);
        if ((order['status'] ?? '').toString().toLowerCase() != 'delivered') {
          return;
        }
        final deliveredAt = _toMs(order['deliveredAt']) ??
            _toMs(order['updatedAt']) ??
            _toMs(order['createdAt']);
        if (deliveredAt == null ||
            deliveredAt < startMs ||
            deliveredAt >= endMs) {
          return;
        }

        final orderId =
            (order['customOrderId'] ?? key ?? '').toString().trim();
        final items = _extractItems(order);

        if (isCustom || items.isEmpty) {
          final shopName = isCustom
              ? 'Custom Orders'
              : (order['shopName'] ?? order['shop'] ?? 'Unknown Shop')
                  .toString();
          final subtotal = _toDouble(
            order['subtotal'] ?? order['grandTotal'] ?? order['budget'],
          );
          final bucket = shopBucket(shopName);
          bucket.orders++;
          bucket.sales += subtotal;
          bucket.delivery += _toDouble(order['deliveryFee']);
          if (items.isEmpty && order['whatYouWant'] != null) {
            _addItemCount(
              bucket.itemCounts,
              order['whatYouWant'].toString(),
              1,
            );
          }
          bucket.orderLines.add(
            _ShopOrderLine(
              orderId: orderId.isEmpty ? key.toString() : orderId,
              items: items.isEmpty
                  ? [
                      _ItemLine(
                        name: order['whatYouWant']?.toString() ?? 'Custom item',
                        qty: 1,
                        lineTotal: subtotal,
                      ),
                    ]
                  : items
                      .map(
                        (it) => _ItemLine(
                          name: (it['name'] ?? 'Item').toString(),
                          qty: _toInt(it['quantity']),
                          lineTotal: _toDouble(it['price']) *
                              _toInt(it['quantity']),
                        ),
                      )
                      .toList(),
              subtotal: subtotal,
              grandTotal: _toDouble(order['grandTotal'] ?? subtotal),
            ),
          );
          return;
        }

        final itemsByShop = <String, List<Map<String, dynamic>>>{};
        for (final item in items) {
          final shop = (item['shopName'] ?? order['shopName'] ?? 'Unknown Shop')
              .toString()
              .trim();
          itemsByShop.putIfAbsent(shop, () => []).add(item);
        }

        for (final entry in itemsByShop.entries) {
          final shopName = entry.key;
          final shopItems = entry.value;
          var shopSubtotal = 0.0;
          final lines = <_ItemLine>[];

          for (final it in shopItems) {
            final qty = _toInt(it['quantity']);
            final price = _toDouble(it['price']);
            final line = price * qty;
            shopSubtotal += line;
            final name = (it['name'] ?? 'Item').toString();
            _addItemCount(shopBucket(shopName).itemCounts, name, qty);
            lines.add(_ItemLine(name: name, qty: qty, lineTotal: line));
          }

          final bucket = shopBucket(shopName);
          bucket.orders++;
          bucket.sales += shopSubtotal;
          if (itemsByShop.length == 1) {
            bucket.delivery += _toDouble(order['deliveryFee']);
          }
          bucket.orderLines.add(
            _ShopOrderLine(
              orderId: orderId.isEmpty ? key.toString() : orderId,
              items: lines,
              subtotal: shopSubtotal,
              grandTotal: _toDouble(order['grandTotal']),
            ),
          );
        }
      }

      final results = await Future.wait([
        _db.child(_tenantPath('shop-orders')).get(),
      ]);
      if (results[0].exists && results[0].value is Map) {
        (results[0].value as Map).forEach((k, v) => ingest(k, v, isCustom: false));
      }

      for (final shop in shopMap.values) {
        shop.commission = shop.sales * (_commissionRate / 100);
        shop.total = shop.sales + shop.delivery;
        shop.sortedItems = shop.itemCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
      }

      final rows = shopMap.values.toList()
        ..sort((a, b) => b.total.compareTo(a.total));

      if (mounted) {
        setState(() {
          _shops
            ..clear()
            ..addAll(rows);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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
          'Shops Hisab',
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
              child: _shops.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('No delivered orders in this range')),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                      itemCount: _shops.length,
                      itemBuilder: (ctx, i) => _buildShopCard(_shops[i]),
                    ),
            ),
    );
  }

  Widget _buildShopCard(_ShopKhata shop) {
    final expanded = _expandedShop == shop.shopName;
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
              _expandedShop = expanded ? null : shop.shopName;
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
                          color: const Color(0xFFFFF3E8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.storefront_rounded, color: _primary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shop.shopName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                              ),
                            ),
                            Text(
                              '${shop.orders} orders delivered',
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
                  _summaryRow('Total Sale', 'Rs. ${shop.sales.toStringAsFixed(0)}', _primary),
                  const SizedBox(height: 6),
                  _summaryRow('Delivery', 'Rs. ${shop.delivery.toStringAsFixed(0)}', Colors.blue),
                  const SizedBox(height: 6),
                  _summaryRow('Commission', 'Rs. ${shop.commission.toStringAsFixed(0)}', Colors.purple),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E8),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Shop Total: Rs. ${shop.total.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: _primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Items Sold (detail)'),
                  if (shop.sortedItems.isEmpty)
                    Text('No item breakdown', style: TextStyle(color: Colors.grey[500]))
                  else
                    ...shop.sortedItems.map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
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
                                '${e.value}×',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: _primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                e.key,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  _sectionTitle('Orders'),
                  ...shop.orderLines.map(_buildOrderLine),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13,
          color: Color(0xFF374151),
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, Color color) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        ),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildOrderLine(_ShopOrderLine line) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Order #${line.orderId}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ...line.items.map(
            (it) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text('${it.qty}× ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Expanded(child: Text(it.name)),
                  Text('Rs. ${it.lineTotal.toStringAsFixed(0)}'),
                ],
              ),
            ),
          ),
          const Divider(height: 16),
          Row(
            children: [
              const Text('Sale: ', style: TextStyle(fontSize: 12)),
              Text(
                'Rs. ${line.subtotal.toStringAsFixed(0)}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShopKhata {
  _ShopKhata({required this.shopName});

  final String shopName;
  int orders = 0;
  double sales = 0;
  double delivery = 0;
  double commission = 0;
  double total = 0;
  final Map<String, int> itemCounts = {};
  List<MapEntry<String, int>> sortedItems = [];
  final List<_ShopOrderLine> orderLines = [];
}

class _ShopOrderLine {
  _ShopOrderLine({
    required this.orderId,
    required this.items,
    required this.subtotal,
    required this.grandTotal,
  });

  final String orderId;
  final List<_ItemLine> items;
  final double subtotal;
  final double grandTotal;
}

class _ItemLine {
  _ItemLine({required this.name, required this.qty, required this.lineTotal});

  final String name;
  final int qty;
  final double lineTotal;
}
