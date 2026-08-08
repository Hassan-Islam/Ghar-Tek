import 'package:flutter/material.dart';
import '../services/image_helper.dart';
import '../services/cart_service.dart';
import 'checkout_page.dart';
import '../services/analytics_service.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../widgets/animations.dart';

class CartPage extends StatefulWidget {
  final CartScope scope;

  const CartPage({super.key, this.scope = CartScope.standard});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> with SingleTickerProviderStateMixin {
  CartScope get _scope => widget.scope;
  List<CartItem> get _items => _cartService.itemsFor(_scope);
  // ── Theme ──────────────────────────────────────────────────────────────────
  static const Color _primary = Color(0xFFFF6B00);
  static const Color _primaryLight = Color(0xFFFFF3E8);
  static const Color _bg = Color(0xFFFFFBF7);

  final CartService _cartService = CartService();
  late AnimationController _emptyAnim;
  late Animation<double> _emptyFade;
  final TextEditingController _instructionsController = TextEditingController();
  bool _wentToCheckout = false;

  @override
  void initState() {
    super.initState();
    _cartService.addListener(_onCartChanged);
    _instructionsController.text = _cartService.deliveryInstructionsFor(_scope);
    _cartService.loadFeeSettings();
    _cartService.startFeeListener();
    _emptyAnim = AnimationController(
        duration: const Duration(milliseconds: 700), vsync: this)
      ..forward();
    _emptyFade =
        CurvedAnimation(parent: _emptyAnim, curve: Curves.easeOut);
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (!_wentToCheckout && !_cartService.isEmptyFor(_scope)) {
      AnalyticsService.orderAbandoned(
        _cartService.subtotalFor(_scope),
        _cartService.itemCountFor(_scope),
        'cart_page',
      );
    }
    _cartService.removeListener(_onCartChanged);
    _instructionsController.dispose();
    _emptyAnim.dispose();
    super.dispose();
  }

  Future<bool> _confirmClear() async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: const Text('Clear Cart?',
                style: TextStyle(fontWeight: FontWeight.w800)),
            content:
                const Text('Remove all items from cart?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Clear All'),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isEmpty = _cartService.isEmptyFor(_scope);
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(isEmpty),
            Expanded(
              child:
                  isEmpty ? _buildEmptyCart() : _buildCartContent(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader(bool isEmpty) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x09000000),
              blurRadius: 8,
              offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _scope == CartScope.instant ? 'Instant Cart' : 'My Cart',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const Text(
                  'Review your items before checkout',
                  style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                ),
              ],
            ),
          ),
          if (!isEmpty)
            GestureDetector(
              onTap: () async {
                final ok = await _confirmClear();
                if (ok) _cartService.clearCart(scope: _scope);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: Colors.red[100]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.delete_outline,
                        size: 14, color: Colors.red[600]),
                    const SizedBox(width: 4),
                    Text('Clear',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.red[600])),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Cart Content ─────────────────────────────────────────────────────────
  Widget _buildCartContent() {
    return Column(
      children: [
        _buildShopBanner(),
        Expanded(child: _buildItemList()),
        _buildInstructionsField(),
        _buildCheckoutBar(),
      ],
    );
  }

  // ── Shop Banner ───────────────────────────────────────────────────────────
  Widget _buildShopBanner() {
    final first = _items.first;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.storefront_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  first.shopName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  '${_cartService.itemCountFor(_scope)} item${_cartService.itemCountFor(_scope) == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Rs. ${_cartService.subtotalFor(_scope).toStringAsFixed(0)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  // ── Items list ─────────────────────────────────────────────────────────────
  Widget _buildItemList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      itemCount: _items.length,
      itemBuilder: (ctx, i) {
        final item = _items[i];
        return Dismissible(
          key: Key(item.id),
          direction: DismissDirection.endToStart,
          background: _swipeDeleteBg(),
          confirmDismiss: (_) async => true,
          onDismissed: (_) => _cartService.removeItem(item.id, scope: _scope),
          child: _buildCartItemCard(item),
        ).animateListItem(index: i);
      },
    );
  }

  Widget _swipeDeleteBg() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.red[400],
        borderRadius: BorderRadius.circular(18),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_rounded, color: Colors.white, size: 24),
          SizedBox(height: 2),
          Text('Remove',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildCartItemCard(CartItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 12,
              offset: Offset(0, 4)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Image
            Container(
              width: 85,
              height: 85,
              decoration: BoxDecoration(
                color: _primaryLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: (item.imageUrl != null &&
                      item.imageUrl!.isNotEmpty)
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: ImageHelper.networkImage(
                        url: item.imageUrl!,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Icon(Icons.fastfood_rounded,
                      color: _primary, size: 36),
            ),
            const SizedBox(width: 14),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: Color(0xFF1A1A1A)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Rs. ${item.price.toStringAsFixed(0)} each',
                    style: const TextStyle(
                        color: Color(0xFF999999), fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Rs. ${item.totalPrice.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: _primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
            // Qty controls
            _buildQtyControl(item),
          ],
        ),
      ),
    );
  }

  Widget _buildQtyControl(CartItem item) {
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            _cartService.increaseQuantity(item.id, scope: _scope);
            AnalyticsService.addToCart(item.id, item.name, item.price, item.shopId);
          },
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _primary,
              borderRadius: BorderRadius.circular(11),
              boxShadow: [
                BoxShadow(
                    color: _primary.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 3)),
              ],
            ),
            child: const Icon(Icons.add, color: Colors.white, size: 18),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${item.quantity}',
          style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: Color(0xFF1A1A1A)),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _cartService.decreaseQuantity(item.id, scope: _scope),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color:
                  item.quantity == 1 ? Colors.red[50] : Colors.grey[100],
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              item.quantity == 1
                  ? Icons.delete_outline_rounded
                  : Icons.remove_rounded,
              size: 18,
              color:
                  item.quantity == 1 ? Colors.red[400] : Colors.grey[600],
            ),
          ),
        ),
      ],
    );
  }

  // ── Instructions Field ────────────────────────────────────────────────────
  Widget _buildInstructionsField() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0EDE8)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x06000000),
              blurRadius: 10,
              offset: Offset(0, -2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                    color: _primaryLight,
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.edit_note_rounded,
                    color: _primary, size: 18),
              ),
              const SizedBox(width: 10),
              const Text('Delivery Instructions',
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _instructionsController,
            onChanged: (value) =>
                _cartService.setDeliveryInstructions(value, scope: _scope),
            decoration: InputDecoration(
              hintText: 'e.g., Ring the bell, leave at gate...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[200]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primary),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            maxLines: 2,
          ),
        ],
      ),
    );
  }

  // ── Checkout Bar ──────────────────────────────────────────────────────────
  Widget _buildCheckoutBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: ScaleTap(
        onTap: () {
          _wentToCheckout = true;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CheckoutPage(cartScope: _scope),
            ),
          );
        },
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: _primary.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 28),
                  child: Text(
                    'Proceed to Checkout',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    Text(
                      'Rs. ${_cartService.subtotalFor(_scope).toStringAsFixed(0)}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_forward_rounded,
                        color: Colors.white, size: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Empty State ───────────────────────────────────────────────────────────
  Widget _buildEmptyCart() {
    return FadeTransition(
      opacity: _emptyFade,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: _primaryLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.shopping_cart_outlined,
                    size: 56, color: _primary),
              ),
              const SizedBox(height: 24),
              const Text(
                'Your cart is empty',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A)),
              ),
              const SizedBox(height: 10),
              Text(
                'Browse shops and add your favourite dishes to get started!',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[500],
                    height: 1.5),
              ),
              const SizedBox(height: 32),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
                    ),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: _primary.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Text(
                    'Browse Shops',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
