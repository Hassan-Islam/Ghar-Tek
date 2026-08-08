import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter/material.dart';
import '../services/category_timing_service.dart';
import '../services/city_scope_service.dart';

class MerchantMenuDealsPage extends StatefulWidget {
  final Map<String, dynamic> shop;
  final bool canEditPrices;

  const MerchantMenuDealsPage({
    super.key,
    required this.shop,
    required this.canEditPrices,
  });

  @override
  State<MerchantMenuDealsPage> createState() => _MerchantMenuDealsPageState();
}

class _MerchantMenuDealsPageState extends State<MerchantMenuDealsPage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const Color _accent = Color(0xFFE85D04);
  static const List<String> _mealCategories = [
    'Breakfast',
    'Lunch',
    'Dinner',
  ];

    String _tenantPath(String path) => CityScopeService.tenantPath(path);

  DatabaseReference get _menuRef =>
      FirebaseDatabase.instance.ref(_tenantPath('shops/${widget.shop['id']}/menu'));
    DatabaseReference get _categoryScheduleRef => FirebaseDatabase.instance
      .ref(_tenantPath('shops/${widget.shop['id']}/categorySchedules'));

  final TextEditingController _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _showDealsOnly = false;
  bool _showLowStockOnly = false;
  String _selectedCategory = 'All';

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _filtered = [];
  Map<String, Map<String, dynamic>> _categorySchedules = {};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilters);
    _loadProducts();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  double _toDouble(dynamic value) {
    return double.tryParse(value?.toString() ?? '0') ?? 0;
  }

  int _toInt(dynamic value) {
    return int.tryParse(value?.toString() ?? '0') ?? 0;
  }

  String _toAmount(double value) {
    if ((value - value.roundToDouble()).abs() < 0.001) {
      return value.round().toString();
    }
    return value.toStringAsFixed(2);
  }

  String _normalizeCategoryKey(dynamic value) {
    return CategoryTimingService.normalizeCategory(value);
  }

  Map<String, Map<String, dynamic>> _parseCategorySchedules(dynamic raw) {
    final parsed = <String, Map<String, dynamic>>{};
    if (raw is! Map) return parsed;

    final map = Map<dynamic, dynamic>.from(raw);
    map.forEach((key, value) {
      if (value is! Map) return;
      final schedule = Map<String, dynamic>.from(value);
      final normalizedKey = _normalizeCategoryKey(schedule['category'] ?? key);
      if (normalizedKey.isEmpty) return;
      parsed[normalizedKey] = schedule;
    });

    return parsed;
  }

  bool _isCategoryWindowOpen(Map<String, dynamic> item) {
    return CategoryTimingService.isCategoryAvailable(
      schedules: _categorySchedules,
      category: item['category'] ?? item['type'],
    );
  }

  bool _isCategoryTimedOut(Map<String, dynamic> item) {
    final category = (item['category'] ?? item['type'] ?? '').toString().trim();
    if (category.isEmpty) return false;
    return !_isCategoryWindowOpen(item);
  }

  String _formatTimeOfDay(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  Future<String?> _pickTimeText(String currentText) async {
    final minutes = CategoryTimingService.parseTimeToMinutes(currentText);
    final initial = minutes == null
        ? TimeOfDay.now()
        : TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked == null) return null;
    return _formatTimeOfDay(picked);
  }

  bool _isDealActive(Map<String, dynamic> item) {
    final price = _toDouble(item['price']);
    final original = _toDouble(item['originalPrice']);
    if (!(original > 0 && original > price)) return false;

    final scheduleEnabled = item['dealScheduleEnabled'] == true;
    if (!scheduleEnabled) return true;

    final now = DateTime.now().millisecondsSinceEpoch;
    final startAt = int.tryParse((item['dealStartAt'] ?? '0').toString()) ?? 0;
    final endAt = int.tryParse((item['dealEndAt'] ?? '0').toString()) ?? 0;

    if (startAt <= 0 || endAt <= 0) return true;
    return now >= startAt && now <= endAt;
  }

  bool _isLowStock(Map<String, dynamic> item) {
    final stock = _toInt(item['stock']);
    final threshold = _toInt(item['lowStockThreshold']);
    return stock <= threshold;
  }

  List<String> get _categories {
    final set = <String>{};
    for (final p in _products) {
      final cat = (p['category'] ?? '').toString().trim();
      if (cat.isNotEmpty) set.add(cat);
    }
    final list = set.toList()..sort();
    return ['All', ...list];
  }

  List<Map<String, dynamic>> get _lowStockItems {
    return _products.where(_isLowStock).toList();
  }

  Future<void> _loadProducts() async {
    setState(() => _loading = true);

    try {
      final snap = await _menuRef.get();
      final categoryScheduleSnap = await _categoryScheduleRef.get();
      final products = <Map<String, dynamic>>[];
      final categorySchedules = _parseCategorySchedules(categoryScheduleSnap.value);

      if (snap.exists && snap.value is Map) {
        final map = snap.value as Map<dynamic, dynamic>;
        map.forEach((key, value) {
          if (value is Map) {
            final item = Map<String, dynamic>.from(value);
            item['id'] = key.toString();
            products.add(item);
          }
        });
      }

      products.sort((a, b) {
        final aName = (a['name'] ?? '').toString().toLowerCase();
        final bName = (b['name'] ?? '').toString().toLowerCase();
        return aName.compareTo(bName);
      });

      if (!mounted) return;
      setState(() {
        _products = products;
        _categorySchedules = categorySchedules;
        if (!_categories.contains(_selectedCategory)) {
          _selectedCategory = 'All';
        }
      });
      _applyFilters();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _products = [];
        _filtered = [];
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCategoryTimingManager() async {
    final categories = <String>{
      ..._mealCategories,
      ..._categories.where((c) => c != 'All' && c.trim().isNotEmpty),
    }.toList();

    if (categories.isEmpty) {
      _showInfo('Please add product categories first.');
      return;
    }

    final openCtrl = TextEditingController();
    final closeCtrl = TextEditingController();
    String selectedCategory = categories.first;
    bool enabled = true;

    void loadCategoryValues(StateSetter setS) {
      final schedule = _categorySchedules[_normalizeCategoryKey(selectedCategory)];
      enabled = schedule == null
          ? true
          : CategoryTimingService.toBool(schedule['enabled'], fallback: true);
      openCtrl.text = (schedule?['openTime'] ?? '10:00 AM').toString();
      closeCtrl.text = (schedule?['closeTime'] ?? '11:00 PM').toString();
      setS(() {});
    }

    final initialSchedule = _categorySchedules[_normalizeCategoryKey(selectedCategory)];
    enabled = initialSchedule == null
        ? true
        : CategoryTimingService.toBool(initialSchedule['enabled'], fallback: true);
    openCtrl.text = (initialSchedule?['openTime'] ?? '10:00 AM').toString();
    closeCtrl.text = (initialSchedule?['closeTime'] ?? '11:00 PM').toString();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final hasExistingSchedule =
              _categorySchedules.containsKey(_normalizeCategoryKey(selectedCategory));
          return AlertDialog(
            title: const Text('Category Timings'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Set a time window for each category. Outside this window, products appear out of stock.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedCategory,
                    items: categories
                        .map((category) => DropdownMenuItem(
                              value: category,
                              child: Text(category),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      selectedCategory = value;
                      loadCategoryValues(setS);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: enabled,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable time-based stock for this category'),
                    onChanged: (value) => setS(() => enabled = value),
                  ),
                  if (enabled) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: openCtrl,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Open Time',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.access_time_rounded),
                          onPressed: () async {
                            final text = await _pickTimeText(openCtrl.text);
                            if (text == null) return;
                            setS(() => openCtrl.text = text);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: closeCtrl,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Close Time',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.access_time_filled_rounded),
                          onPressed: () async {
                            final text = await _pickTimeText(closeCtrl.text);
                            if (text == null) return;
                            setS(() => closeCtrl.text = text);
                          },
                        ),
                      ),
                    ),
                  ],
                  if (hasExistingSchedule) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Saved: ${openCtrl.text} - ${closeCtrl.text}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: hasExistingSchedule
                    ? () async {
                        await _categoryScheduleRef
                            .child(_normalizeCategoryKey(selectedCategory))
                            .remove();
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx, true);
                        _showInfo('Removed timing for $selectedCategory');
                      }
                    : null,
                child: const Text('Remove'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (enabled) {
                    final openMinutes =
                        CategoryTimingService.parseTimeToMinutes(openCtrl.text);
                    final closeMinutes =
                        CategoryTimingService.parseTimeToMinutes(closeCtrl.text);
                    if (openMinutes == null || closeMinutes == null) {
                      _showInfo('Please select valid open/close times.');
                      return;
                    }
                  }

                  await _categoryScheduleRef
                      .child(_normalizeCategoryKey(selectedCategory))
                      .set({
                    'category': selectedCategory,
                    'enabled': enabled,
                    'openTime': openCtrl.text.trim().isEmpty
                        ? '10:00 AM'
                        : openCtrl.text.trim(),
                    'closeTime': closeCtrl.text.trim().isEmpty
                        ? '11:00 PM'
                        : closeCtrl.text.trim(),
                    'updatedAt': ServerValue.timestamp,
                  });

                  if (!ctx.mounted) return;
                  Navigator.pop(ctx, true);
                  _showInfo('Timing saved for $selectedCategory');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    openCtrl.dispose();
    closeCtrl.dispose();

    if (saved == true) {
      await _loadProducts();
    }
  }

  void _applyFilters() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _products.where((item) {
        final name = (item['name'] ?? '').toString().toLowerCase();
        final desc = (item['description'] ?? '').toString().toLowerCase();
        final category = (item['category'] ?? '').toString();

        final queryOk = q.isEmpty || name.contains(q) || desc.contains(q);
        final categoryOk = _selectedCategory == 'All' || category == _selectedCategory;
        final dealsOk = !_showDealsOnly || _isDealActive(item);
        final stockOk = !_showLowStockOnly || _isLowStock(item);

        return queryOk && categoryOk && dealsOk && stockOk;
      }).toList();
    });
  }

  Future<void> _toggleAvailability(Map<String, dynamic> product) async {
    final current = product['available'] != false;
    await _menuRef.child(product['id'].toString()).update({'available': !current});
    await _loadProducts();
  }

  Future<void> _deleteProduct(Map<String, dynamic> product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Product'),
        content: Text('Delete ${(product['name'] ?? 'this product')}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: _accent),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _menuRef.child(product['id'].toString()).remove();
    await _loadProducts();
  }

  Future<void> _openProductEditor({Map<String, dynamic>? product}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _MerchantProductEditorSheet(
        initial: product,
        canEditPrices: widget.canEditPrices,
      ),
    );

    if (result == null) return;

    if (product == null) {
      await _menuRef.push().set({...result, 'createdAt': DateTime.now().millisecondsSinceEpoch});
    } else {
      await _menuRef.child(product['id'].toString()).update(result);
    }

    await _loadProducts();
  }

  Future<void> _bulkUpdatePrice() async {
    if (!widget.canEditPrices) {
      _showInfo('Price editing disabled by admin');
      return;
    }

    final amountCtrl = TextEditingController();
    bool usePercent = true;
    bool increase = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Bulk Price Update'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Percent'),
                      selected: usePercent,
                      onSelected: (_) => setS(() => usePercent = true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Flat Rs.'),
                      selected: !usePercent,
                      onSelected: (_) => setS(() => usePercent = false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: usePercent ? 'Value (%)' : 'Value (Rs.)',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Decrease'),
                      selected: !increase,
                      onSelected: (_) => setS(() => increase = false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Increase'),
                      selected: increase,
                      onSelected: (_) => setS(() => increase = true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Applies to currently filtered products (${_filtered.length} items).',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final amount = double.tryParse(amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      _showInfo('Enter a valid amount');
      return;
    }

    int touched = 0;
    for (final item in _filtered) {
      final id = item['id']?.toString();
      if (id == null || id.isEmpty) continue;

      final patch = _buildBulkPatch(
        item,
        amount: amount,
        usePercent: usePercent,
        increase: increase,
      );

      if (patch.isEmpty) continue;
      touched++;
      await _menuRef.child(id).update(patch);
    }

    await _loadProducts();
    _showInfo('Bulk update completed on $touched products');
  }

  Map<String, dynamic> _buildBulkPatch(
    Map<String, dynamic> item, {
    required double amount,
    required bool usePercent,
    required bool increase,
  }) {
    final patch = <String, dynamic>{};

    double transform(double current) {
      if (usePercent) {
        final ratio = amount / 100;
        return increase ? current * (1 + ratio) : current * (1 - ratio);
      }
      return increase ? current + amount : current - amount;
    }

    final hasSizes = item['hasSizes'] == true;
    if (hasSizes && item['sizes'] is List) {
      final sizes = <Map<String, dynamic>>[];
      for (final raw in (item['sizes'] as List)) {
        if (raw is! Map) continue;
        final size = Map<String, dynamic>.from(raw);
        final price = _toDouble(size['price']);
        if (price <= 0) {
          sizes.add(size);
          continue;
        }
        final updated = transform(price).clamp(1, 9999999).toDouble();
        size['price'] = _toAmount(updated);
        sizes.add(size);
      }
      if (sizes.isNotEmpty) {
        patch['sizes'] = sizes;
        final firstPrice = _toDouble(sizes.first['price']);
        if (firstPrice > 0) patch['price'] = _toAmount(firstPrice);
      }
    } else {
      final price = _toDouble(item['price']);
      if (price > 0) {
        final updated = transform(price).clamp(1, 9999999).toDouble();
        patch['price'] = _toAmount(updated);
      }
    }

    if (patch.isNotEmpty) {
      patch['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    }

    return patch;
  }

  Future<void> _openDealScheduler(Map<String, dynamic> item) async {
    if (!widget.canEditPrices) {
      _showInfo('Deals editing disabled by admin');
      return;
    }

    final dealPriceCtrl = TextEditingController(
      text: (_toDouble(item['price']) > 0) ? _toAmount(_toDouble(item['price'])) : '',
    );
    final originalCtrl = TextEditingController(
      text: (_toDouble(item['originalPrice']) > 0)
          ? _toAmount(_toDouble(item['originalPrice']))
          : _toAmount(_toDouble(item['price'])),
    );

    DateTime start = DateTime.now().add(const Duration(minutes: 5));
    DateTime end = DateTime.now().add(const Duration(days: 1));

    final existingStart = int.tryParse((item['dealStartAt'] ?? '0').toString()) ?? 0;
    final existingEnd = int.tryParse((item['dealEndAt'] ?? '0').toString()) ?? 0;
    if (existingStart > 0) start = DateTime.fromMillisecondsSinceEpoch(existingStart);
    if (existingEnd > 0) end = DateTime.fromMillisecondsSinceEpoch(existingEnd);

    bool enabled = item['dealScheduleEnabled'] == true;

    Future<void> pickDateTime({required bool isStart, required StateSetter setS}) async {
      final base = isStart ? start : end;
      final date = await showDatePicker(
        context: context,
        initialDate: base,
        firstDate: DateTime.now().subtract(const Duration(days: 1)),
        lastDate: DateTime.now().add(const Duration(days: 365)),
      );
      if (date == null) return;
      if (!mounted) return;
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
      if (time == null) return;

      final value = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      setS(() {
        if (isStart) {
          start = value;
          if (!end.isAfter(start)) {
            end = start.add(const Duration(hours: 2));
          }
        } else {
          end = value;
          if (!end.isAfter(start)) {
            start = end.subtract(const Duration(hours: 2));
          }
        }
      });
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Deal Scheduler'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (item['name'] ?? 'Product').toString(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: originalCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Original Price (Rs.)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: dealPriceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Deal Price (Rs.)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: enabled,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable schedule window'),
                  onChanged: (v) => setS(() => enabled = v),
                ),
                if (enabled) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Deal Starts'),
                    subtitle: Text(start.toLocal().toString().substring(0, 16)),
                    trailing: const Icon(Icons.event_rounded),
                    onTap: () => pickDateTime(isStart: true, setS: setS),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Deal Ends'),
                    subtitle: Text(end.toLocal().toString().substring(0, 16)),
                    trailing: const Icon(Icons.event_busy_rounded),
                    onTap: () => pickDateTime(isStart: false, setS: setS),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    final original = double.tryParse(originalCtrl.text.trim());
    final deal = double.tryParse(dealPriceCtrl.text.trim());
    if (original == null || deal == null || original <= 0 || deal <= 0 || deal >= original) {
      _showInfo('Deal price must be lower than original price');
      return;
    }

    final patch = <String, dynamic>{
      'originalPrice': _toAmount(original),
      'price': _toAmount(deal),
      'dealScheduleEnabled': enabled,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };

    if (enabled) {
      patch['dealStartAt'] = start.millisecondsSinceEpoch;
      patch['dealEndAt'] = end.millisecondsSinceEpoch;
    } else {
      patch['dealStartAt'] = null;
      patch['dealEndAt'] = null;
    }

    await _menuRef.child(item['id'].toString()).update(patch);
    await _loadProducts();
    _showInfo('Deal schedule saved');
  }

  Future<void> _restockItem(Map<String, dynamic> item) async {
    final stock = _toInt(item['stock']);
    final threshold = _toInt(item['lowStockThreshold']);
    final target = threshold + 10;
    if (target <= stock) return;

    await _menuRef.child(item['id'].toString()).update({
      'stock': target,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await _loadProducts();
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: _primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F2),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Menu & Deals Studio', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            Text(
              (widget.shop['name'] ?? 'Shop').toString(),
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openCategoryTimingManager,
            icon: const Icon(Icons.schedule_rounded),
            tooltip: 'Category Timings',
          ),
          IconButton(onPressed: _loadProducts, icon: const Icon(Icons.refresh_rounded)),
          IconButton(
            onPressed: _bulkUpdatePrice,
            icon: const Icon(Icons.price_change_rounded),
            tooltip: 'Bulk Price Update',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openProductEditor(),
        backgroundColor: _accent,
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('Add Menu Item', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : Column(
              children: [
                _buildLowStockBanner(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search menu, category, description...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 42,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      _filterChip(
                        label: _showDealsOnly ? 'Deals On' : 'All Prices',
                        selected: _showDealsOnly,
                        onTap: () {
                          setState(() => _showDealsOnly = !_showDealsOnly);
                          _applyFilters();
                        },
                      ),
                      const SizedBox(width: 6),
                      _filterChip(
                        label: _showLowStockOnly ? 'Low Stock Only' : 'Stock: All',
                        selected: _showLowStockOnly,
                        onTap: () {
                          setState(() => _showLowStockOnly = !_showLowStockOnly);
                          _applyFilters();
                        },
                      ),
                      const SizedBox(width: 6),
                      ..._categories.map((cat) => Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _filterChip(
                              label: cat,
                              selected: _selectedCategory == cat,
                              onTap: () {
                                setState(() => _selectedCategory = cat);
                                _applyFilters();
                              },
                            ),
                          )),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _filtered.isEmpty
                      ? const Center(child: Text('No items found for current filters'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 100),
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) => _productCard(_filtered[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildLowStockBanner() {
    final lowStock = _lowStockItems;
    if (lowStock.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF2E8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            Icon(Icons.inventory_2_outlined, color: _primary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Stock looks healthy. No low-stock alerts right now.',
                style: TextStyle(fontWeight: FontWeight.w600, color: _accent),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD28A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: _accent),
              const SizedBox(width: 8),
              Text(
                'Low-stock alerts: ${lowStock.length}',
                style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFCC5200)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: lowStock.take(4).map((item) {
              final stock = _toInt(item['stock']);
              final threshold = _toInt(item['lowStockThreshold']);
              return ActionChip(
                backgroundColor: Colors.white,
                label: Text('${item['name'] ?? 'Item'} ($stock/$threshold)'),
                avatar: const Icon(Icons.add_box_rounded, size: 18, color: _accent),
                onPressed: () => _restockItem(item),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _filterChip({required String label, required bool selected, required VoidCallback onTap}) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: _primary,
      backgroundColor: Colors.white,
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.grey.shade700,
        fontWeight: FontWeight.w600,
      ),
      side: BorderSide(color: selected ? _primary : Colors.grey.shade300),
    );
  }

  Widget _productCard(Map<String, dynamic> item) {
    final name = (item['name'] ?? 'Product').toString();
    final price = _toDouble(item['price']);
    final original = _toDouble(item['originalPrice']);
    final manuallyAvailable = item['available'] != false;
    final categoryTimedOut = _isCategoryTimedOut(item);
    final available = manuallyAvailable && !categoryTimedOut;
    final stock = _toInt(item['stock']);
    final threshold = _toInt(item['lowStockThreshold']);
    final lowStock = stock <= threshold;
    final hasActiveDeal = _isDealActive(item);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: lowStock ? const Color(0xFFFFD28A) : Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Switch(
                value: manuallyAvailable,
                activeThumbColor: _primary,
                onChanged: (_) => _toggleAvailability(item),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _badge('Rs. ${_toAmount(price)}', color: const Color(0xFFFFF2E8), text: _primary),
              if (original > 0 && original > price)
                _badge('Was Rs. ${_toAmount(original)}', color: const Color(0xFFFFF7F0), text: Colors.black87),
              if (hasActiveDeal)
                _badge('Deal Active', color: const Color(0xFFFFEBDD), text: _accent),
              if (lowStock)
                _badge('Low Stock $stock/$threshold', color: const Color(0xFFFFF1E5), text: const Color(0xFFCC5200)),
              if (categoryTimedOut)
                _badge('Category Time Closed', color: const Color(0xFFFFEFEF), text: Colors.red),
              if (!available && !categoryTimedOut)
                _badge('Manually Unavailable', color: const Color(0xFFF3F3F3), text: Colors.black54),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openProductEditor(product: item),
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.canEditPrices ? () => _openDealScheduler(item) : null,
                  icon: const Icon(Icons.schedule_rounded, size: 18),
                  label: const Text('Schedule Deal'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _deleteProduct(item),
                icon: const Icon(Icons.delete_outline_rounded, color: _accent),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, {required Color color, required Color text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(fontSize: 11, color: text, fontWeight: FontWeight.w700)),
    );
  }
}

class _MerchantProductEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final bool canEditPrices;

  const _MerchantProductEditorSheet({
    required this.initial,
    required this.canEditPrices,
  });

  @override
  State<_MerchantProductEditorSheet> createState() => _MerchantProductEditorSheetState();
}

class _MerchantProductEditorSheetState extends State<_MerchantProductEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _imageCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _originalCtrl = TextEditingController();
  final _stockCtrl = TextEditingController();
  final _thresholdCtrl = TextEditingController();
  String _mealCategory = '';

  bool _available = true;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    if (p == null) {
      _thresholdCtrl.text = '5';
      _stockCtrl.text = '20';
      return;
    }

    _nameCtrl.text = (p['name'] ?? '').toString();
    _categoryCtrl.text = (p['category'] ?? '').toString();
    _mealCategory = _normalizeMealCategory(p['mealCategory'] ?? '');
    _descCtrl.text = (p['description'] ?? '').toString();
    _imageCtrl.text = (p['imageUrl'] ?? p['image'] ?? '').toString();
    _priceCtrl.text = (p['price'] ?? '').toString();
    _originalCtrl.text = (p['originalPrice'] ?? '').toString();
    _stockCtrl.text = (p['stock'] ?? 20).toString();
    _thresholdCtrl.text = (p['lowStockThreshold'] ?? 5).toString();
    _available = p['available'] != false;
  }

  String _normalizeMealCategory(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    final lower = raw.toLowerCase();
    if (lower == 'breakfast' || lower == 'nashta') return 'Breakfast';
    if (lower == 'lunch') return 'Lunch';
    if (lower == 'dinner') return 'Dinner';
    return '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _descCtrl.dispose();
    _imageCtrl.dispose();
    _priceCtrl.dispose();
    _originalCtrl.dispose();
    _stockCtrl.dispose();
    _thresholdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canEditPrices = widget.canEditPrices;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Text(
                  widget.initial == null ? 'Add Menu Item' : 'Edit Menu Item',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 14),
                _field(_nameCtrl, 'Name *', validator: (v) => v!.trim().isEmpty ? 'Required' : null),
                const SizedBox(height: 10),
                _field(_categoryCtrl, 'Category'),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _mealCategory.isEmpty ? 'None' : _mealCategory,
                  items: const [
                    DropdownMenuItem(value: 'None', child: Text('None')),
                    DropdownMenuItem(value: 'Breakfast', child: Text('Breakfast')),
                    DropdownMenuItem(value: 'Lunch', child: Text('Lunch')),
                    DropdownMenuItem(value: 'Dinner', child: Text('Dinner')),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _mealCategory = value == null || value == 'None' ? '' : value;
                    });
                  },
                  decoration: const InputDecoration(labelText: 'Meal Category (Trending)'),
                ),
                const SizedBox(height: 10),
                _field(_descCtrl, 'Description', maxLines: 2),
                const SizedBox(height: 10),
                _field(_imageCtrl, 'Image URL'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _priceCtrl,
                        'Price (Rs.) *',
                        keyboardType: TextInputType.number,
                        enabled: canEditPrices,
                        validator: (v) => v!.trim().isEmpty ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _field(
                        _originalCtrl,
                        'Original (Rs.)',
                        keyboardType: TextInputType.number,
                        enabled: canEditPrices,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _stockCtrl,
                        'Stock Qty',
                        keyboardType: TextInputType.number,
                        validator: (v) => v!.trim().isEmpty ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _field(
                        _thresholdCtrl,
                        'Low-stock Alert',
                        keyboardType: TextInputType.number,
                        validator: (v) => v!.trim().isEmpty ? 'Required' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Available for order'),
                  value: _available,
                  onChanged: (v) => setState(() => _available = v),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      if (!_formKey.currentState!.validate()) return;

                      final payload = <String, dynamic>{
                        'name': _nameCtrl.text.trim(),
                        'category': _categoryCtrl.text.trim(),
                        'mealCategory': _mealCategory,
                        'description': _descCtrl.text.trim(),
                        'imageUrl': _imageCtrl.text.trim(),
                        'available': _available,
                        'stock': int.tryParse(_stockCtrl.text.trim()) ?? 0,
                        'lowStockThreshold': int.tryParse(_thresholdCtrl.text.trim()) ?? 5,
                        'updatedAt': DateTime.now().millisecondsSinceEpoch,
                      };

                      if (canEditPrices) {
                        payload['price'] = _priceCtrl.text.trim();
                        payload['originalPrice'] = _originalCtrl.text.trim().isEmpty ? null : _originalCtrl.text.trim();
                      } else if (widget.initial != null) {
                        payload['price'] = widget.initial!['price'];
                        payload['originalPrice'] = widget.initial!['originalPrice'];
                      }

                      Navigator.pop(context, payload);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B00),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: const Text('Save Item', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    bool enabled = true,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      enabled: enabled,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
