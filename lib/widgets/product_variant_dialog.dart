import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/image_helper.dart';

class ProductVariantDialog extends StatefulWidget {
  final Map<String, dynamic> product;
  final int currentQuantity;

  const ProductVariantDialog({
    super.key,
    required this.product,
    this.currentQuantity = 0,
  });

  @override
  State<ProductVariantDialog> createState() => _ProductVariantDialogState();
}

class _ProductVariantDialogState extends State<ProductVariantDialog>
    with SingleTickerProviderStateMixin {
  late int _quantity;
  late TextEditingController _controller;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  String? _selectedVariant; // Variant ID
  double _selectedPrice = 0;

  static const Color _primary = Color(0xFFFF6B00);

  double _toDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  @override
  void initState() {
    super.initState();
    _quantity = widget.currentQuantity > 0 ? widget.currentQuantity : 1;
    _controller = TextEditingController(text: '$_quantity');
    _animController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _scaleAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();

    // Initialize with first variant or base price
    final variants = widget.product['variants'] as Map<dynamic, dynamic>?;
    if (variants != null && variants.isNotEmpty) {
      final firstKey = variants.keys.first;
      _selectedVariant = firstKey.toString();
      _selectedPrice = _toDouble(
        variants[firstKey]['price'] ?? widget.product['price'],
      );
    } else {
      _selectedPrice = _toDouble(widget.product['price']);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _increment() {
    final maxQty = widget.product['maxQuantity'] as int?;
    if (maxQty != null && _quantity >= maxQty) {
      _showMaxLimitSnack(maxQty);
      return;
    }
    setState(() {
      _quantity++;
      _controller.text = '$_quantity';
    });
  }

  void _decrement() {
    if (_quantity > 1) {
      setState(() {
        _quantity--;
        _controller.text = '$_quantity';
      });
    }
  }

  void _showMaxLimitSnack(int max) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Maximum quantity: $max'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onManualInput(String value) {
    final parsed = int.tryParse(value);
    final maxQty = widget.product['maxQuantity'] as int?;
    if (parsed != null && parsed > 0) {
      if (maxQty != null && parsed > maxQty) {
        _showMaxLimitSnack(maxQty);
        setState(() {
          _quantity = maxQty;
          _controller.text = '$_quantity';
        });
      } else {
        setState(() => _quantity = parsed);
      }
    } else if (value.isEmpty) {
      setState(() => _quantity = 1);
    }
  }

  String _resolveProductImageUrl(Map<String, dynamic> product) {
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

  @override
  Widget build(BuildContext context) {
    final imageUrl = _resolveProductImageUrl(widget.product);
    final name = widget.product['name'] ?? 'Product';
    final rating = _toDouble(widget.product['rating']);
    final maxQty = widget.product['maxQuantity'] as int?;
    final variants = widget.product['variants'] as Map<dynamic, dynamic>?;
    final hasVariants = variants != null && variants.isNotEmpty;

    return ScaleTransition(
      scale: _scaleAnim,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 650),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Product Image & Info
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.orange[50],
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.orange[100]!, width: 2),
                    ),
                    child: imageUrl.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: ImageHelper.networkImage(
                              url: imageUrl,
                              fit: BoxFit.cover,
                              errorWidget: const Center(
                                child: Icon(
                                  Icons.fastfood_rounded,
                                  color: _primary,
                                  size: 50,
                                ),
                              ),
                            ),
                          )
                        : const Icon(Icons.fastfood_rounded, color: _primary, size: 50),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 19,
                      color: Color(0xFF1A1A1A),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  // Rating
                  if (rating > 0)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.star, size: 18, color: Colors.amber[600]),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 20),
                  // Variants Section
                  if (hasVariants) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Select Variant:',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...variants.entries.map((entry) {
                      final variantId = entry.key.toString();
                      final variantData = entry.value as Map<dynamic, dynamic>;
                      final variantName = variantData['name'] ?? 'Option';
                      final variantPrice = _toDouble(variantData['price']);
                      final isSelected = _selectedVariant == variantId;

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedVariant = variantId;
                            _selectedPrice = variantPrice;
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isSelected ? _primary.withValues(alpha: 0.1) : Colors.grey[50],
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected ? _primary : Colors.grey[300]!,
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: isSelected ? _primary : Colors.grey[400],
                                size: 22,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  variantName,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                                    color: isSelected ? _primary : const Color(0xFF1A1A1A),
                                  ),
                                ),
                              ),
                              Text(
                                'Rs. ${variantPrice.toStringAsFixed(0)}',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  color: isSelected ? _primary : Colors.grey[700],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                  ] else ...[
                    Text(
                      'Rs. ${_selectedPrice.toStringAsFixed(0)} per item',
                      style: TextStyle(
                        fontSize: 16,
                        color: _primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  // Max quantity indicator
                  if (maxQty != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange[200]!),
                      ),
                      child: Text(
                        'Max: $maxQty available',
                        style: const TextStyle(
                          fontSize: 11,
                          color: _primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Quantity Selector
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey[200]!),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Decrement
                        GestureDetector(
                          onTap: _decrement,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _quantity > 1 ? Colors.grey[200] : Colors.grey[100],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.remove,
                              color: _quantity > 1 ? const Color(0xFF1A1A1A) : Colors.grey[400],
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        // Manual Input
                        SizedBox(
                          width: 70,
                          child: TextField(
                            controller: _controller,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              color: _primary,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onChanged: _onManualInput,
                            onSubmitted: _onManualInput,
                          ),
                        ),
                        const SizedBox(width: 20),
                        // Increment
                        GestureDetector(
                          onTap: _increment,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _primary,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: _primary.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.add, color: Colors.white, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Total Price
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [_primary.withValues(alpha: 0.1), Colors.orange[50]!],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.orange[200]!),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        Text(
                          'Rs. ${(_selectedPrice * _quantity).toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: _primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: BorderSide(color: Colors.grey[300]!),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () {
                            // Return quantity, variant, and price
                            Navigator.pop(context, {
                              'quantity': _quantity,
                              'variantId': _selectedVariant,
                              'price': _selectedPrice,
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 2,
                          ),
                          child: const Text(
                            'Add to Cart',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
