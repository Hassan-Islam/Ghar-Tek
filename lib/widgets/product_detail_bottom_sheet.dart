import 'package:flutter/material.dart';
import '../services/image_helper.dart';
import '../services/analytics_service.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'product_rating_dialog.dart';

// ─── Constants ──────────────────────────────────────────────────────────────────
const Color _kOrange = Color(0xFFE8431C);
const Color _kOrangeLight = Color(0xFFFFF0EB);
const Color _kCream = Color(0xFFFFF8F4);
const Color _kDark = Color(0xFF1A1A1A);
const Color _kGray = Color(0xFF8A8A8A);
const Color _kBorder = Color(0xFFF0E8E4);

/// ProductDetailBottomSheet — Food Delivery App
class ProductDetailBottomSheet extends StatefulWidget {
  final Map<String, dynamic> product;
  final int currentQuantity;

  const ProductDetailBottomSheet({
    super.key,
    required this.product,
    this.currentQuantity = 0,
  });

  @override
  State<ProductDetailBottomSheet> createState() =>
      _ProductDetailBottomSheetState();
}

class _ProductDetailBottomSheetState extends State<ProductDetailBottomSheet>
    with TickerProviderStateMixin {
  late int _quantity;
  String? _selectedVariantId;
  double _selectedPrice = 0;
  double _originalPrice = 0;
  int _selectedSizeIndex = -1; 
  List<Map<String, dynamic>> _parsedSizes = []; 
  bool _addedToCart = false;

  // Animations
  late AnimationController _fadeController;
  late AnimationController _cartBtnController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  late Animation<double> _cartBtnScale;

  @override
  void initState() {
    super.initState();
    _quantity = widget.currentQuantity > 0 ? widget.currentQuantity : 1;

    // ── Fade + Slide animation ──
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOutCubic));
    _fadeController.forward();

    // ── Cart button bounce ──
    _cartBtnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _cartBtnScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.95), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _cartBtnController, curve: Curves.easeInOut));

    _initPricing();

    final pId = widget.product['id']?.toString() ?? '';
    final pName = widget.product['name']?.toString() ?? 'Product';
    final sId = widget.product['shopId']?.toString() ?? '';
    AnalyticsService.productClick(pId, pName, sId);
    AnalyticsService.productView(pId, pName, sId);
  }

  void _initPricing() {
    final product = widget.product;
    final hasSizes = product['hasSizes'] == true;

    _parsedSizes = _extractSizes(product);

    if (hasSizes && _parsedSizes.isNotEmpty) {
      _selectedSizeIndex = 0;
      _selectedPrice = _toDouble(_parsedSizes[0]['price']);
      _originalPrice = _toDouble(_parsedSizes[0]['originalPrice']);
      return;
    }

    final halfPrice = _toDouble(product['halfPrice']);
    final fullPrice = _toDouble(product['fullPrice']);
    if (hasSizes && (halfPrice > 0 || fullPrice > 0)) {
      _parsedSizes = [
        if (halfPrice > 0)
          {'label': 'Half Plate', 'price': halfPrice, 'originalPrice': _toDouble(product['originalPrice'])},
        if (fullPrice > 0)
          {'label': 'Full Plate', 'price': fullPrice, 'originalPrice': 0.0},
      ];
      _selectedSizeIndex = 0;
      _selectedPrice = _parsedSizes[0]['price'] as double;
      _originalPrice = _toDouble(_parsedSizes[0]['originalPrice']);
      return;
    }

    final variants = product['variants'] as Map<dynamic, dynamic>?;
    if (variants != null && variants.isNotEmpty) {
      final firstKey = variants.keys.first.toString();
      _selectedVariantId = firstKey;
      final firstVariant = variants[variants.keys.first] as Map?;
      _selectedPrice = _toDouble(
        firstVariant?['price'] ?? firstVariant?['amount'] ?? product['price'],
      );
      _originalPrice = _toDouble(
        firstVariant?['originalPrice'] ?? firstVariant?['oldPrice'] ?? product['originalPrice'],
      );
      return;
    } else {
      _selectedPrice = _toDouble(product['price']);
    }
    _originalPrice = _toDouble(product['originalPrice']);
  }

  List<Map<String, dynamic>> _extractSizes(Map<String, dynamic> product) {
    final raw = product['sizes'];
    if (raw == null) return [];

    if (raw is List) {
      return raw
          .whereType<Map>()
          .map<Map<String, dynamic>>((s) => Map<String, dynamic>.from(s))
          .where((s) => (s['label'] ?? '').toString().isNotEmpty)
          .toList();
    }

    if (raw is Map) {
      final sorted = (raw).entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return sorted
          .where((e) => e.value is Map)
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e.value as Map))
          .where((s) => (s['label'] ?? '').toString().isNotEmpty)
          .toList();
    }

    return [];
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _cartBtnController.dispose();
    super.dispose();
  }

  double _toDouble(dynamic val) =>
      double.tryParse(val?.toString() ?? '') ?? 0.0;

  String _resolveSelectedProductImage(Map<String, dynamic> product) {
    if (_selectedVariantId != null) {
      final variants = product['variants'] as Map<dynamic, dynamic>?;
      final selected = variants?[_selectedVariantId];
      if (selected is Map) {
        final candidate = ImageHelper.getDirectImageUrl(
          (selected['imageUrl'] ??
                  selected['image'] ??
                  selected['photo'] ??
                  '')
              .toString(),
        );
        if (candidate.isNotEmpty) return candidate;
      }
    }

    final keys = ['imageUrl', 'image', 'photo', 'thumbnail', 'productImage'];
    for (final key in keys) {
      final candidate = ImageHelper.getDirectImageUrl((product[key] ?? '').toString());
      if (candidate.isNotEmpty) return candidate;
    }

    final images = product['images'];
    if (images is List && images.isNotEmpty) {
      final first = images.first;
      final candidate = ImageHelper.getDirectImageUrl(first.toString());
      if (candidate.isNotEmpty) return candidate;
    }

    return '';
  }

  int get _maxQty {
    final v = widget.product['maxQty'] ?? widget.product['maxQuantity'];
    return (v is int) ? v : (int.tryParse(v?.toString() ?? '') ?? 10);
  }

  void _increment() {
    if (_quantity < _maxQty) setState(() => _quantity++);
  }

  void _decrement() {
    if (_quantity > 1) setState(() => _quantity--);
  }

  double get _totalPrice => _selectedPrice * _quantity;

  int get _discountPercent {
    if (_originalPrice > 0 && _originalPrice > _selectedPrice) {
      return ((_originalPrice - _selectedPrice) / _originalPrice * 100).round();
    }
    return 0;
  }

  String? get _selectedSizeLabel {
    if (_selectedSizeIndex >= 0 && _selectedSizeIndex < _parsedSizes.length) {
      return (_parsedSizes[_selectedSizeIndex]['label'] ?? '').toString();
    }
    return null;
  }

  void _handleAddToCart() {
    _cartBtnController.forward(from: 0);
    setState(() => _addedToCart = true);

    Navigator.pop(context, {
      'quantity': _quantity,
      'variantId': _selectedVariantId,
      'price': _selectedPrice,
      'size': _selectedSizeLabel,
    });
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final imageUrl = _resolveSelectedProductImage(product);
    final isAssetImage = imageUrl.startsWith('assets/');
    final name = (product['name'] ?? 'Product') as String;
    final shopName = (product['shopName'] ?? '') as String;
    final description = (product['description'] ?? product['desc'] ?? '') as String;
    final rating = _toDouble(product['rating']);
    final category = (product['category'] ?? product['shopCategory'] ?? '') as String;
    final isHot = product['isHot'] == true ||
        product['hotItem'] == true ||
        (product['tag'] ?? '').toString().toLowerCase().contains('hot');
    final hasSizes = product['hasSizes'] == true;
    final variants = product['variants'] as Map<dynamic, dynamic>?;
    final hasVariants = variants != null && variants.isNotEmpty;

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(0.95),
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: _kCream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 6, bottom: 2),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
            ),
            Flexible(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: _buildHeroImage(imageUrl, isHot, isAssetImage),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: _kDark,
                                      height: 1.25,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (category.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _kOrangeLight,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      category,
                                      style: const TextStyle(
                                        color: _kOrange,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            if (shopName.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  const Text('📍 ',
                                      style: TextStyle(fontSize: 12)),
                                  Flexible(
                                    child: Text(
                                      shopName,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: _kGray,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (rating > 0) ...[
                              const SizedBox(height: 8),
                              _buildRatingRow(rating),
                            ],
                          ],
                        ),
                      ),
                      const _Divider(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Rs. ${_selectedPrice.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontSize: 23,
                                    fontWeight: FontWeight.w800,
                                    color: _kOrange,
                                  ),
                                ),
                                if (_originalPrice > 0 &&
                                    _originalPrice > _selectedPrice) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    'Rs. ${_originalPrice.toStringAsFixed(0)}',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: Colors.grey[700],
                                      fontWeight: FontWeight.w500,
                                      decoration: TextDecoration.lineThrough,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (hasSizes) ...[
                              const SizedBox(height: 8),
                              const Text(
                                'Customize',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _kDark,
                                ),
                              ),
                              const SizedBox(height: 6),
                              _buildSizeSelector(),
                            ],
                            if (!hasSizes && hasVariants) ...[
                              const SizedBox(height: 8),
                              const Text(
                                'Customize',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _kDark,
                                ),
                              ),
                              const SizedBox(height: 6),
                              _buildVariantSelector(variants),
                            ],
                          ],
                        ),
                      ),
                      const _Divider(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Row(
                          children: [
                            const Text(
                              'Quantity',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _kDark,
                              ),
                            ),
                            const Spacer(),
                            _QuantitySelector(
                              qty: _quantity,
                              maxQty: _maxQty,
                              onIncrease: _increment,
                              onDecrease: _decrement,
                            ),
                          ],
                        ),
                      ),
                      const _Divider(),
                      if (description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'About This Item',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: _kDark,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                description,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF555555),
                                  height: 1.55,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroImage(String imageUrl, bool isHot, bool isAssetImage) {
    return SizedBox(
      width: double.infinity,
      height: 205,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: _kOrangeLight,
              child: imageUrl.isNotEmpty
                  ? (isAssetImage
                      ? Image.asset(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _imagePlaceholder(),
                        )
                      : ImageHelper.networkImage(
                          url: imageUrl,
                          fit: BoxFit.cover,
                          errorWidget: _imagePlaceholder(),
                        ))
                  : _imagePlaceholder(),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.18),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 10,
            left: 12,
            child: _overlayButton(
              icon: Icons.close_rounded,
              onTap: () => Navigator.pop(context),
            ),
          ),
          if (isHot)
            Positioned(
              bottom: 12,
              left: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red[600],
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '🔥 Hot Item',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (_discountPercent > 0)
            Positioned(
              bottom: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _kOrange,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_discountPercent% OFF',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _overlayButton({
    required IconData icon,
    Color? iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.93),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 6,
            ),
          ],
        ),
        child: Icon(icon, size: 18, color: iconColor ?? _kDark),
      ),
    );
  }

  Widget _imagePlaceholder() {
    return Center(
      child: Icon(Icons.fastfood_rounded,
          size: 52, color: _kOrange.withValues(alpha: 0.25)),
    );
  }

  Widget _buildRatingRow(double rating) {
    return GestureDetector(
      onTap: () {
        showDialog(
          context: context,
          builder: (context) => ProductRatingDialog(
            shopId: widget.product['shopId']?.toString() ?? '',
            productId: widget.product['id']?.toString() ?? '',
            productName: widget.product['name']?.toString() ?? 'Product',
            onSubmitted: () {
              Navigator.of(context).pop();
              Fluttertoast.showToast(msg: 'Thank you for your rating!');
            },
          ),
        );
      },
      child: Row(
        children: [
          ...List.generate(5, (i) {
            final filled = rating >= i + 1;
            final half = !filled && rating > i;
            return Icon(
              half ? Icons.star_half_rounded : Icons.star_rounded,
              size: 16,
              color: filled || half ? const Color(0xFFF59E0B) : const Color(0xFFE0E0E0),
            );
          }),
          const SizedBox(width: 5),
          Text(
            '${rating.toStringAsFixed(1)} (${widget.product['ratingCount'] ?? 0} reviews)',
            style: const TextStyle(
              fontSize: 12,
              color: _kGray,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.edit_rounded, size: 14, color: _kGray),
        ],
      ),
    );
  }

  // ── Horizontal Scroll Size Selector ──
  Widget _buildSizeSelector() {
    if (_parsedSizes.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          for (int i = 0; i < _parsedSizes.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: SizedBox(
                width: 105, // Narrow width
                child: _SizeCard(
                  label: (_parsedSizes[i]['label'] ?? 'Size ${i + 1}').toString(),
                  price: _toDouble(_parsedSizes[i]['price']),
                  originalPrice: _toDouble(_parsedSizes[i]['originalPrice']),
                  selected: _selectedSizeIndex == i,
                  onTap: () => _selectSize(i),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _selectSize(int index) {
    setState(() {
      _selectedSizeIndex = index;
      _selectedPrice = _toDouble(_parsedSizes[index]['price']);
      _originalPrice = _toDouble(_parsedSizes[index]['originalPrice']);
      _selectedVariantId = null;
    });
  }

  // ── Horizontal Scroll Variant Selector ──
  Widget _buildVariantSelector(Map<dynamic, dynamic> variants) {
    final entries = variants.entries.toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          for (final entry in entries)
            if (entry.value is Map)
              Builder(
                builder: (context) {
                  final data = Map<dynamic, dynamic>.from(entry.value as Map);
                  final title = (data['name'] ?? data['label'] ?? data['title'] ?? 'Option').toString();
                  final price = _toDouble(data['price'] ?? data['amount']);
                  final original = _toDouble(data['originalPrice'] ?? data['oldPrice']);

                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: SizedBox(
                      width: 105, // Narrow width
                      child: _VariantCard(
                        title: title,
                        price: price,
                        originalPrice: original,
                        selected: _selectedVariantId == entry.key.toString(),
                        onTap: () => setState(() {
                          _selectedVariantId = entry.key.toString();
                          _selectedPrice = price;
                          _originalPrice = original;
                          _selectedSizeIndex = -1;
                        }),
                      ),
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _kBorder)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Total',
                style: TextStyle(
                  fontSize: 12,
                  color: _kGray,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                'Rs. ${_totalPrice.toStringAsFixed(0)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: _kOrange,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ScaleTransition(
              scale: _cartBtnScale,
              child: SizedBox(
                height: 46,
                child: ElevatedButton(
                  onPressed: _handleAddToCart,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _addedToCart
                        ? const Color(0xFF22C55E)
                        : _kOrange,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _addedToCart ? '✓ Added to Cart!' : '🛒  Add to Cart',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 20),
        color: _kBorder,
      ),
    );
  }
}

class _SizeCard extends StatelessWidget {
  final String label;
  final double price;
  final double originalPrice;
  final bool selected;
  final VoidCallback onTap;

  const _SizeCard({
    required this.label,
    required this.price,
    this.originalPrice = 0,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? _kOrangeLight : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _kOrange : _kBorder,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _kOrange.withValues(alpha: 0.14),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 22,
              color: selected ? _kOrange : Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? _kOrange : _kDark,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Rs. ${price.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: selected ? _kOrange : _kDark,
              ),
            ),
            if (originalPrice > 0 && originalPrice > price) ...[
              const SizedBox(height: 2),
              Text(
                'Rs. ${originalPrice.toStringAsFixed(0)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[700],
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VariantCard extends StatelessWidget {
  final String title;
  final double price;
  final double originalPrice;
  final bool selected;
  final VoidCallback onTap;

  const _VariantCard({
    required this.title,
    required this.price,
    this.originalPrice = 0,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? _kOrangeLight : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _kOrange : _kBorder,
            width: selected ? 1.6 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: selected ? 0.06 : 0.04),
              blurRadius: selected ? 8 : 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 22,
              color: selected ? _kOrange : Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? _kOrange : _kDark,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Rs. ${price.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: selected ? _kOrange : _kDark,
              ),
            ),
            if (originalPrice > 0 && originalPrice > price) ...[
              const SizedBox(height: 2),
              Text(
                'Rs. ${originalPrice.toStringAsFixed(0)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[700],
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuantitySelector extends StatelessWidget {
  final int qty;
  final int maxQty;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;

  const _QuantitySelector({
    required this.qty,
    required this.maxQty,
    required this.onIncrease,
    required this.onDecrease,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(
          icon: Icons.remove_rounded,
          onTap: onDecrease,
          enabled: qty > 1,
          filled: false,
        ),
        Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 8),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _kOrangeLight,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$qty',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _kOrange,
            ),
          ),
        ),
        _btn(
          icon: Icons.add_rounded,
          onTap: onIncrease,
          enabled: qty < maxQty,
          filled: true,
        ),
      ],
    );
  }

  Widget _btn({
    required IconData icon,
    required VoidCallback onTap,
    required bool enabled,
    required bool filled,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: filled
              ? (enabled ? _kOrange : _kOrange.withValues(alpha: 0.35))
              : (enabled ? Colors.white : Colors.grey[100]),
          borderRadius: BorderRadius.circular(10),
          border: filled
              ? null
              : Border.all(color: enabled ? _kBorder : Colors.grey[200]!),
        ),
        child: Icon(
          icon,
          size: 18,
          color: filled
              ? Colors.white
              : (enabled ? _kDark : Colors.grey[400]),
        ),
      ),
    );
  }
}