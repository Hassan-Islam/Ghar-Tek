import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:image_picker/image_picker.dart';
import '../services/category_timing_service.dart';
import '../services/city_scope_service.dart';
import '../services/image_helper.dart';
import '../services/image_upload_service.dart';

class AdminProductsPage extends StatefulWidget {
  final Map<String, dynamic> shop;
  const AdminProductsPage({super.key, required this.shop});

  @override
  State<AdminProductsPage> createState() => _AdminProductsPageState();
}

class _AdminProductsPageState extends State<AdminProductsPage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const Color _primaryLight = Color(0xFFFFF3E8);
  static const Color _bg = Color(0xFFFAFAFA);
  static const List<String> _mealCategories = [
    'Breakfast',
    'Lunch',
    'Dinner',
  ];

    String _tenantPath(String path) => CityScopeService.tenantPath(path);

  DatabaseReference get _ref =>
      FirebaseDatabase.instance.ref(_tenantPath('shops/${widget.shop['id']}/menu'));

  DatabaseReference get _legacyProductsRef =>
      FirebaseDatabase.instance.ref(_tenantPath('shops/${widget.shop['id']}/products'));

    DatabaseReference get _categoryScheduleRef =>
      FirebaseDatabase.instance.ref(_tenantPath('shops/${widget.shop['id']}/categorySchedules'));

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _isLoading = true;
  String _search = '';
  String _selectedCategory = 'All';
  Map<String, Map<String, dynamic>> _categorySchedules = {};

  @override
  void initState() {
    super.initState();
    _initTenantAndLoad();
  }

  Future<void> _initTenantAndLoad() async {
    await CityScopeService.ensureLoaded();
    if (!mounted) return;
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    try {
      final categoryScheduleSnap = await _categoryScheduleRef.get();
      final categorySchedules = _parseCategorySchedules(categoryScheduleSnap.value);

      final menuSnap = await _ref.get();
      if (menuSnap.exists) {
        final data = menuSnap.value as Map<dynamic, dynamic>;
        _products = data.entries.map((e) {
          final v = Map<String, dynamic>.from(e.value as Map);
          v['id'] = e.key;
          return v;
        }).toList();
      } else {
        final legacySnap = await _legacyProductsRef.get();
        if (legacySnap.exists) {
          final legacyData = legacySnap.value as Map<dynamic, dynamic>;
          _products = legacyData.entries.map((e) {
            final v = Map<String, dynamic>.from(e.value as Map);
            v['id'] = e.key;
            return v;
          }).toList();
          await _ref.set(legacyData);
        } else {
          _products = [];
        }
      }

      _categorySchedules = categorySchedules;
    } catch (_) {
      _products = [];
      _categorySchedules = {};
    }
    _applyFilter();
    setState(() => _isLoading = false);
  }

  void _applyFilter() {
    final q = _search.toLowerCase();
    setState(() {
      _filtered = _products.where((p) {
        final matchSearch = q.isEmpty ||
            (p['name'] ?? '').toString().toLowerCase().contains(q);
        final cat = p['category']?.toString() ?? '';
        final matchCat = _selectedCategory == 'All' || cat == _selectedCategory;
        return matchSearch && matchCat;
      }).toList();
    });
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

  Map<String, dynamic>? _scheduleForCategory(String category) {
    final key = _normalizeCategoryKey(category);
    if (key.isEmpty) return null;
    return _categorySchedules[key];
  }

  bool _isCategoryTimedOut(Map<String, dynamic> product) {
    final category = (product['category'] ?? '').toString().trim();
    if (category.isEmpty) return false;

    return !CategoryTimingService.isCategoryAvailable(
      schedules: _categorySchedules,
      category: category,
    );
  }

  String _scheduleRange(Map<String, dynamic> schedule) {
    final open = (schedule['openTime'] ?? '').toString().trim();
    final close = (schedule['closeTime'] ?? '').toString().trim();
    if (open.isEmpty || close.isEmpty) return 'Timing not complete';
    return '$open - $close';
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

  Future<void> _openCategoryTimingDialog() async {
    final categories = <String>{
      ..._mealCategories,
      ..._categories.where((c) => c != 'All' && c.trim().isNotEmpty),
    }.toList();

    if (categories.isEmpty) {
      _showInfo('Pehle categories wale products add karein.');
      return;
    }

    final openCtrl = TextEditingController();
    final closeCtrl = TextEditingController();
    String selectedCategory = categories.first;
    bool enabled = true;

    void loadCategoryValues(StateSetter setS) {
      final schedule = _scheduleForCategory(selectedCategory);
      enabled = schedule == null
          ? true
          : CategoryTimingService.toBool(schedule['enabled'], fallback: true);
      openCtrl.text = (schedule?['openTime'] ?? '10:00 AM').toString();
      closeCtrl.text = (schedule?['closeTime'] ?? '11:00 PM').toString();
      setS(() {});
    }

    final initialSchedule = _scheduleForCategory(selectedCategory);
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
              _scheduleForCategory(selectedCategory) != null;

          return AlertDialog(
            title: const Text('Meal Timings (Admin)'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Breakfast/Lunch/Dinner ka open/close time set karein. Window ke bahar ye meal category out of stock show hogi.',
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
                    title: const Text('Enable timing for this category'),
                    onChanged: (value) => setS(() => enabled = value),
                  ),
                  if (enabled) ...[
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
                      'Current: ${openCtrl.text} - ${closeCtrl.text}',
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
                        _showInfo('Timing removed for $selectedCategory');
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
                      _showInfo('Valid open/close time select karein.');
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

  List<String> get _categories {
    final cats = _products.map((p) => p['category']?.toString() ?? '').toSet().toList();
    cats.sort();
    return ['All', ...cats.where((c) => c.isNotEmpty)];
  }

  String _resolveProductImage(Map<String, dynamic> product) {
    const keys = <String>[
      'imageUrl',
      'image',
      'photo',
      'photoUrl',
      'photoURL',
      'thumbnail',
      'thumbnailUrl',
      'secure_url',
      'productImage',
      'url',
    ];
    for (final key in keys) {
      final value = ImageHelper.getDirectImageUrl((product[key] ?? '').toString());
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<void> _toggleAvailability(Map<String, dynamic> product) async {
    final current = product['available'] != false;
    await _ref.child(product['id']).update({'available': !current});
    setState(() => product['available'] = !current);
  }

  Future<void> _deleteProduct(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Product'),
        content: const Text('Are you sure you want to delete this product?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _ref.child(id).remove();
      await _loadProducts();
    }
  }

  void _openProductForm({Map<String, dynamic>? product}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ProductFormPage(
          shopId: widget.shop['id'],
          product: product,
          onSaved: _loadProducts,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.shop['name'] ?? 'Products',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: Colors.white)),
            const Text('Manage Menu', style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: _primary,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.schedule_rounded, color: Colors.white),
            tooltip: 'Meal Timings',
            onPressed: _openCategoryTimingDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: _loadProducts,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openProductForm(),
        backgroundColor: _primary,
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('Add Product', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              onChanged: (v) {
                _search = v;
                _applyFilter();
              },
              decoration: InputDecoration(
                hintText: 'Search products...',
                hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded, color: _primary, size: 20),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.grey[200]!),
                ),
              ),
            ),
          ),
          // Category chips
          if (_categories.length > 1)
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _categories.length,
                itemBuilder: (_, i) {
                  final cat = _categories[i];
                  final selected = cat == _selectedCategory;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(cat),
                      selected: selected,
                      onSelected: (_) {
                        setState(() => _selectedCategory = cat);
                        _applyFilter();
                      },
                      selectedColor: _primary,
                      backgroundColor: Colors.white,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : Colors.grey[700],
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      side: BorderSide(color: selected ? _primary : Colors.grey[200]!),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 4),
          // Products list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: _primary))
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.fastfood_rounded, size: 64, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('No products found',
                                style: TextStyle(color: Colors.grey[500], fontSize: 16, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Text('Tap + to add your first product',
                                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: _filtered.length,
                        itemBuilder: (_, i) => _buildProductCard(_filtered[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product) {
    final available = product['available'] != false;
    final price = product['price']?.toString() ?? '0';
    final imageUrl = _resolveProductImage(product);
    final hasSizes = product['hasSizes'] == true;
    final category = (product['category'] ?? '').toString();
    final mealCategory = (product['mealCategory'] ?? '').toString();
    final categoryTimedOut = _isCategoryTimedOut(product);
    final schedule = _scheduleForCategory(category);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openProductForm(product: product),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Image
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: imageUrl.isNotEmpty
                    ? ImageHelper.networkImage(url: imageUrl, width: 72, height: 72)
                    : Container(
                        width: 72,
                        height: 72,
                        color: _primaryLight,
                        child: const Icon(Icons.fastfood_rounded, color: _primary, size: 32),
                      ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  product['name'] ?? '',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if ((double.tryParse((product['rating'] ?? '0').toString()) ?? 0) > 0) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.star_rounded, color: Colors.orange, size: 14),
                                const SizedBox(width: 2),
                                Text(
                                  (product['rating'] ?? '0').toString(),
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (hasSizes)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue[50],
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('Sizes', style: TextStyle(fontSize: 10, color: Colors.blue[700], fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    if ((product['category'] ?? '').toString().isNotEmpty)
                      Text(
                        product['category'],
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    if (mealCategory.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Meal: $mealCategory',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.orange[700],
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      hasSizes ? 'Multiple sizes' : 'Rs. $price',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: hasSizes ? Colors.grey[600] : _primary,
                      ),
                    ),
                    if (categoryTimedOut && schedule != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Out of stock by category timing (${_scheduleRange(schedule)})',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.red[700],
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Actions column
              Column(
                children: [
                  // Availability toggle
                  Switch(
                    value: available,
                    onChanged: (_) => _toggleAvailability(product),
                    activeThumbColor: _primary,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  // Delete
                  GestureDetector(
                    onTap: () => _deleteProduct(product['id']),
                    child: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Product Form ------------------------------------------------------------

class _SizeEntry {
  String label;
  String price;
  String originalPrice;
  _SizeEntry({this.label = '', this.price = '', this.originalPrice = ''});
}

class _ProductFormPage extends StatefulWidget {
  final String shopId;
  final Map<String, dynamic>? product;
  final VoidCallback onSaved;

  const _ProductFormPage({
    required this.shopId,
    this.product,
    required this.onSaved,
  });

  @override
  State<_ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<_ProductFormPage> {
  static const Color _primary = Color(0xFFFF6B00);

  final ImagePicker _imagePicker = ImagePicker();
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _originalPriceCtrl = TextEditingController();
  final _extraChargeValueCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  
  List<String> _existingCategories = [
    'Biryani', 'Burger', 'FastFood', 'Ice Cream', 'Pizza',
    'Groceries', 'Cold Drink', 'Juices', 'Tea & Coffee', 'Cakes', 'Instant',
  ];
  String _mealCategory = '';
  final _trendingStartCtrl = TextEditingController();
  final _trendingEndCtrl = TextEditingController();
  final _imageUrlCtrl = TextEditingController();
  String _extraChargeType = 'none';

  bool _hasSizes = false;
  bool _available = true;
  bool _freeDelivery = false;
  bool _isHot = false;
  bool _isDiscount = false;
  bool _isSaving = false;
  bool _isUploadingImage = false;
  List<_SizeEntry> _sizes = [_SizeEntry()];

  void _onImageUrlChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    if (p != null) {
      _nameCtrl.text = p['name'] ?? '';
      _descCtrl.text = p['description'] ?? '';
      _priceCtrl.text = p['price']?.toString() ?? '';
      _originalPriceCtrl.text = (p['originalPrice'] ?? p['oldPrice'])?.toString() ?? '';
      _extraChargeType = (p['extraChargeType'] ?? p['platformFeeType'] ?? 'none').toString();
      _extraChargeValueCtrl.text = (p['extraChargeValue'] ?? p['platformFeeValue'] ?? 0).toString();
      _categoryCtrl.text = p['category'] ?? '';
      _mealCategory = _normalizeMealCategory(p['mealCategory'] ?? '');
      _trendingStartCtrl.text = (p['trendingStartTime'] ?? p['trendingOpenTime'] ?? '').toString();
      _trendingEndCtrl.text = (p['trendingEndTime'] ?? p['trendingCloseTime'] ?? '').toString();
      _imageUrlCtrl.text = ImageHelper.getDirectImageUrl(
        (p['imageUrl'] ??
            p['image'] ??
            p['photo'] ??
            p['photoUrl'] ??
            p['thumbnail'] ??
            p['secure_url'] ??
            '')
        .toString(),
      );
      _available = p['available'] != false;
      _hasSizes = p['hasSizes'] == true;
      _freeDelivery = p['freeDelivery'] == true || p['deliveryFree'] == true;
      _isHot = p['isHot'] == true || (p['tag'] ?? '').toString().toLowerCase().contains('hot');
      _isDiscount = p['isDiscount'] == true || (double.tryParse((p['originalPrice'] ?? '').toString()) ?? 0) > (double.tryParse((p['price'] ?? '').toString()) ?? 0);
      if (_hasSizes && p['sizes'] is List) {
        _sizes = (p['sizes'] as List).map((s) {
          final m = Map<String, dynamic>.from(s as Map);
          return _SizeEntry(
            label: m['label']?.toString() ?? '',
            price: m['price']?.toString() ?? '',
            originalPrice: (m['originalPrice'] ?? m['oldPrice'])?.toString() ?? '',
          );
        }).toList();
        if (_sizes.isEmpty) _sizes = [_SizeEntry()];
      }
    } else {
      _extraChargeType = 'none';
      _extraChargeValueCtrl.text = '';
    }

    _imageUrlCtrl.addListener(_onImageUrlChanged);
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      await CityScopeService.ensureLoaded();
      final shopsRef = FirebaseDatabase.instance.ref(CityScopeService.tenantPath('shops'));
      final snap = await shopsRef.get();
      if (snap.exists && snap.value is Map) {
        final shops = Map<dynamic, dynamic>.from(snap.value as Map);
        final Set<String> categories = Set.from(_existingCategories);
        
        for (final shopEntry in shops.values) {
          if (shopEntry is! Map) continue;
          final shopData = Map<dynamic, dynamic>.from(shopEntry);
          if (shopData.containsKey('menu') && shopData['menu'] is Map) {
            final menu = Map<dynamic, dynamic>.from(shopData['menu']);
            for (final prodEntry in menu.values) {
              if (prodEntry is! Map) continue;
              final cat = (prodEntry['category'] ?? '').toString().trim();
              if (cat.isNotEmpty) {
                categories.add(cat);
              }
            }
          }
        }
        if (mounted) {
          setState(() {
            _existingCategories = categories.toList()..sort();
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading categories: $e');
    }
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
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _originalPriceCtrl.dispose();
    _extraChargeValueCtrl.dispose();
    _categoryCtrl.dispose();
    _trendingStartCtrl.dispose();
    _trendingEndCtrl.dispose();
    _imageUrlCtrl.removeListener(_onImageUrlChanged);
    _imageUrlCtrl.dispose();
    super.dispose();
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

  Future<void> _pickAndUploadProductImage() async {
    if (_isUploadingImage) return;

    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1920,
      );
      if (pickedFile == null) return;

      setState(() => _isUploadingImage = true);

      final result = await ImageUploadService.uploadImage(
        file: pickedFile,
        useCase: ImageUploadUseCase.product,
      );

      if (!mounted) return;

      _imageUrlCtrl.text = result.url;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Product image uploaded successfully.'),
          backgroundColor: _primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUploadingImage = false);
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final normalizedImageUrl =
        ImageUploadService.normalizeImageUrl(_imageUrlCtrl.text);
    if (normalizedImageUrl.isNotEmpty &&
        !ImageUploadService.isCloudinaryUrl(normalizedImageUrl)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please use Cloudinary image URL or upload via Upload Product Image.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    final data = <String, dynamic>{
      'name': _nameCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'category': _categoryCtrl.text.trim(),
      'mealCategory': _mealCategory,
      'trendingCategory': _mealCategory,
      'trendingStartTime': _trendingStartCtrl.text.trim(),
      'trendingEndTime': _trendingEndCtrl.text.trim(),
      'trendingEnabled': _trendingStartCtrl.text.trim().isNotEmpty && _trendingEndCtrl.text.trim().isNotEmpty,
      'imageUrl': normalizedImageUrl,
      'available': _available,
      'isTrending': _trendingStartCtrl.text.trim().isNotEmpty && _trendingEndCtrl.text.trim().isNotEmpty,
      'isHotSelling': _trendingStartCtrl.text.trim().isNotEmpty && _trendingEndCtrl.text.trim().isNotEmpty,
      'isHot': _isHot,
      'isDiscount': _isDiscount,
      'freeDelivery': _freeDelivery,
      'hasSizes': _hasSizes,
      'extraChargeType': _extraChargeType,
      'extraChargeValue': double.tryParse(_extraChargeValueCtrl.text.trim()) ?? 0,
    };

    if (_hasSizes) {
      data['sizes'] = _sizes
          .where((s) => s.label.isNotEmpty && s.price.isNotEmpty)
          .map((s) => {
                'label': s.label,
                'price': s.price,
                if (s.originalPrice.trim().isNotEmpty) 'originalPrice': s.originalPrice.trim(),
              })
          .toList();
      final firstValidSize = _sizes.firstWhere(
        (s) => s.label.isNotEmpty && s.price.isNotEmpty,
        orElse: () => _SizeEntry(),
      );
      data['price'] = firstValidSize.price.isNotEmpty ? firstValidSize.price : '0';
      if (firstValidSize.originalPrice.trim().isNotEmpty) {
        data['originalPrice'] = firstValidSize.originalPrice.trim();
      } else {
        data['originalPrice'] = null;
      }
    } else {
      data['price'] = _priceCtrl.text.trim();
      final originalValue = _originalPriceCtrl.text.trim();
      if (originalValue.isNotEmpty) {
        data['originalPrice'] = originalValue;
      } else {
        data['originalPrice'] = null;
      }
      data['sizes'] = null;
    }

    await CityScopeService.ensureLoaded();
    final ref = FirebaseDatabase.instance.ref(CityScopeService.tenantPath('shops/${widget.shopId}/menu'));
    try {
      if (widget.product != null) {
        await ref.child(widget.product!['id']).update(data);
      } else {
        await ref.push().set(data);
      }
      widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showGlobalProductSearch() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return const _GlobalProductSearchSheet();
      },
    ).then((selectedProduct) {
      if (selectedProduct != null && selectedProduct is Map<String, dynamic>) {
        setState(() {
          _nameCtrl.text = selectedProduct['name'] ?? '';
          _descCtrl.text = selectedProduct['description'] ?? '';
          _priceCtrl.text = selectedProduct['price']?.toString() ?? '';
          _originalPriceCtrl.text = (selectedProduct['originalPrice'] ?? selectedProduct['oldPrice'])?.toString() ?? '';
          _extraChargeType = (selectedProduct['extraChargeType'] ?? selectedProduct['platformFeeType'] ?? 'none').toString();
          _extraChargeValueCtrl.text = (selectedProduct['extraChargeValue'] ?? selectedProduct['platformFeeValue'] ?? 0).toString();
          _categoryCtrl.text = selectedProduct['category'] ?? '';
          _mealCategory = _normalizeMealCategory(selectedProduct['mealCategory'] ?? '');
          _trendingStartCtrl.text = (selectedProduct['trendingStartTime'] ?? selectedProduct['trendingOpenTime'] ?? '').toString();
          _trendingEndCtrl.text = (selectedProduct['trendingEndTime'] ?? selectedProduct['trendingCloseTime'] ?? '').toString();
          _imageUrlCtrl.text = ImageHelper.getDirectImageUrl(
            (selectedProduct['imageUrl'] ??
                selectedProduct['image'] ??
                selectedProduct['photo'] ??
                selectedProduct['photoUrl'] ??
                selectedProduct['thumbnail'] ??
                selectedProduct['secure_url'] ??
                '')
            .toString(),
          );
          _available = selectedProduct['available'] != false;
          _hasSizes = selectedProduct['hasSizes'] == true;
          _freeDelivery = selectedProduct['freeDelivery'] == true || selectedProduct['deliveryFree'] == true;
          
          if (_hasSizes && selectedProduct['sizes'] is List) {
            _sizes = (selectedProduct['sizes'] as List).map((s) {
              final m = Map<String, dynamic>.from(s as Map);
              return _SizeEntry(
                label: m['label']?.toString() ?? '',
                price: m['price']?.toString() ?? '',
                originalPrice: (m['originalPrice'] ?? m['oldPrice'])?.toString() ?? '',
              );
            }).toList();
            if (_sizes.isEmpty) _sizes = [_SizeEntry()];
          }
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Product details imported! You can now edit and save.'),
            backgroundColor: _primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.product != null;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(isEdit ? 'Edit Product' : 'Add Product',
            style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
        backgroundColor: _primary,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (!isEdit)
            IconButton(
              icon: const Icon(Icons.manage_search_rounded, color: Colors.white),
              tooltip: 'Search existing products',
              onPressed: _showGlobalProductSearch,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _field('Product Name *', _nameCtrl, validator: (v) => v!.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 14),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _categoryCtrl.text),
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text.isEmpty) {
                  return _existingCategories;
                }
                return _existingCategories.where((String option) {
                  return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                });
              },
              onSelected: (String selection) {
                _categoryCtrl.text = selection;
              },
              fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                // Keep controllers in sync
                textEditingController.addListener(() {
                  _categoryCtrl.text = textEditingController.text;
                });
                return TextFormField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  decoration: _inputDecoration(
                    'Category (Instant = 20 min delivery, Islamabad only)',
                  ),
                  style: const TextStyle(fontSize: 14),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: 200, maxWidth: MediaQuery.of(context).size.width - 40),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (BuildContext context, int index) {
                          final String option = options.elementAt(index);
                          return InkWell(
                            onTap: () => onSelected(option),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text(option),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
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
              decoration: const InputDecoration(
                labelText: 'Trending Category'
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.schedule_rounded, color: _primary, size: 20),
                      SizedBox(width: 10),
                      Text(
                        'Trending Timing',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _trendingStartCtrl,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'Start Time',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.access_time_rounded),
                        onPressed: () async {
                          final picked = await _pickTimeText(_trendingStartCtrl.text);
                          if (picked == null) return;
                          setState(() => _trendingStartCtrl.text = picked);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _trendingEndCtrl,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'End Time',
                      border: const OutlineInputBorder(),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.access_time_filled_rounded),
                            onPressed: () async {
                              final picked = await _pickTimeText(_trendingEndCtrl.text);
                              if (picked == null) return;
                              setState(() => _trendingEndCtrl.text = picked);
                            },
                          ),
                          if (_trendingStartCtrl.text.trim().isNotEmpty || _trendingEndCtrl.text.trim().isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => setState(() {
                                _trendingStartCtrl.clear();
                                _trendingEndCtrl.clear();
                              }),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Category aur timing save karne ke baad yeh product sirf usi time window mein Trending Products mein dikhega.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _field('Description', _descCtrl, maxLines: 3),
            const SizedBox(height: 14),
            _field('Image URL (Cloudinary)', _imageUrlCtrl),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isUploadingImage ? null : _pickAndUploadProductImage,
                    icon: _isUploadingImage
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_rounded, size: 18),
                    label: Text(_isUploadingImage ? 'Uploading...' : 'Upload Product Image'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _primary,
                      side: const BorderSide(color: _primary),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _imageUrlCtrl.text.trim().isEmpty
                      ? null
                      : () => setState(() => _imageUrlCtrl.clear()),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Remove'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(color: Colors.red.shade200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
            if (_imageUrlCtrl.text.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: ImageHelper.networkImage(
                    url: _imageUrlCtrl.text.trim(),
                    fit: BoxFit.cover,
                    placeholder: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: _primary),
                      ),
                    ),
                    errorWidget: Container(
                      color: const Color(0xFFFFF3E8),
                      alignment: Alignment.center,
                      child: const Text(
                        'Image preview unavailable',
                        style: TextStyle(
                            color: Color(0xFF9A734C),
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            // Availability toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline_rounded, color: _primary, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Available', style: TextStyle(fontWeight: FontWeight.w600))),
                  Switch(
                    value: _available,
                    onChanged: (v) => setState(() => _available = v),
                    activeThumbColor: _primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Free delivery toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.local_shipping_rounded,
                    color: _primary,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Free Delivery for this Product',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Switch(
                    value: _freeDelivery,
                    onChanged: (v) => setState(() => _freeDelivery = v),
                    activeThumbColor: _primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Hot toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.whatshot_rounded, color: _primary, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Hot Product', style: TextStyle(fontWeight: FontWeight.w600))),
                  Switch(
                    value: _isHot,
                    onChanged: (v) => setState(() => _isHot = v),
                    activeThumbColor: _primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Discount toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_offer_rounded, color: _primary, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Discounted Product', style: TextStyle(fontWeight: FontWeight.w600))),
                  Switch(
                    value: _isDiscount,
                    onChanged: (v) => setState(() => _isDiscount = v),
                    activeThumbColor: _primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Has sizes toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F9F9),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.format_list_bulleted_rounded, color: _primary, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Has Multiple Sizes', style: TextStyle(fontWeight: FontWeight.w600))),
                  Switch(
                    value: _hasSizes,
                    onChanged: (v) => setState(() => _hasSizes = v),
                    activeThumbColor: _primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Price or sizes
            if (!_hasSizes)
              _field('Discounted Price (Rs.) *', _priceCtrl,
                  keyboardType: TextInputType.number,
                  validator: (v) => v!.trim().isEmpty ? 'Required' : null),
            if (!_hasSizes) ...[
              const SizedBox(height: 14),
              _field('Original Price (Rs.) (Optional)', _originalPriceCtrl,
                  keyboardType: TextInputType.number),
            ],
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _extraChargeType.isEmpty ? 'none' : _extraChargeType,
              decoration: _inputDecoration('Extra Charge / Commission Type'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('None')),
                DropdownMenuItem(value: 'percent', child: Text('Percent (%)')),
                DropdownMenuItem(value: 'fixed', child: Text('Fixed (Rs.)')),
              ],
              onChanged: (v) => setState(() => _extraChargeType = v ?? 'none'),
            ),
            const SizedBox(height: 14),
            _field(
              _extraChargeType == 'percent'
                  ? 'Extra Charge Value (%)'
                  : 'Extra Charge Value (Rs.)',
              _extraChargeValueCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            if (_hasSizes) ...[
              Row(
                children: [
                  const Text('Sizes & Prices', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => setState(() => _sizes.add(_SizeEntry())),
                    icon: const Icon(Icons.add_rounded, size: 18, color: _primary),
                    label: const Text('Add Size', style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              ..._sizes.asMap().entries.map((entry) {
                final i = entry.key;
                final s = entry.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isCompact = constraints.maxWidth < 520;

                      final removeButton = _sizes.length > 1
                          ? IconButton(
                              icon: const Icon(Icons.remove_circle_outline_rounded, color: Colors.red, size: 20),
                              onPressed: () => setState(() => _sizes.removeAt(i)),
                            )
                          : const SizedBox.shrink();

                      if (isCompact) {
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFCFCFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: Column(
                            children: [
                              TextFormField(
                                initialValue: s.label,
                                onChanged: (v) => s.label = v,
                                decoration: _inputDecoration('Label (e.g. Half)'),
                                style: const TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: s.price,
                                      onChanged: (v) => s.price = v,
                                      keyboardType: TextInputType.number,
                                      decoration: _inputDecoration('Rs.'),
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: s.originalPrice,
                                      onChanged: (v) => s.originalPrice = v,
                                      keyboardType: TextInputType.number,
                                      decoration: _inputDecoration('Orig. Rs.'),
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                  if (_sizes.length > 1) ...[
                                    const SizedBox(width: 4),
                                    removeButton,
                                  ],
                                ],
                              ),
                            ],
                          ),
                        );
                      }

                      return Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: TextFormField(
                              initialValue: s.label,
                              onChanged: (v) => s.label = v,
                              decoration: _inputDecoration('Label (e.g. Half)'),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              initialValue: s.price,
                              onChanged: (v) => s.price = v,
                              keyboardType: TextInputType.number,
                              decoration: _inputDecoration('Rs.'),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              initialValue: s.originalPrice,
                              onChanged: (v) => s.originalPrice = v,
                              keyboardType: TextInputType.number,
                              decoration: _inputDecoration('Orig. Rs.'),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          if (_sizes.length > 1) ...[
                            const SizedBox(width: 2),
                            removeButton,
                          ],
                        ],
                      );
                    },
                  ),
                );
              }),
            ],
            const SizedBox(height: 30),
            SizedBox(
              height: 54,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 3,
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 24, height: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : Text(isEdit ? 'Save Changes' : 'Add Product',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(fontSize: 14),
      decoration: _inputDecoration(label),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
      filled: true,
      fillColor: const Color(0xFFF9F9F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.grey[200]!)),
      focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: Color(0xFFFF6B00), width: 1.5)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.red)),
    );
  }
}

// --- Global Product Search Sheet ---------------------------------------------

class _GlobalProductSearchSheet extends StatefulWidget {
  const _GlobalProductSearchSheet();

  @override
  State<_GlobalProductSearchSheet> createState() => _GlobalProductSearchSheetState();
}

class _GlobalProductSearchSheetState extends State<_GlobalProductSearchSheet> {
  static const Color _primary = Color(0xFFFF6B00);
  final TextEditingController _searchCtrl = TextEditingController();
  
  bool _isLoading = true;
  List<Map<String, dynamic>> _allProducts = [];
  List<Map<String, dynamic>> _filteredProducts = [];

  @override
  void initState() {
    super.initState();
    _loadAllProducts();
    _searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAllProducts() async {
    try {
      await CityScopeService.ensureLoaded();
      final shopsRef = FirebaseDatabase.instance.ref(CityScopeService.tenantPath('shops'));
      final snap = await shopsRef.get();
      
      final Map<String, Map<String, dynamic>> uniqueProducts = {};

      if (snap.exists && snap.value is Map) {
        final shops = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final shopEntry in shops.entries) {
          if (shopEntry.value is! Map) continue;
          final shopData = Map<dynamic, dynamic>.from(shopEntry.value as Map);
          
          if (shopData.containsKey('menu') && shopData['menu'] is Map) {
            final menu = Map<dynamic, dynamic>.from(shopData['menu'] as Map);
            for (final prodEntry in menu.entries) {
              if (prodEntry.value is! Map) continue;
              final prod = Map<String, dynamic>.from(prodEntry.value as Map);
              prod['id'] = prodEntry.key;
              
              final name = (prod['name'] ?? '').toString().trim();
              if (name.isNotEmpty) {
                final key = name.toLowerCase();
                // Deduplicate by name. Only add if not exists, or if the new one has an image but the old doesn't.
                if (!uniqueProducts.containsKey(key)) {
                  uniqueProducts[key] = prod;
                } else {
                  final existingImage = _resolveProductImage(uniqueProducts[key]!);
                  final newImage = _resolveProductImage(prod);
                  if (existingImage.isEmpty && newImage.isNotEmpty) {
                    uniqueProducts[key] = prod;
                  }
                }
              }
            }
          }
        }
      }

      _allProducts = uniqueProducts.values.toList();
      _allProducts.sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
      _filteredProducts = List.from(_allProducts);
    } catch (e) {
      debugPrint('Error loading global products: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSearch() {
    final query = _searchCtrl.text.toLowerCase();
    setState(() {
      _filteredProducts = _allProducts.where((p) {
        final name = (p['name'] ?? '').toString().toLowerCase();
        final cat = (p['category'] ?? '').toString().toLowerCase();
        return name.contains(query) || cat.contains(query);
      }).toList();
    });
  }

  String _resolveProductImage(Map<String, dynamic> product) {
    const keys = <String>[
      'imageUrl', 'image', 'photo', 'photoUrl', 'photoURL',
      'thumbnail', 'thumbnailUrl', 'secure_url', 'productImage', 'url',
    ];
    for (final key in keys) {
      final value = ImageHelper.getDirectImageUrl((product[key] ?? '').toString());
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Import Product',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      Text('Search and copy details from existing products',
                          style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                  style: IconButton.styleFrom(backgroundColor: Colors.grey[100]),
                ),
              ],
            ),
          ),
          
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by name or category...',
                hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded, color: _primary),
                filled: true,
                fillColor: const Color(0xFFF9F9F9),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.grey[200]!)),
              ),
            ),
          ),

          // List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: _primary))
                : _filteredProducts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.search_off_rounded, size: 64, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('No products found',
                                style: TextStyle(color: Colors.grey[500], fontSize: 16, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: _filteredProducts.length,
                        separatorBuilder: (context, index) => Divider(color: Colors.grey[100]),
                        itemBuilder: (context, index) {
                          final product = _filteredProducts[index];
                          final imageUrl = _resolveProductImage(product);
                          final name = (product['name'] ?? '').toString();
                          final category = (product['category'] ?? '').toString();
                          final price = (product['price'] ?? '0').toString();
                          final hasSizes = product['hasSizes'] == true;

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: imageUrl.isNotEmpty
                                  ? ImageHelper.networkImage(url: imageUrl, width: 50, height: 50)
                                  : Container(
                                      width: 50,
                                      height: 50,
                                      color: const Color(0xFFFFF3E8),
                                      child: const Icon(Icons.fastfood_rounded, color: _primary, size: 24),
                                    ),
                            ),
                            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(
                              category.isNotEmpty ? category : 'No category',
                              style: TextStyle(color: Colors.grey[600], fontSize: 12),
                            ),
                            trailing: Text(
                              hasSizes ? 'Multiple sizes' : 'Rs. $price',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                            onTap: () {
                              Navigator.pop(context, product);
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}