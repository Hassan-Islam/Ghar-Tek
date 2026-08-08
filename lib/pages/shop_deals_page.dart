import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/category_timing_service.dart';
import '../services/city_scope_service.dart';

import '../services/cart_service.dart';
import '../services/image_helper.dart';
import '../widgets/product_detail_bottom_sheet.dart';
import 'cart_page.dart';

class ShopDealsPage extends StatefulWidget {
  final Map<String, dynamic> shop;

  const ShopDealsPage({super.key, required this.shop});

  @override
  State<ShopDealsPage> createState() => _ShopDealsPageState();
}

class _ShopDealsPageState extends State<ShopDealsPage> {
  static const Color _primary = Color(0xFFFF6B00);

  final _db = FirebaseDatabase.instance.ref();
  final CartService _cartService = CartService();
  final TextEditingController _searchCtrl = TextEditingController();

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  List<Map<String, dynamic>> _deals = [];
  List<Map<String, dynamic>> _filteredDeals = [];
  Map<String, Map<String, dynamic>> _categorySchedules = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cartService.addListener(_onCartChanged);
    _searchCtrl.addListener(_applyFilter);
    _loadDeals();
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cartService.removeListener(_onCartChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDeals() async {
    setState(() => _loading = true);
    try {
      await CityScopeService.ensureLoaded();
      final snap = await _db.child(_tenantPath('shops')).child(widget.shop['id']).child('menu').get();
      final categoryScheduleSnap = await _db
          .child(_tenantPath('shops'))
          .child(widget.shop['id'])
          .child('categorySchedules')
          .get();
      final deals = <Map<String, dynamic>>[];
      final categorySchedules = _parseCategorySchedules(categoryScheduleSnap.value);

      if (snap.exists && snap.value is Map) {
        final menu = Map<dynamic, dynamic>.from(snap.value as Map);
        menu.forEach((key, value) {
          if (value is Map) {
            final item = Map<String, dynamic>.from(value);
            item['id'] = key;
            item['shopId'] = widget.shop['id'];
            item['shopName'] = widget.shop['name'] ?? 'Shop';

            final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
            final originalPrice = double.tryParse(item['originalPrice']?.toString() ?? '0') ?? 0;
            final scheduleEnabled = item['dealScheduleEnabled'] == true;
            final now = DateTime.now().millisecondsSinceEpoch;
            final startAt = int.tryParse((item['dealStartAt'] ?? '0').toString()) ?? 0;
            final endAt = int.tryParse((item['dealEndAt'] ?? '0').toString()) ?? 0;
            final inWindow = !scheduleEnabled || startAt <= 0 || endAt <= 0 || (now >= startAt && now <= endAt);

            final categoryOpen = CategoryTimingService.isCategoryAvailable(
              schedules: categorySchedules,
              category: item['category'] ?? item['type'],
            );
            item['__categoryTimedOut'] = !categoryOpen;

            if (originalPrice > 0 && originalPrice > price && inWindow) {
              deals.add(item);
            }
          }
        });
      }

      deals.sort((a, b) {
        final pa = double.tryParse(a['price']?.toString() ?? '0') ?? 0;
        final oa = double.tryParse(a['originalPrice']?.toString() ?? '0') ?? 0;
        final pb = double.tryParse(b['price']?.toString() ?? '0') ?? 0;
        final ob = double.tryParse(b['originalPrice']?.toString() ?? '0') ?? 0;
        final da = oa > 0 ? ((oa - pa) / oa) : 0;
        final db = ob > 0 ? ((ob - pb) / ob) : 0;
        return db.compareTo(da);
      });

      if (!mounted) return;
      setState(() {
        _deals = deals;
        _filteredDeals = deals;
        _categorySchedules = categorySchedules;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, Map<String, dynamic>> _parseCategorySchedules(dynamic raw) {
    final parsed = <String, Map<String, dynamic>>{};
    if (raw is! Map) return parsed;

    final map = Map<dynamic, dynamic>.from(raw);
    map.forEach((key, value) {
      if (value is! Map) return;
      final schedule = Map<String, dynamic>.from(value);
      final normalizedKey = CategoryTimingService.normalizeCategory(
        schedule['category'] ?? key,
      );
      if (normalizedKey.isEmpty) return;
      parsed[normalizedKey] = schedule;
    });

    return parsed;
  }

  Map<String, dynamic>? _categoryScheduleForItem(Map<String, dynamic> item) {
    final key =
        CategoryTimingService.normalizeCategory(item['category'] ?? item['type']);
    if (key.isEmpty) return null;
    return _categorySchedules[key];
  }

  bool _isItemUnavailable(Map<String, dynamic> item) {
    final manualOut = item['outOfStock'] == true;
    final manuallyUnavailable = item['isAvailable'] == false || item['available'] == false;
    final categoryOpen = CategoryTimingService.isCategoryAvailable(
      schedules: _categorySchedules,
      category: item['category'] ?? item['type'],
    );
    return manualOut || manuallyUnavailable || !categoryOpen;
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filteredDeals = _deals.where((item) {
        if (query.isEmpty) return true;
        final name = (item['name'] ?? '').toString().toLowerCase();
        final desc = (item['description'] ?? '').toString().toLowerCase();
        return name.contains(query) || desc.contains(query);
      }).toList();
    });
  }

  String _resolveImageValue(dynamic raw) {
    if (raw == null) return '';
    return ImageHelper.getDirectImageUrl(raw.toString());
  }

  String _resolveDealImage(Map<String, dynamic> item) {
    const keys = <String>[
      'imageUrl',
      'image',
      'imageURL',
      'image_url',
      'photo',
      'photoUrl',
      'thumbnail',
      'thumbnailUrl',
      'secure_url',
      'url',
    ];
    for (final key in keys) {
      final value = _resolveImageValue(item[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<void> _openProduct(Map<String, dynamic> item) async {
    if (_isItemUnavailable(item)) {
      final schedule = _categoryScheduleForItem(item);
      final categoryName =
          (item['category'] ?? item['type'] ?? 'This category').toString();
      final openTime = (schedule?['openTime'] ?? '').toString();
      final closeTime = (schedule?['closeTime'] ?? '').toString();
      final timing = openTime.isNotEmpty && closeTime.isNotEmpty
          ? 'Available from $openTime to $closeTime.'
          : 'Please try again later.';

      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('$categoryName is out of stock right now. $timing'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      return;
    }

    final cartId = CartService.defaultCartItemId(item);
    final currentQty = _cartService.getItemQuantity(cartId);

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProductDetailBottomSheet(
        product: item,
        currentQuantity: currentQty,
      ),
    );

    if (result == null) return;

    final quantity = result['quantity'] as int? ?? 1;
    final variantId = result['variantId'] as String?;
    final size = result['size'] as String?;
    final price = result['price'] as double? ??
        (double.tryParse(item['price']?.toString() ?? '0') ?? 0.0);

    final resolvedCartId = CartService.resolveCartItemId(
      item,
      variantId: variantId,
      size: size,
    );

    final imageUrl = _resolveDealImage(item);
    final itemName = (item['name'] ?? 'Item').toString();
    final itemNameWithSize = size == null ? itemName : '$itemName ($size)';
    // Normal browsing always uses the standard cart (instant cart is only for
    // the dedicated Instant Delivery page).
    const scope = CartScope.standard;
    final added = _cartService.upsertItem(
      CartItem(
        id: resolvedCartId,
        name: itemNameWithSize,
        shopName: (item['shopName'] ?? widget.shop['name'] ?? '').toString(),
        shopId: (item['shopId'] ?? widget.shop['id'] ?? '').toString(),
        category: (item['category'] ?? item['type'] ?? '').toString(),
        price: price,
        imageUrl: imageUrl,
        extraChargeType:
            (item['extraChargeType'] ?? item['platformFeeType'] ?? 'none')
                .toString(),
        extraChargeValue: double.tryParse(
                (item['extraChargeValue'] ?? item['platformFeeValue'] ?? 0)
                    .toString()) ??
            0.0,
        quantity: quantity,
      ),
      scope: scope,
    );

    if (!added) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$quantity × $itemName added to cart'),
          backgroundColor: _primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFBF7),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF1A1A1A),
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  title: Text('${widget.shop['name'] ?? 'Shop'} Deals',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  actions: [
                    IconButton(
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.shopping_cart_outlined),
                          if (_cartService.itemCount > 0)
                            Positioned(
                              right: -5,
                              top: -5,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${_cartService.itemCount}',
                                  style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.w800),
                                ),
                              ),
                            ),
                        ],
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CartPage()),
                      ),
                    ),
                  ],
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search deals...',
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: _primary),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_filteredDeals.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text('No deals available right now',
                          style: TextStyle(fontSize: 14, color: Colors.grey)),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: _filteredDeals.length,
                    itemBuilder: (context, index) {
                      final item = _filteredDeals[index];
                      final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
                      final original = double.tryParse(item['originalPrice']?.toString() ?? '0') ?? 0;
                      final discount = original > 0 ? (((original - price) / original) * 100).round() : 0;
                      final image = (item['imageUrl'] ?? item['image'] ?? '').toString();
                      final unavailable = _isItemUnavailable(item);

                      return GestureDetector(
                        onTap: unavailable ? null : () => _openProduct(item),
                        child: Opacity(
                          opacity: unavailable ? 0.55 : 1.0,
                          child: Container(
                          margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3)),
                            ],
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 72,
                                  height: 72,
                                  child: image.isNotEmpty
                                      ? ImageHelper.networkImage(url: image, fit: BoxFit.cover)
                                      : Container(
                                          color: const Color(0xFFFFF3E8),
                                          child: const Icon(Icons.local_offer_rounded, color: _primary),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item['name'] ?? 'Deal Item',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Text('Rs. ${price.toStringAsFixed(0)}',
                                            style: const TextStyle(
                                                color: _primary, fontWeight: FontWeight.w900, fontSize: 15)),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Rs. ${original.toStringAsFixed(0)}',
                                          style: TextStyle(
                                            color: Colors.grey.shade700,
                                            decoration: TextDecoration.lineThrough,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: unavailable
                                      ? const Color(0xFFFFF1F1)
                                      : const Color(0xFFE8F9EF),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  unavailable ? 'OUT' : '$discount% OFF',
                                  style: TextStyle(
                                    color: unavailable
                                        ? const Color(0xFFC0392B)
                                        : const Color(0xFF12885B),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        ),
                      );
                    },
                  ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
              ],
            ),
    );
  }
}
