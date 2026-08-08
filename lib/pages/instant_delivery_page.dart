import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';

import '../services/analytics_service.dart';
import '../services/cart_service.dart';
import '../services/city_scope_service.dart';
import '../services/image_helper.dart';
import '../services/instant_delivery_service.dart';
import '../widgets/animations.dart';
import '../widgets/product_detail_bottom_sheet.dart';
import 'cart_page.dart';
import 'checkout_page.dart';

/// Instant Delivery page — Islamabad only.
class InstantDeliveryPage extends StatefulWidget {
  const InstantDeliveryPage({super.key});

  @override
  State<InstantDeliveryPage> createState() => _InstantDeliveryPageState();
}

class _InstantDeliveryPageState extends State<InstantDeliveryPage> {
  static const Color _primary = Color(0xFFFF6B00);
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final CartService _cartService = CartService();

  bool _isLoading = true;
  List<Map<String, dynamic>> _products = [];
  final Map<String, Map<String, dynamic>> _shopsCache = {};

  @override
  void initState() {
    super.initState();
    _cartService.addListener(_onCartChanged);
    unawaited(_cartService.loadFeeSettings());
    _loadInstantProducts();
  }

  @override
  void dispose() {
    _cartService.removeListener(_onCartChanged);
    super.dispose();
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  bool _isInstantItem(Map<String, dynamic> item) {
    return InstantDeliveryService.isInstantProduct(item);
  }

  Future<void> _loadInstantProducts() async {
    try {
      await CityScopeService.ensureLoaded();
      final tenantPath = CityScopeService.tenantPath('shops');

      final snap = await _database.child(tenantPath).get();
      if (!snap.exists || snap.value == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final shopsData = Map<dynamic, dynamic>.from(snap.value as Map);
      final items = <Map<String, dynamic>>[];
      _shopsCache.clear();

      shopsData.forEach((shopId, shopValue) {
        if (shopValue is! Map) return;
        final shop = Map<String, dynamic>.from(shopValue);
        shop['id'] = shopId.toString();
        if (shop['isVisible'] == false) return;

        _shopsCache[shopId.toString()] = shop;

        if (shop['menu'] is Map) {
          final menu = Map<dynamic, dynamic>.from(shop['menu']);
          menu.forEach((itemId, itemValue) {
            if (itemValue is! Map) return;
            final item = Map<String, dynamic>.from(itemValue);
            item['id'] = itemId.toString();
            item['shopId'] = shopId.toString();
            item['shopName'] = shop['name'] ?? 'Unknown Shop';
            if (_isInstantItem(item)) items.add(item);
          });
        }
      });

      if (!mounted) return;
      setState(() {
        _products = items;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading instant products: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openProduct(Map<String, dynamic> product) async {
    final shopId = product['shopId']?.toString();
    if (shopId == null) return;
    final shop = _shopsCache[shopId];
    if (shop == null) return;

    final productWithShop = Map<String, dynamic>.from(product);
    productWithShop['shop'] = shop;

    final cartId = CartService.defaultCartItemId(productWithShop);
    final currentQty = _cartService.getItemQuantity(
      cartId,
      scope: CartScope.instant,
    );

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ProductDetailBottomSheet(
        product: productWithShop,
        currentQuantity: currentQty,
      ),
    );

    if (result == null || !mounted) return;

    final quantity = result['quantity'] as int? ?? 1;
    final variantId = result['variantId'] as String?;
    final size = result['size'] as String?;
    final price = result['price'] as double? ??
        (double.tryParse(product['price']?.toString() ?? '0') ?? 0.0);

    final resolvedCartId = CartService.resolveCartItemId(
      productWithShop,
      variantId: variantId,
      size: size,
    );

    final imageUrl = ImageHelper.getDirectImageUrl(
      (product['imageUrl'] ?? product['image'] ?? '').toString(),
    );
    final itemName = (product['name'] ?? 'Item').toString();
    final itemNameWithSize = size == null ? itemName : '$itemName ($size)';

    _cartService.upsertItem(
      CartItem(
        id: resolvedCartId,
        name: itemNameWithSize,
        shopName: (product['shopName'] ?? shop['name'] ?? '').toString(),
        shopId: shopId,
        category: InstantDeliveryService.instantCategory,
        price: price,
        imageUrl: imageUrl,
        quantity: quantity,
      ),
      scope: CartScope.instant,
    );

    AnalyticsService.addToCart(
      product['id']?.toString() ?? '',
      itemName,
      price,
      shopId,
    );

    Fluttertoast.showToast(
      msg: '$quantity × $itemName ${InstantDeliveryService.addedToastSuffix}',
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.TOP,
      backgroundColor: _primary,
      textColor: Colors.white,
      fontSize: 13,
    );
  }

  Widget _buildPromiseBanner() {
    final deliveryFee = _cartService.instantDeliveryFeeBase;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF6B00), Color(0xFFFF9500)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6B00).withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      InstantDeliveryService.promiseTitle,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      InstantDeliveryService.promiseSubtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.delivery_dining_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    InstantDeliveryService.deliveryFeeLabel(deliveryFee),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product) {
    final name = (product['name'] ?? '').toString();
    final shopName = (product['shopName'] ?? '').toString();
    final priceInfo = InstantDeliveryService.resolveDisplayPrice(product);
    final imageUrl = ImageHelper.getDirectImageUrl(
      (product['imageUrl'] ?? product['image'] ?? '').toString(),
    );

    final shopId = product['shopId']?.toString();
    final shop = shopId != null ? _shopsCache[shopId] : null;
    final bool shopOpen =
        shop == null || (shop['isOpen'] != false && shop['status'] != 'closed');
    final bool isProductAvailable = product['available'] != false;
    final bool canOrder = shopOpen && isProductAvailable;

    return GestureDetector(
      onTap: () => _openProduct(product),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    imageUrl.isNotEmpty
                        ? ImageHelper.networkImage(
                            url: imageUrl,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: const Color(0xFFFFF3E8),
                            child: const Icon(
                              Icons.fastfood_rounded,
                              color: _primary,
                              size: 32,
                            ),
                          ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt_rounded,
                                color: Colors.white, size: 12),
                            SizedBox(width: 2),
                            Text(
                              InstantDeliveryService.badgeLabel,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!shopOpen)
                      ClipRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 3.0, sigmaY: 3.0),
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.3),
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
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    shopName,
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          priceInfo.displayLabel,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: priceInfo.hasPrice
                                ? _primary
                                : Colors.grey[600],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (priceInfo.originalPrice != null &&
                          priceInfo.originalPrice! > priceInfo.price) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Rs. ${priceInfo.originalPrice!.round()}',
                            style: TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: Colors.grey[400],
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (!canOrder) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F0F0),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        !shopOpen ? 'Closed' : 'Unavailable',
                        style: const TextStyle(
                          color: Color(0xFF999999),
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingOrderBar() {
    final subtotal = _cartService.subtotalFor(CartScope.instant);
    final deliveryFee = _cartService.deliveryFeeFor(CartScope.instant);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF3D00), Color(0xFFFF6B00)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6B00).withValues(alpha: 0.45),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: ScaleTap(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CartPage(scope: CartScope.instant),
                  ),
                );
              },
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${_cartService.itemCountFor(CartScope.instant)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          InstantDeliveryService.cartLabel,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          'Items Rs. ${subtotal.toStringAsFixed(0)} + Delivery Rs. ${deliveryFee.toStringAsFixed(0)}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontWeight: FontWeight.w600,
                            fontSize: 11.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          ScaleTap(
            onTap: () {
              Navigator.push(
                context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const CheckoutPage(cartScope: CartScope.instant),
                  ),
              );
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, color: Color(0xFFFF6B00), size: 16),
                  SizedBox(width: 4),
                  Text(
                    'Order Now',
                    style: TextStyle(
                      color: Color(0xFFFF6B00),
                      fontWeight: FontWeight.w900,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    )
        .animate()
        .slideY(
          begin: 1,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
        );
  }

  @override
  Widget build(BuildContext context) {
    final showInstantCart = _cartService.itemCountFor(CartScope.instant) > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: const Text(
          InstantDeliveryService.pageTitle,
          style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
        ),
        backgroundColor: _primary,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (showInstantCart)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                tooltip: 'Instant Cart',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                    builder: (_) => const CartPage(scope: CartScope.instant),
                  ),
                  );
                },
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.shopping_bag_outlined, color: Colors.white),
                    Positioned(
                      top: -4,
                      right: -6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${_cartService.itemCountFor(CartScope.instant)}',
                          style: const TextStyle(
                            color: Color(0xFFFF6B00),
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: CircularProgressIndicator(color: _primary))
              : RefreshIndicator(
                  color: _primary,
                  onRefresh: _loadInstantProducts,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(child: _buildPromiseBanner()),
                      if (_products.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.bolt_outlined,
                                  size: 64,
                                  color: Colors.grey[300],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No instant delivery items right now',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey[500],
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: 0.78,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) =>
                                  _buildProductCard(_products[index]),
                              childCount: _products.length,
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.only(
                          bottom: showInstantCart
                              ? MediaQuery.of(context).padding.bottom + 96
                              : 24,
                        ),
                      ),
                    ],
                  ),
                ),
          if (showInstantCart)
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 14,
              child: _buildFloatingOrderBar(),
            ),
        ],
      ),
    );
  }
}
