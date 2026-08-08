import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/image_helper.dart';

class QuantitySelectorDialog extends StatefulWidget {
  final String itemName;
  final double price;
  final String? imageUrl;
  final int currentQuantity;
  final int? maxQuantity; // Admin-configured max quantity

  const QuantitySelectorDialog({
    super.key,
    required this.itemName,
    required this.price,
    this.imageUrl,
    this.currentQuantity = 0,
    this.maxQuantity,
  });

  @override
  State<QuantitySelectorDialog> createState() => _QuantitySelectorDialogState();
}

class _QuantitySelectorDialogState extends State<QuantitySelectorDialog>
    with SingleTickerProviderStateMixin {
  late int _quantity;
  late TextEditingController _controller;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  static const Color _primary = Color(0xFFFF6B00);

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
  }

  @override
  void dispose() {
    _controller.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _increment() {
    if (widget.maxQuantity != null && _quantity >= widget.maxQuantity!) {
      _showMaxLimitSnack();
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

  void _showMaxLimitSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Maximum quantity: ${widget.maxQuantity}'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onManualInput(String value) {
    final parsed = int.tryParse(value);
    if (parsed != null && parsed > 0) {
      if (widget.maxQuantity != null && parsed > widget.maxQuantity!) {
        _showMaxLimitSnack();
        setState(() {
          _quantity = widget.maxQuantity!;
          _controller.text = '$_quantity';
        });
      } else {
        setState(() => _quantity = parsed);
      }
    } else if (value.isEmpty) {
      setState(() => _quantity = 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Product Image & Info
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orange[100]!, width: 2),
                ),
                child: widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: ImageHelper.networkImage(
                          url: widget.imageUrl!,
                          fit: BoxFit.cover,
                          errorWidget: const Center(
                            child: Icon(
                              Icons.fastfood_rounded,
                              color: _primary,
                              size: 40,
                            ),
                          ),
                        ),
                      )
                    : const Icon(Icons.fastfood_rounded, color: _primary, size: 40),
              ),
              const SizedBox(height: 16),
              Text(
                widget.itemName,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  color: Color(0xFF1A1A1A),
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                'Rs. ${widget.price.toStringAsFixed(0)} per item',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.maxQuantity != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange[200]!),
                  ),
                  child: Text(
                    'Max: ${widget.maxQuantity} available',
                    style: const TextStyle(
                      fontSize: 11,
                      color: _primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              // Quantity Selector
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    Text(
                      'Rs. ${(widget.price * _quantity).toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontSize: 20,
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
                      onPressed: () => Navigator.pop(context, _quantity),
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
    );
  }
}
