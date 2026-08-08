import 'package:flutter/material.dart';
import 'dart:async';
import '../services/image_helper.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import '../services/cart_service.dart';
import 'shop_menu_page.dart';
import 'shop_deals_page.dart';
import '../services/shops_cache_service.dart';
import '../services/analytics_service.dart';

class ShopsPage extends StatefulWidget {
  const ShopsPage({super.key});

  @override
  State<ShopsPage> createState() => _ShopsPageState();
}

class _ShopsPageState extends State<ShopsPage> with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFFFF6B00);
  static const Color _bg = Color(0xFFFFFBF7);

  final _database = FirebaseDatabase.instance.ref();
  final CartService _cartService = CartService();
  final _searchController = TextEditingController();
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  final ScrollController _scrollController = ScrollController();
  Timer? _statusRefreshTimer;
  Timer? _scrollDebounce;
  bool _searchVisible = true;
  double _lastScrollOffset = 0;

  List<Map<String, dynamic>> _allShops = [];
  List<Map<String, dynamic>> _filteredShops = [];
  bool _isLoading = true;
  bool _appTemporarilyClosed = false;
  String _appClosePopupMessage = 'App is temporarily closed due to maintenance.';
  String _selectedCategory = 'All';
  bool _showOpenOnly = false;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  bool _isShopOpenNow(Map<String, dynamic> shop) {
    if (_appTemporarilyClosed) return false;
    if (shop['isOpen'] == false || shop['status'] == 'closed') return false;

    final closedDays = (shop['closedDays'] as List?)?.map((e) => e.toString()).toList() ?? [];
    const daysOfWeek = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final todayName = daysOfWeek[DateTime.now().weekday - 1];
    if (closedDays.contains(todayName)) {
      return false;
    }

    final slots = _parseTimingSlots(shop['timingSlots']);
    if (slots.isNotEmpty) {
      final now = DateTime.now();
      final nowMinutes = now.hour * 60 + now.minute;
      var hasValidSlot = false;

      for (final slot in slots) {
        final open = (slot['openTime'] ?? '').trim();
        final close = (slot['closeTime'] ?? '').trim();
        if (open.isEmpty || close.isEmpty) continue;
        final openMinutes = _parseTimeToMinutes(open);
        final closeMinutes = _parseTimeToMinutes(close);
        if (openMinutes == null || closeMinutes == null) continue;
        hasValidSlot = true;

        if (openMinutes == closeMinutes) return true;
        if (openMinutes < closeMinutes) {
          if (nowMinutes >= openMinutes && nowMinutes < closeMinutes) {
            return true;
          }
        } else {
          if (nowMinutes >= openMinutes || nowMinutes < closeMinutes) {
            return true;
          }
        }
      }

      if (hasValidSlot) return false;
    }

    final openTimeRaw = (shop['openTime'] ?? '').toString().trim();
    final closeTimeRaw = (shop['closeTime'] ?? '').toString().trim();
    if (openTimeRaw.isEmpty || closeTimeRaw.isEmpty) return true;

    final openMinutes = _parseTimeToMinutes(openTimeRaw);
    final closeMinutes = _parseTimeToMinutes(closeTimeRaw);
    if (openMinutes == null || closeMinutes == null) return true;

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    if (openMinutes == closeMinutes) return true;
    if (openMinutes < closeMinutes) {
      return nowMinutes >= openMinutes && nowMinutes < closeMinutes;
    }
    return nowMinutes >= openMinutes || nowMinutes < closeMinutes;
  }

  int? _parseTimeToMinutes(String input) {
    final value = input.trim().toUpperCase();
    final match = RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$').firstMatch(value);
    if (match == null) return null;

    int hour = int.tryParse(match.group(1) ?? '') ?? -1;
    final minute = int.tryParse(match.group(2) ?? '') ?? -1;
    final amPm = match.group(3);
    if (hour < 0 || minute < 0 || minute > 59) return null;

    if (amPm != null) {
      if (hour == 12) hour = 0;
      if (amPm == 'PM') hour += 12;
    }
    if (hour < 0 || hour > 23) return null;
    return hour * 60 + minute;
  }

  List<Map<String, String>> _parseTimingSlots(dynamic raw) {
    final slots = <Map<String, String>>[];

    void addSlot(dynamic item) {
      if (item is! Map) return;
      final map = Map<dynamic, dynamic>.from(item);
      final open = (map['openTime'] ?? '').toString().trim();
      final close = (map['closeTime'] ?? '').toString().trim();
      if (open.isEmpty || close.isEmpty) return;
      slots.add({'openTime': open, 'closeTime': close});
    }

    if (raw is List) {
      for (final item in raw) {
        addSlot(item);
      }
    } else if (raw is Map) {
      final map = Map<dynamic, dynamic>.from(raw);
      for (final item in map.values) {
        addSlot(item);
      }
    }

    return slots;
  }

  double? _tryToDouble(dynamic value) {
    if (value is num) return value.toDouble();
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  void _sortShopsByOpenStatus(List<Map<String, dynamic>> shops) {
    shops.sort((a, b) {
      final aOpen = _isShopOpenNow(a);
      final bOpen = _isShopOpenNow(b);
      if (aOpen == bOpen) return 0;
      return aOpen ? -1 : 1;
    });
  }

  String _resolveImageValue(dynamic raw) {
    if (raw == null) return '';
    return ImageHelper.getDirectImageUrl(raw.toString());
  }

  BoxFit _parseShopImageFit(Map<String, dynamic> shop) {
    switch ((shop['imageFit'] ?? 'cover').toString()) {
      case 'contain':
        return BoxFit.contain;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      default:
        return BoxFit.cover;
    }
  }

  String _resolveShopImage(Map<String, dynamic> shop) {
    const keys = <String>[
      'imageUrl',
      'image',
      'logo',
      'logoUrl',
      'bannerImage',
      'bannerUrl',
      'banner_url',
      'photo',
      'photoUrl',
      'photoURL',
      'thumbnail',
      'thumbnailUrl',
      'secure_url',
      'url',
    ];
    for (final key in keys) {
      final value = _resolveImageValue(shop[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(duration: const Duration(milliseconds: 600), vsync: this);
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut),
    );
    _cartService.addListener(_onFeeChanged);
    _cartService.loadFeeSettings();
    _startStatusRefreshTimer();
    ShopsCacheService.instance.warmUp();
    _loadShops();
    _searchController.addListener(_applyFilter);
    _scrollController.addListener(_onScroll);
  }

  void _onFeeChanged() {
    if (mounted) setState(() {});
  }

  void _startStatusRefreshTimer() {
    _statusRefreshTimer?.cancel();
    _statusRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      _applyFilter();
    });
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final dy = offset - _lastScrollOffset;
    _lastScrollOffset = offset;
    if ((dy > 12 && _searchVisible) || (dy < -12 && !_searchVisible)) {
      _scrollDebounce?.cancel();
      _scrollDebounce = Timer(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        if (dy > 12 && _searchVisible) {
          setState(() => _searchVisible = false);
        } else if (dy < -12 && !_searchVisible) {
          setState(() => _searchVisible = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _statusRefreshTimer?.cancel();
    _scrollDebounce?.cancel();
    _fadeCtrl.dispose();
    _searchController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _cartService.removeListener(_onFeeChanged);
    super.dispose();
  }

  Future<void> _loadShops() async {
    setState(() => _isLoading = true);
    try {
      await CityScopeService.ensureLoaded();
      final results = await Future.wait([
        ShopsCacheService.instance.getAppControl(),
        ShopsCacheService.instance.getShopsMap(),
      ]);
      final appData = results[0];
      final shopsRaw = results[1];
      List<Map<String, dynamic>> shops = [];

      bool randomShopsEnabled = true;
      _appTemporarilyClosed = appData['temporarilyClosed'] == true;
      _appClosePopupMessage =
          (appData['closePopupMessage'] ?? _appClosePopupMessage).toString();
      randomShopsEnabled = appData['randomShopsEnabled'] != false;

      shopsRaw.forEach((key, val) {
        if (val is! Map) return;
        final shop = Map<String, dynamic>.from(val);
        if (shop['isVisible'] == false) return;
        shop['id'] = key;
        shop['menuCount'] = 0;
        shop['dealsCount'] = 0;
        shops.add(shop);
      });
      if (randomShopsEnabled) {
        shops.shuffle();
      } else {
        shops.sort((a, b) {
          final aRating = _tryToDouble(a['rating']) ?? 4.0;
          final bRating = _tryToDouble(b['rating']) ?? 4.0;
          return bRating.compareTo(aRating);
        });
      }
      _sortShopsByOpenStatus(shops);
      if (mounted) {
        setState(() {
          _allShops = shops;
          _filteredShops = shops;
          _isLoading = false;
        });
        _fadeCtrl.forward();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyFilter() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredShops = _allShops.where((shop) {
        final matchesSearch = query.isEmpty ||
            (shop['name'] ?? '').toString().toLowerCase().contains(query) ||
            (shop['category'] ?? '').toString().toLowerCase().contains(query) ||
            (shop['description'] ?? '').toString().toLowerCase().contains(query);
        final matchesCategory = _selectedCategory == 'All' ||
            (shop['category'] ?? '').toString().toLowerCase().contains(_selectedCategory.toLowerCase());
        final isOpen = _isShopOpenNow(shop);
        final matchesOpen = !_showOpenOnly || isOpen;
        return matchesSearch && matchesCategory && matchesOpen;
      }).toList();
      _sortShopsByOpenStatus(_filteredShops);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              height: _searchVisible ? null : 0,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: _buildSearchBar(),
            ),
            _buildFilterRow(),
            Expanded(
              child: _isLoading
                  ? _buildLoadingState()
                  : _filteredShops.isEmpty
                      ? _buildEmptyState()
                      : FadeTransition(
                          opacity: _fadeAnim,
                          child: RefreshIndicator(
                            color: _primary,
                            onRefresh: _loadShops,
                            child: _buildShopsGrid(),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Restaurants & Shops',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search for Restaurants or Shop...',
            hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
            prefixIcon: Icon(Icons.search_rounded, color: _primary),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close, color: Colors.grey[400], size: 18),
                    onPressed: () {
                      _searchController.clear();
                      _applyFilter();
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _showOpenOnly = !_showOpenOnly);
              _applyFilter();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _showOpenOnly ? Colors.green[50] : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _showOpenOnly ? Colors.green : Colors.grey[300]!,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _showOpenOnly ? Colors.green : Colors.grey[400],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Open Now',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _showOpenOnly ? Colors.green[700] : Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShopsGrid() {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      cacheExtent: 720,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        mainAxisExtent: 315,
      ),
      itemCount: _filteredShops.length,
      itemBuilder: (context, i) => RepaintBoundary(
        child: _buildShopCard(_filteredShops[i]),
      ),
    );
  }

  Widget _buildStarRating(double rating) {
    final full = rating.floor();
    final half = (rating - full) >= 0.5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        if (i < full) return const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFB300));
        if (i == full && half) return const Icon(Icons.star_half_rounded, size: 12, color: Color(0xFFFFB300));
        return const Icon(Icons.star_border_rounded, size: 12, color: Color(0xFFFFB300));
      }),
    );
  }

  Widget _buildShopCard(Map<String, dynamic> shop) {
    final imageUrl = _resolveShopImage(shop);
    final isOpen = _isShopOpenNow(shop);
    final name = shop['name'] ?? 'Restaurant';
    final category = shop['category'] ?? 'Food';
    final rating = shop['rating']?.toString() ?? '4.5';
    final deliveryTime = shop['deliveryTime']?.toString() ?? '30';
    final openTime = shop['openTime']?.toString() ?? '10:00 AM';
    final closeTime = shop['closeTime']?.toString() ?? '11:00 PM';
    final dealsCount = (shop['dealsCount'] as num?)?.toInt() ?? 0;
    final standardFeeBase = _cartService.standardDeliveryFeeBase;
    final shopDeliveryFee = _tryToDouble(shop['deliveryFeeStandard']);
    final showDeliveryFee = shopDeliveryFee != null &&
      (shopDeliveryFee - standardFeeBase).abs() >= 0.01;

    void openMenuOrPopup() {
      if (_appTemporarilyClosed) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Shop is Closed'),
            content: Text(_appClosePopupMessage),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
            ],
          ),
        );
        return;
      }
      AnalyticsService.shopClick(shop['id']?.toString() ?? '', name);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ShopMenuPage(shop: shop)),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: openMenuOrPopup,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: AspectRatio(
                  aspectRatio: 1 / 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      imageUrl.isNotEmpty
                          ? ImageHelper.networkImage(
                              url: imageUrl,
                              fit: _parseShopImageFit(shop),
                            )
                          : _buildShopImagePlaceholder(category),
                      if (!isOpen)
                        Container(
                          color: Colors.black.withValues(alpha: 0.45),
                          alignment: Alignment.center,
                          child: const Text(
                            'Shop is Closed',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOpen ? Colors.green : Colors.red,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isOpen ? 'Open' : 'Closed',
                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Color(0xFF1A1A1A),
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildStarRating(double.tryParse(rating) ?? 4.5),
                      const SizedBox(width: 4),
                      Text(rating,
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A))),
                      const SizedBox(width: 4),
                      Icon(Icons.access_time_rounded, size: 12, color: Colors.grey[500]),
                      const SizedBox(width: 3),
                      Text('${deliveryTime}m', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    ],
                  ),
                  if (showDeliveryFee) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.local_shipping_rounded,
                          size: 12,
                          color: Colors.deepOrange[700],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Delivery: Rs. ${shopDeliveryFee!.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Colors.deepOrange[700],
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '$openTime – $closeTime',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: Colors.grey[600], fontWeight: FontWeight.w600),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: openMenuOrPopup,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.grey.shade300),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          child: const Text('Menu', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                      ),
                      if (dealsCount > 0) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => ShopDealsPage(shop: shop)),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              elevation: 0,
                            ),
                            child: const Text('Deals', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShopImagePlaceholder(String category) {
    String emoji = '🍽️';
    Color bgColor = const Color(0xFFFFF3E8);
    if (category.toLowerCase().contains('fast') ||
        category.toLowerCase().contains('burger')) {
      emoji = '🍔';
      bgColor = const Color(0xFFFFF8E1);
    } else if (category.toLowerCase().contains('desi') ||
        category.toLowerCase().contains('biryani')) {
      emoji = '🍛';
      bgColor = const Color(0xFFFBE9E7);
    } else if (category.toLowerCase().contains('pizza')) {
      emoji = '🍕';
      bgColor = const Color(0xFFFFF9C4);
    } else if (category.toLowerCase().contains('drink')) {
      emoji = '🥤';
      bgColor = const Color(0xFFE8F5E9);
    } else if (category.toLowerCase().contains('dessert') ||
        category.toLowerCase().contains('sweet')) {
      emoji = '🍰';
      bgColor = const Color(0xFFFCE4EC);
    } else if (category.toLowerCase().contains('bbq')) {
      emoji = '🔥';
      bgColor = const Color(0xFFFFEBEE);
    } else if (category.toLowerCase().contains('grocery')) {
      emoji = '🛒';
      bgColor = const Color(0xFFE8F5E9);
    }
    return Container(
      color: bgColor,
      child: Center(
        child: Text(emoji, style: const TextStyle(fontSize: 44)),
      ),
    );
  }

  Widget _buildLoadingState() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.68,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
      ),
      itemCount: 6,
      itemBuilder: (context, i) => _buildShimmerCard(),
    );
  }

  Widget _buildShimmerCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
          )
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 120,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    height: 12,
                    width: 100,
                    decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(6))),
                const SizedBox(height: 6),
                Container(
                    height: 10,
                    width: 70,
                    decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(6))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 16),
          Text(
            'Koi restaurant nahi mila',
            style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Search ya category change karein',
            style: TextStyle(fontSize: 13, color: Colors.grey[400]),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _selectedCategory = 'All';
                _showOpenOnly = false;
              });
              _applyFilter();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Reset Filters'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ],
      ),
    );
  }
}
