import 'dart:ui';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../home_page.dart';
import 'my_orders_page.dart';
import 'settings_page.dart';
import 'shops_page.dart';
import 'cart_page.dart';
import '../services/cart_service.dart';
import '../services/city_scope_service.dart';
import '../widgets/animations.dart';

class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class MainLayout extends StatefulWidget {
  final int initialIndex;
  const MainLayout({super.key, this.initialIndex = 0});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  late int _selectedIndex;
  late final PageController _pageController;
  final CartService _cartService = CartService();
  final GlobalKey<MyOrdersPageState> _myOrdersPageKey =
      GlobalKey<MyOrdersPageState>();
  bool _ordersRefreshRetryActive = false;
  bool _startupPopupHandled = false;
  int _pendingOrders = 0;
  StreamSubscription<DatabaseEvent>? _shopOrdersSub;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _selectedIndex);
    _pages = [
      _KeepAlivePage(child: HomePage(onNavigate: _onItemTapped)),
      const _KeepAlivePage(child: ShopsPage()),
      _KeepAlivePage(child: MyOrdersPage(key: _myOrdersPageKey)),
      const _KeepAlivePage(child: SettingsPage()),
    ];
    _cartService.addListener(_onCartChanged);
    _listenPendingOrders();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshOrdersIfNeeded(_selectedIndex);
      _showStartupPopupIfEnabled();
    });
  }

  bool _toBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  Future<void> _showStartupPopupIfEnabled() async {
    if (_startupPopupHandled || !mounted) return;
    _startupPopupHandled = true;

    try {
      await CityScopeService.ensureLoaded();
      final snap = await FirebaseDatabase.instance
          .ref(_tenantPath('settings/app-control'))
          .get();
      if (!mounted || !snap.exists || snap.value is! Map) return;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final popupEnabled = _toBool(data['startupPopupEnabled'], fallback: false);
      final popupMessage = (data['startupPopupMessage'] ?? '').toString().trim();
      final popupTitle = (data['startupPopupTitle'] ?? 'Koi bhi instructions')
          .toString()
          .trim();

      if (!popupEnabled || popupMessage.isEmpty) return;
      if (!mounted) return;

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  popupTitle.isEmpty ? 'Koi bhi instructions' : popupTitle,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Text(
              popupMessage,
              style: const TextStyle(fontSize: 14.5, height: 1.35),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  bool _isActiveStatus(String status) {
    const inactive = {'delivered', 'cancelled', 'rejected'};
    return !inactive.contains(status.toLowerCase());
  }

  void _listenPendingOrders() {
    FirebaseAuth.instance.authStateChanges().listen((user) {
      _shopOrdersSub?.cancel();

      if (user == null) {
        if (mounted) setState(() => _pendingOrders = 0);
        return;
      }

      CityScopeService.ensureLoaded().then((_) {
        if (!mounted) return;

        void syncCount(int count) {
          if (!mounted) return;
          setState(() => _pendingOrders = count);
        }

        _shopOrdersSub = FirebaseDatabase.instance
            .ref(_tenantPath('shop-orders'))
            .orderByChild('userId')
            .equalTo(user.uid)
            .onValue
            .listen((event) {
              int shopActive = 0;
              if (event.snapshot.exists && event.snapshot.value is Map) {
                (event.snapshot.value as Map).forEach((_, value) {
                  if (value is Map) {
                    final status = (value['status'] ?? 'pending').toString();
                    if (_isActiveStatus(status)) shopActive++;
                  }
                });
              }
              syncCount(shopActive);
            });
      });
    });
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  void _refreshOrdersIfNeeded(int index) {
    if (index != 2) return;
    _refreshOrdersPageWithRetry();
  }

  void _refreshOrdersPageWithRetry({int attempt = 0}) {
    if (!mounted) {
      _ordersRefreshRetryActive = false;
      return;
    }

    if (!_ordersRefreshRetryActive) {
      _ordersRefreshRetryActive = true;
    }

    final state = _myOrdersPageKey.currentState;
    if (state != null) {
      state.refreshNow(showLoader: attempt == 0);
      _ordersRefreshRetryActive = false;
      return;
    }

    if (attempt >= 15) {
      _ordersRefreshRetryActive = false;
      return;
    }

    Future.delayed(const Duration(milliseconds: 120), () {
      _refreshOrdersPageWithRetry(attempt: attempt + 1);
    });
  }

  @override
  void dispose() {
    _cartService.removeListener(_onCartChanged);
    _shopOrdersSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _onItemTapped(int index) {
    if (_selectedIndex == index) {
      _refreshOrdersIfNeeded(index);
      return;
    }
    setState(() => _selectedIndex = index);
    _refreshOrdersIfNeeded(index);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
    Widget? badge,
  }) {
    final selected = _selectedIndex == index;
    const accent = Color(0xFFFF6B00);

    return Expanded(
      child: ScaleTap(
        onTap: () => _onItemTapped(index),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          scale: selected ? 1.03 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(
                    selected ? activeIcon : icon,
                    size: 25,
                    color: selected ? accent : Colors.black,
                  ),
                  if (badge != null)
                    Positioned(
                      right: -8,
                      top: -8,
                      child: badge,
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: selected ? accent : Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCartButton() {
    return ScaleTap(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CartPage()),
      ),
      child: SizedBox(
        width: 70,
        height: 70,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: const Color(0xFFFF6B00),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF6B00).withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: const Icon(
                Icons.shopping_bag_outlined,
                color: Colors.white,
                size: 28,
              ),
            ),
            if (_cartService.itemCount > 0)
              Positioned(
                top: 7,
                right: 7,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF2D2D),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      _cartService.itemCount > 9
                          ? '9+'
                          : '${_cartService.itemCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
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
      backgroundColor: Colors.white,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          if (_selectedIndex != index && mounted) {
            setState(() => _selectedIndex = index);
          }
          _refreshOrdersIfNeeded(index);
        },
        physics: const PageScrollPhysics(),
        children: _pages,
      ),
      floatingActionButton: _buildCartButton(),
      floatingActionButtonLocation: const CustomCenterDockedLocation(),
      bottomNavigationBar: SizedBox(
        height: 52,
        child: BottomAppBar(
          color: Colors.white,
          elevation: 8,
          shape: const CircularNotchedRectangle(),
          notchMargin: 6,
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
            children: [
              _buildNavItem(
                index: 0,
                icon: Icons.home_rounded,
                activeIcon: Icons.home_rounded,
                label: 'Home',
              ),
              _buildNavItem(
                index: 1,
                icon: Icons.storefront_outlined,
                activeIcon: Icons.storefront_rounded,
                label: 'Shop',
              ),
              const Expanded(child: SizedBox()),
              _buildNavItem(
                index: 2,
                icon: Icons.receipt_long_outlined,
                activeIcon: Icons.receipt_long_rounded,
                label: 'Orders',
                badge: _pendingOrders > 0
                    ? Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF6B00),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          _pendingOrders > 9 ? '9+' : '$_pendingOrders',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      )
                    : null,
              ),
              _buildNavItem(
                index: 3,
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class CustomCenterDockedLocation extends FloatingActionButtonLocation {
  const CustomCenterDockedLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final double fabX = (scaffoldGeometry.scaffoldSize.width - scaffoldGeometry.floatingActionButtonSize.width) / 2.0;
    return Offset(
      fabX,
      scaffoldGeometry.contentBottom - (scaffoldGeometry.floatingActionButtonSize.height / 2.0) + 12.0,
    );
  }
}
