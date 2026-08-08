import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import '../services/image_helper.dart';
import '../widgets/product_detail_bottom_sheet.dart';

class CategoryProductsPage extends StatefulWidget {
  final String categoryName;

  const CategoryProductsPage({super.key, required this.categoryName});

  @override
  State<CategoryProductsPage> createState() => _CategoryProductsPageState();
}

class _CategoryProductsPageState extends State<CategoryProductsPage> {
  static const Color _primary = Color(0xFFFF6B00);
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  
  bool _isLoading = true;
  List<Map<String, dynamic>> _products = [];
  Map<String, Map<String, dynamic>> _shopsCache = {};

  @override
  void initState() {
    super.initState();
    _loadCategoryProducts();
  }

  Future<void> _loadCategoryProducts() async {
    try {
      await CityScopeService.ensureLoaded();
      final targetCity = CityScopeService.normalizeCity(CityScopeService.currentCity);
      final tenantPath = CityScopeService.tenantPath('shops');
      
      final snap = await _database.child(tenantPath).get();
      if (!snap.exists || snap.value == null) {
        setState(() => _isLoading = false);
        return;
      }

      final shopsData = Map<dynamic, dynamic>.from(snap.value as Map);
      List<Map<String, dynamic>> items = [];
      Map<String, Map<String, dynamic>> shopsCache = {};

      shopsData.forEach((shopId, shopValue) {
        if (shopValue is Map) {
          final shop = Map<String, dynamic>.from(shopValue);
          shop['id'] = shopId.toString();
          
          if (shop['isVisible'] == false) return; // Skip hidden shops

          shopsCache[shopId.toString()] = shop;

          if (shop.containsKey('menu') && shop['menu'] is Map) {
            final menu = Map<dynamic, dynamic>.from(shop['menu']);
            menu.forEach((itemId, itemValue) {
              if (itemValue is Map) {
                final item = Map<String, dynamic>.from(itemValue);
                item['id'] = itemId.toString();
                item['shopId'] = shopId.toString();
                item['shopName'] = shop['name'] ?? 'Unknown Shop';

                final itemCategory = (item['category'] ?? '').toString().toLowerCase();
                if (itemCategory == widget.categoryName.toLowerCase()) {
                  items.add(item);
                }
              }
            });
          }
        }
      });

      setState(() {
        _products = items;
        _shopsCache = shopsCache;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading category products: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openProduct(Map<String, dynamic> product) {
    final shopId = product['shopId']?.toString();
    if (shopId == null) return;
    
    final shop = _shopsCache[shopId];
    if (shop == null) return;

    final productWithShop = Map<String, dynamic>.from(product);
    productWithShop['shop'] = shop;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ProductDetailBottomSheet(
        product: productWithShop,
      ),
    );
  }

  Widget _buildProductCard(Map<String, dynamic> product) {
    final name = (product['name'] ?? '').toString();
    final shopName = (product['shopName'] ?? '').toString();
    final price = (product['price'] ?? '0').toString();
    final imageUrl = ImageHelper.getDirectImageUrl((product['imageUrl'] ?? product['image'] ?? '').toString());
    final hasSizes = product['hasSizes'] == true;
    final originalPrice = (product['originalPrice'] ?? '').toString();
    
    final shopId = product['shopId']?.toString();
    final shop = shopId != null ? _shopsCache[shopId] : null;
    final bool shopOpen = shop == null || (shop['isOpen'] != false && shop['status'] != 'closed');
    final bool isProductAvailable = product['available'] != false;
    final bool canOrder = shopOpen && isProductAvailable;

    return GestureDetector(
      onTap: () => _openProduct(product),
      child: Container(
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
            // Image
            Expanded(
              flex: 5,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
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
                            child: const Icon(Icons.fastfood_rounded, color: _primary, size: 32),
                          ),
                    if (!shopOpen)
                      ClipRect(
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
                  ],
                ),
              ),
            ),
            // Info
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
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
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (hasSizes)
                          const Text(
                            'Multiple sizes',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: _primary),
                          )
                        else ...[
                          Text(
                            'Rs. $price',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _primary),
                          ),
                          if (originalPrice.isNotEmpty && originalPrice != '0') ...[
                            const SizedBox(width: 4),
                            Text(
                              'Rs. $originalPrice',
                              style: TextStyle(
                                decoration: TextDecoration.lineThrough,
                                color: Colors.grey[400],
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                    if (!canOrder) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(widget.categoryName, style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
        backgroundColor: _primary,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : _products.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.fastfood_outlined, size: 64, color: Colors.grey[300]),
                      const SizedBox(height: 16),
                      Text(
                        'No items found for "${widget.categoryName}"',
                        style: TextStyle(fontSize: 16, color: Colors.grey[500], fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.75,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                  ),
                  itemCount: _products.length,
                  itemBuilder: (context, index) {
                    return _buildProductCard(_products[index]);
                  },
                ),
    );
  }
}
