import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/cart_service.dart';
import '../services/city_scope_service.dart';
import '../services/image_helper.dart';
import '../widgets/animations.dart';
import '../widgets/product_detail_bottom_sheet.dart';
import 'cart_page.dart';

class ShopMenuPage extends StatefulWidget {
  final Map<String, dynamic> shop;
  const ShopMenuPage({super.key, required this.shop});

  @override
  State<ShopMenuPage> createState() => _ShopMenuPageState();
}

class _ShopMenuPageState extends State<ShopMenuPage> {
  // Theme constants based on HTML design
  static const Color _primary = Color(0xFFFF6B00);
  static const Color _bg = Color(0xFFF7F7F7);
  static const Color _surface = Colors.white;

  final CartService _cartService = CartService();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _menuItems = [];
  List<String> _categories = [];
  String _selectedCategory = 'All';
  String _searchQuery = '';
  bool _isFavorite = false;
  bool _isMenuLoading = true;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    try {
      _cartService.addListener(_onCartChanged);
      _loadMenu();
      _checkFavoriteStatus();
    } catch (e) {
      debugPrint('ShopMenuPage initState error: $e');
    }
  }

  Future<void> _loadMenu() async {
    setState(() => _isMenuLoading = true);
    try {
      await CityScopeService.ensureLoaded();
      final shopId = widget.shop['id']?.toString() ?? '';
      if (shopId.isEmpty) {
        _parseShopData(widget.shop['menu']);
        return;
      }

      final menuSnap = await FirebaseDatabase.instance
          .ref(_tenantPath('shops/$shopId/menu'))
          .get();
      if (menuSnap.exists) {
        _parseShopData(menuSnap.value);
        return;
      }

      final legacySnap = await FirebaseDatabase.instance
          .ref(_tenantPath('shops/$shopId/products'))
          .get();
      if (legacySnap.exists) {
        _parseShopData(legacySnap.value);
        return;
      }

      _parseShopData(widget.shop['menu']);
    } catch (e) {
      debugPrint('ShopMenuPage _loadMenu error: $e');
      _parseShopData(widget.shop['menu']);
    } finally {
      if (mounted) setState(() => _isMenuLoading = false);
    }
  }

  Future<void> _checkFavoriteStatus() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final shopId = widget.shop['id'];
        if (shopId != null && shopId.toString().isNotEmpty) {
          final ref = FirebaseDatabase.instance.ref('users/${user.uid}/favorites/$shopId');
          final snapshot = await ref.get();
          if (snapshot.exists && mounted) {
            setState(() {
              _isFavorite = snapshot.value == true;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error checking favorite status: $e');
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please login to add favorites')));
        return;
      }
      final shopId = widget.shop['id'];
      if (shopId != null && shopId.toString().isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('users/${user.uid}/favorites/$shopId');
        final newStatus = !_isFavorite;
        setState(() {
          _isFavorite = newStatus;
        });
        await ref.set(newStatus);
      }
    } catch (e) {
      debugPrint('Error toggling favorite: $e');
    }
  }

  @override
  void dispose() {
    _cartService.removeListener(_onCartChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  void _parseShopData(dynamic rawMenu) {
    _menuItems = [];
    _categories = ['All'];
    if (rawMenu is Map) {
      final List<Map<String, dynamic>> items = [];
      final Set<String> cats = {'All'};

      rawMenu.forEach((key, val) {
        if (val is Map) {
          final item = Map<String, dynamic>.from(val);
          item['id'] = key;
          item['shopId'] = widget.shop['id'];
          item['shopName'] = widget.shop['name'] ?? 'Unknown Shop';
          item['shopCategory'] = widget.shop['category'] ?? 'Other';
          item['imageUrl'] = _resolveImageFromMap(item);
          items.add(item);
          
          final cat = (item['category'] ?? 'Other').toString();
          cats.add(cat);
        }
      });

      _menuItems = items;
      _categories = cats.toList();
    } else if (rawMenu is List) {
      final List<Map<String, dynamic>> items = [];
      final Set<String> cats = {'All'};

      for (int i = 0; i < rawMenu.length; i++) {
        final val = rawMenu[i];
        if (val is Map) {
          final item = Map<String, dynamic>.from(val);
          item['id'] = item['id']?.toString() ?? 'item_$i';
          item['shopId'] = widget.shop['id'];
          item['shopName'] = widget.shop['name'] ?? 'Unknown Shop';
          item['shopCategory'] = widget.shop['category'] ?? 'Other';
          item['imageUrl'] = _resolveImageFromMap(item);
          items.add(item);
          
          final cat = (item['category'] ?? 'Other').toString();
          cats.add(cat);
        }
      }
      _menuItems = items;
      _categories = cats.toList();
    }
  }

  String _resolveImageFromMap(Map<String, dynamic> data) {
    if (data.containsKey('imageUrl') && data['imageUrl'] != null) {
      return data['imageUrl'].toString();
    }
    if (data.containsKey('image') && data['image'] != null) {
      return data['image'].toString();
    }
    return '';
  }

  double _parsePrice(dynamic val) {
    if (val == null) return 0;
    return double.tryParse(val.toString()) ?? 0;
  }

  // Check if shop is open based on status flag or timing (assuming open if no explicit close)
  bool _isShopOpen() {
    final status = (widget.shop['status'] ?? 'open').toString().toLowerCase();
    return status != 'closed' && status != 'inactive';
  }

  List<Map<String, dynamic>> get _filteredItems {
    return _menuItems.where((item) {
      final matchesSearch = _searchQuery.isEmpty ||
          (item['name'] ?? '').toString().toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesCat = _selectedCategory == 'All' ||
          (item['category'] ?? 'Other').toString() == _selectedCategory;
      return matchesSearch && matchesCat;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    try {
      final filtered = _filteredItems;
      final shopOpen = _isShopOpen();

      if (_isMenuLoading) {
        return const Scaffold(
          backgroundColor: _bg,
          body: Center(
            child: CircularProgressIndicator(color: _primary),
          ),
        );
      }

      return Scaffold(
        backgroundColor: _bg,
        body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildTopSpacing()),
              SliverToBoxAdapter(child: _buildTopBar()),
              SliverToBoxAdapter(child: _buildShopInfoCard(shopOpen)),
              SliverToBoxAdapter(child: _buildSearchBar()),
              SliverToBoxAdapter(child: _buildCategoryChips()),
              
              if (_selectedCategory != 'All')
                 SliverToBoxAdapter(
                   child: Padding(
                     padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                     child: Text(
                       _selectedCategory,
                       style: const TextStyle(
                         fontSize: 15.5,
                         fontWeight: FontWeight.w700,
                         color: Color(0xFF222222),
                       ),
                     ),
                   ),
                 ),

              if (filtered.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Center(
                      child: Text(
                        'No items found',
                        style: TextStyle(color: Colors.grey[500]),
                      ),
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = filtered[index];
                      // Group logic if 'All' is selected could be added here, 
                      // but for simplicity matching the HTML, we'll just show the section title if it's the first of its category.
                      bool showCatTitle = false;
                      if (_selectedCategory == 'All') {
                        if (index == 0) {
                          showCatTitle = true;
                        } else {
                          final prevItem = filtered[index - 1];
                          if ((item['category'] ?? 'Other') != (prevItem['category'] ?? 'Other')) {
                            showCatTitle = true;
                          }
                        }
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showCatTitle)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                              child: Text(
                                (item['category'] ?? 'Other').toString(),
                                style: const TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF222222),
                                ),
                              ),
                            ),
                          _buildItemCard(item, shopOpen),
                        ],
                      ).animateListItem(index: index);
                    },
                    childCount: filtered.length,
                  ),
                ),
                
              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          ),
          
          if (_cartService.itemCount > 0)
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 14,
              child: _buildFloatingCartBar(),
            ),
        ],
      ),
    );
    } catch (e, stack) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error Loading Menu')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $e\n\n$stack', style: const TextStyle(color: Colors.red)),
        ),
      );
    }
  }

  Widget _buildTopSpacing() {
    return SizedBox(height: MediaQuery.of(context).padding.top);
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ScaleTap(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Color(0xFFF2F2F2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.arrow_back, size: 18, color: Color(0xFF333333)),
            ),
          ),
          ScaleTap(
            onTap: _toggleFavorite,
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Color(0xFFF2F2F2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isFavorite ? Icons.favorite : Icons.favorite_border,
                size: 16,
                color: _isFavorite ? Colors.red : const Color(0xFF333333),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShopInfoCard(bool shopOpen) {
    final imageUrl = _resolveImageFromMap(widget.shop);
    final rating = double.tryParse((widget.shop['rating'] ?? 0).toString()) ?? 0;
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000), // Very soft shadow
            blurRadius: 24,
            offset: Offset(0, 8),
          )
        ],
      ),
      child: Row(
        children: [
              if (imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ImageHelper.networkImage(
                    url: imageUrl,
                    width: 88,
                    height: 88,
                    fit: BoxFit.cover,
                    placeholder: _buildPlaceholder(88),
                    errorWidget: _buildPlaceholder(88),
                  ),
                )
              else
                _buildPlaceholder(88),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        widget.shop['name']?.toString() ?? 'Shop',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF222222),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: shopOpen ? Colors.green : Colors.red,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        shopOpen ? 'Open' : 'Closed',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  widget.shop['category']?.toString() ?? 'Various items',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF888888),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (rating > 0) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF7EE),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.star, size: 10, color: Color(0xFF1E9E4B)),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Color(0xFF1E9E4B),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Row(
                      children: [
                        const Icon(Icons.access_time_filled, size: 10, color: Color(0xFF909090)),
                        const SizedBox(width: 3),
                        Text(
                          widget.shop['deliveryTime']?.toString() ?? '30-45 min',
                          style: const TextStyle(
                            color: Color(0xFF909090),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (double.tryParse(widget.shop['deliveryFeeStandard']?.toString() ?? '') != null) ...[
                      const SizedBox(width: 8),
                      Row(
                        children: [
                          const Icon(Icons.moped, size: 10, color: Color(0xFF909090)),
                          const SizedBox(width: 3),
                          Text(
                            'Rs. ${double.tryParse(widget.shop['deliveryFeeStandard']?.toString() ?? '')!.toStringAsFixed(0)}',
                            style: const TextStyle(
                              color: Color(0xFF909090),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildPlaceholder(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFEEEEEE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: const Icon(Icons.storefront, color: Colors.grey),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300, width: 1.5),
        ),
        child: TextField(
          textAlignVertical: TextAlignVertical.center,
          controller: _searchController,
          onChanged: (val) {
            setState(() {
              _searchQuery = val;
            });
          },
          style: const TextStyle(fontSize: 13.5, color: Color(0xFF333333)),
          decoration: const InputDecoration(
            hintText: 'Search in menu',
            hintStyle: TextStyle(color: Color(0xFF999999)),
            prefixIcon: Icon(Icons.search, size: 18, color: Color(0xFF999999)),
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryChips() {
    return SizedBox(
      height: 38, // Adjusted height
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = _categories[index];
          final isActive = cat == _selectedCategory;
          
          return ScaleTap(
            onTap: () {
              setState(() => _selectedCategory = cat);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? _primary : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                cat,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                  color: isActive ? Colors.white : const Color(0xFF888888),
                ),
              ),
            ),
          ).animateHorizontalItem(index: index);
        },
      ),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item, bool shopOpen) {
    final imgUrl = _resolveImageFromMap(item);
    final price = _parsePrice(item['price']);
    final oldPrice = _parsePrice(item['originalPrice']);
    
    // Attempt to get product specific rating/time if exists, else fallback to 4.5
    final rating = double.tryParse((item['rating'] ?? 4.5).toString()) ?? 4.5;
    
    final inCartQty = _cartService.getItemQuantity(item['id'].toString());
    final isProductAvailable = item['available'] != false;
    final canOrder = shopOpen && isProductAvailable;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      margin: const EdgeInsets.only(bottom: 2),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                imgUrl.isNotEmpty
                    ? ImageHelper.networkImage(
                        url: imgUrl,
                        width: 78,
                        height: 78,
                        fit: BoxFit.cover,
                        placeholder: _buildItemPlaceholder(),
                        errorWidget: _buildItemPlaceholder(),
                      )
                    : _buildItemPlaceholder(),
                if (!shopOpen)
                  Positioned.fill(
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 3.0, sigmaY: 3.0),
                        child: Container(
                          color: Colors.black.withOpacity(0.3),
                          alignment: Alignment.center,
                          child: const Text(
                            'Shop is Closed',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['name'] ?? 'Item',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF222222),
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    if (rating > 0) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF7EE),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.star, size: 10, color: Color(0xFF1E9E4B)),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Color(0xFF1E9E4B),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // Assuming time can be pulled from shop if not on item
                    Row(
                      children: [
                        const Icon(Icons.access_time_filled, size: 10, color: Color(0xFF909090)),
                        const SizedBox(width: 3),
                        Text(
                          item['deliveryTime']?.toString() ?? widget.shop['deliveryTime']?.toString() ?? '30-45 min',
                          style: const TextStyle(
                            color: Color(0xFF909090),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Rs. ${price.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _primary,
                      ),
                    ),
                    if (oldPrice > 0 && oldPrice > price) ...[
                      const SizedBox(width: 6),
                      Text(
                        'Rs. ${oldPrice.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFAAAAAA),
                          decoration: TextDecoration.lineThrough,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (canOrder)
            inCartQty > 0
                ? _buildQtyStepper(item, inCartQty)
                : _buildAddBtn(item)
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                !shopOpen ? 'Closed' : 'Unavailable',
                style: const TextStyle(
                  color: Color(0xFF999999),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
  
  Widget _buildItemPlaceholder() {
    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        color: const Color(0xFFEEEEEE),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.fastfood, color: Colors.grey),
    );
  }

  /// True when a product offers half/full, sizes, or variants that the customer
  /// must choose before it can be added to the cart.
  bool _productNeedsSelection(Map<String, dynamic> item) {
    if (item['hasSizes'] == true) return true;
    final sizes = item['sizes'];
    if (sizes is List && sizes.isNotEmpty) return true;
    if (sizes is Map && sizes.isNotEmpty) return true;
    final variants = item['variants'];
    if (variants is Map && variants.isNotEmpty) return true;
    final half = double.tryParse(item['halfPrice']?.toString() ?? '') ?? 0;
    final full = double.tryParse(item['fullPrice']?.toString() ?? '') ?? 0;
    return half > 0 || full > 0;
  }

  void _addItemToCart(Map<String, dynamic> item) {
    // Products with half/full, sizes, or variants must open the selection sheet
    // so the customer can pick an option before adding.
    if (_productNeedsSelection(item)) {
      _openProductSelection(item);
      return;
    }

    // Regular shop browsing always uses the standard (normal) cart, so users can
    // order anything normally. The dedicated Instant Delivery page is the only
    // place that adds to the instant cart.
    _cartService.addItem(
      CartItem(
        id: item['id'].toString(),
        name: item['name']?.toString() ?? 'Item',
        shopName: item['shopName']?.toString() ?? 'Shop',
        shopId: item['shopId']?.toString() ?? '',
        category: item['category']?.toString(),
        price: _parsePrice(item['price']),
        imageUrl: _resolveImageFromMap(item),
      ),
      scope: CartScope.standard,
    );
  }

  Future<void> _openProductSelection(Map<String, dynamic> item) async {
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

    if (result == null || !mounted) return;

    final quantity = result['quantity'] as int? ?? 1;
    final variantId = result['variantId'] as String?;
    final size = result['size'] as String?;
    final price = result['price'] as double? ?? _parsePrice(item['price']);

    final resolvedCartId = CartService.resolveCartItemId(
      item,
      variantId: variantId,
      size: size,
    );

    final itemName = (item['name'] ?? 'Item').toString();
    final itemNameWithSize = size == null ? itemName : '$itemName ($size)';

    _cartService.upsertItem(
      CartItem(
        id: resolvedCartId,
        name: itemNameWithSize,
        shopName: item['shopName']?.toString() ??
            widget.shop['name']?.toString() ??
            'Shop',
        shopId: item['shopId']?.toString() ??
            widget.shop['id']?.toString() ??
            '',
        category: item['category']?.toString(),
        price: price,
        imageUrl: _resolveImageFromMap(item),
        quantity: quantity,
      ),
      scope: CartScope.standard,
    );
  }

  Widget _buildAddBtn(Map<String, dynamic> item) {
    return ScaleTap(
      onTap: () => _addItemToCart(item),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF0E5), // Light orange background
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Text(
          'ADD',
          style: TextStyle(
            color: _primary,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildQtyStepper(Map<String, dynamic> item, int qty) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _primary,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33FF6B00), // Soft orange shadow
            blurRadius: 10,
            offset: Offset(0, 4),
          )
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTap(
            onTap: () {
              _cartService.decreaseQuantity(item['id'].toString());
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6.0),
              child: Text('−', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ),
          const SizedBox(width: 12),
          Text(qty.toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(width: 12),
          ScaleTap(
            onTap: () => _addItemToCart(item),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6.0),
              child: Text('+', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ),
        ],
      ),
    ).animate().scale(duration: 200.ms, curve: Curves.easeOutBack);
  }

  Widget _buildFloatingCartBar() {
    return ScaleTap(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const CartPage()));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: _primary,
          borderRadius: BorderRadius.circular(30), // Pill shape
          boxShadow: const [
            BoxShadow(
              color: Color(0x40FF6B00), // Softer glowing shadow
              blurRadius: 20,
              offset: Offset(0, 8),
            )
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    color: Color(0x40FFFFFF), // rgba(255,255,255,0.25)
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _cartService.itemCount.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'View Cart',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  'Rs. ${_cartService.subtotal.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward, color: Colors.white, size: 16),
              ],
            ),
          ],
        ),
      ).animate().slideY(begin: 1, duration: 400.ms, curve: Curves.easeOutBack),
    );
  }
}
