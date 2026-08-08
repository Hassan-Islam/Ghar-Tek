import 'dart:async';
import 'dart:convert';
import 'package:flutter_animate/flutter_animate.dart';
import 'widgets/animations.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/auth_service.dart';
import 'services/category_timing_service.dart';
import 'services/city_scope_service.dart';
import 'services/image_helper.dart';
import 'services/connectivity_service.dart';
import 'pages/shop_menu_page.dart';
import 'pages/shop_deals_page.dart';
import 'pages/cart_page.dart';
import 'pages/local_notifications_page.dart';
import 'pages/loyalty_points_page.dart';
import 'pages/instant_delivery_page.dart';
import 'services/instant_delivery_service.dart';
import 'pages/weekly_reward_page.dart';
import 'services/cart_service.dart';
import 'widgets/product_detail_bottom_sheet.dart';
import 'widgets/animated_search_bar.dart';
import 'pages/global_search_page.dart';
import 'widgets/rating_dialog.dart';
import 'services/analytics_service.dart';
import 'pages/category_products_page.dart';
import 'pages/user_chats_list_page.dart';

class HomePage extends StatefulWidget {
  final void Function(int)? onNavigate;
  const HomePage({super.key, this.onNavigate});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _Shimmer extends StatefulWidget {
  final Widget child;

  const _Shimmer({required this.child});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerGradientTransform extends GradientTransform {
  final double offset;

  const _ShimmerGradientTransform(this.offset);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(offset, 0, 0);
  }
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            final width = rect.width;
            final offset = (width * 2) * _controller.value - width;
            return LinearGradient(
              colors: const [
                Color(0xFFE6E6E6),
                Color(0xFFF5F5F5),
                Color(0xFFE6E6E6),
              ],
              stops: const [0.1, 0.3, 0.4],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              transform: _ShimmerGradientTransform(offset),
            ).createShader(rect);
          },
          child: child,
        );
      },
    );
  }
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const Color _primary = Color(0xFFFF6B00);
  static const String _adPlacementBanner = 'banner';
  static const String _adPlacementTrendingFirst = 'trending_first_card';
  static const Set<String> _timedTrendingCategories = {
    'nashta',
    'breakfast',
    'lunch',
    'dinner',
  };
  static const Duration _homeCacheTtl = Duration(minutes: 10);
  static const String _trendingSnapshotPath = 'trending_summary';

  final AuthService _authService = AuthService();
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final CartService _cartService = CartService();
  final TextEditingController _searchController = TextEditingController();

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  User? _currentUser;
  Map<String, dynamic>? _userData;
  List<Map<String, dynamic>> _shops = [];
  List<Map<String, dynamic>> _allMenuItems = [];
  List<Map<String, dynamic>> _homeMenuItems = [];
  List<Map<String, dynamic>> _filteredItems = [];
  bool _isLoading = true;
  final String _selectedCategory = 'All';

  // Ad banner state
  List<Map<String, dynamic>> _ads = [];
  Map<String, dynamic>? _trendingFirstCardAd;
  int _currentAdIndex = 0;
  late PageController _adPageController;
  Timer? _adTimer;

  // Weekly Winners state
  List<String> _weeklyWinners = [];
  final int _currentWinnerIndex = 0;
  Timer? _winnerTickerTimer;

  // Connectivity
  final ConnectivityService _connectivity = ConnectivityService();
  Timer? _slowImageTimer;
  Timer? _shopStatusTimer;
  bool _isRetryingNetwork = false;
  bool _loyaltyPointsEnabled = true;
  bool _instantDeliveryEnabled = true;
  bool _isBackgroundRefreshing = false;
  DateTime? _lastResumeRefresh;
  StreamSubscription<DatabaseEvent>? _appControlSubscription;
  StreamSubscription<DatabaseEvent>? _homeCategoriesSub;

  final List<Map<String, dynamic>> _categories = [
    {'label': 'All', 'imagePath': 'assets/images/categories/all.jpg'},
    {'label': 'Biryani', 'imagePath': 'assets/images/categories/biryani.jpg'},
    {'label': 'Burger', 'imagePath': 'assets/images/categories/burger.jpg'},
    {'label': 'FastFood', 'imagePath': 'assets/images/categories/fastfood.jpg'},
    {
      'label': 'Ice Cream',
      'imagePath': 'assets/images/categories/ice_cream.jpg',
    },
    {'label': 'Pizza', 'imagePath': 'assets/images/categories/pizza.jpg'},
    {
      'label': 'Groceries',
      'imagePath': 'assets/images/categories/groceries.jpg',
    },
    {
      'label': 'Cold Drink',
      'imagePath': 'assets/images/categories/cold_drink.jpg',
    },
    {'label': 'Juices', 'imagePath': 'assets/images/categories/juices.jpg'},
    {
      'label': 'Tea & Coffe',
      'imagePath': 'assets/images/categories/tea_coffee.jpg',
    },
    {'label': 'Cakes', 'imagePath': 'assets/images/categories/cakes.jpg'},
  ];

  List<Map<String, dynamic>> _homeCategories = [];

  int _unreadChatCount = 0;
  StreamSubscription<DatabaseEvent>? _unreadChatsSub;

  @override
  void initState() {
    super.initState();
    _homeCategories = _categories.toList();
    WidgetsBinding.instance.addObserver(this);
    _adPageController = PageController();
    _cartService.loadFeeSettings();
    _loadData();
    _loadAds();
    _fetchLatestWinners();
    // _loadHomeCategories() is already triggered inside _loadData(); the live
    // listener below also delivers the initial value. Calling it again here was
    // a redundant network read on every home open.
    _listenHomeCategories();
    _listenAppControl();
    _startShopStatusRefreshTimer();
    _searchController.addListener(_applyFilter);
    _cartService.addListener(_onCartChanged);
    _connectivity.startListening();
    _connectivity.addListener(_onConnectivityChanged);
    _listenUnreadChats();
  }

  void _listenUnreadChats() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();
    _unreadChatsSub?.cancel();
    _unreadChatsSub = _database.child(CityScopeService.tenantPath('chats/${user.uid}')).onValue.listen((event) {
      int count = 0;
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        
        int getUnreadMessagesCount(Map chatData) {
          final meta = chatData['meta'];
          if (meta is Map && meta['unreadByUser'] == true) {
            final messages = chatData['messages'];
            if (messages is Map) {
              final msgsList = messages.values.toList();
              msgsList.sort((a, b) {
                final tA = (a is Map) ? (a['createdAt'] ?? a['createdAtClient'] ?? 0) : 0;
                final tB = (b is Map) ? (b['createdAt'] ?? b['createdAtClient'] ?? 0) : 0;
                int valA = 0, valB = 0;
                if (tA is int) valA = tA;
                else if (tA is double) valA = tA.toInt();
                else if (tA is String) valA = int.tryParse(tA) ?? 0;
                if (tB is int) valB = tB;
                else if (tB is double) valB = tB.toInt();
                else if (tB is String) valB = int.tryParse(tB) ?? 0;
                return valB.compareTo(valA);
              });
              int threadCount = 0;
              for (var msg in msgsList) {
                if (msg is Map && msg['senderRole'] != 'user') {
                  threadCount++;
                } else if (msg is Map && msg['senderRole'] == 'user') {
                  break;
                }
              }
              return threadCount > 0 ? threadCount : 1;
            }
            return 1;
          }
          return 0;
        }

        if (data.containsKey('meta') || data.containsKey('messages')) {
          count += getUnreadMessagesCount(data);
        } else {
          data.forEach((k, v) {
            if (v is Map) {
              count += getUnreadMessagesCount(v);
            }
          });
        }
      }
      if (mounted) setState(() => _unreadChatCount = count);
    });
  }

  void _startShopStatusRefreshTimer() {
    _shopStatusTimer?.cancel();
    _shopStatusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _adTimer?.cancel();
    _winnerTickerTimer?.cancel();
    _slowImageTimer?.cancel();
    _shopStatusTimer?.cancel();
    _unreadChatsSub?.cancel();
    _appControlSubscription?.cancel();
    _homeCategoriesSub?.cancel();
    _adPageController.dispose();
    _searchController.dispose();
    _cartService.removeListener(_onCartChanged);
    _connectivity.removeListener(_onConnectivityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = DateTime.now();
    if (_lastResumeRefresh != null &&
        now.difference(_lastResumeRefresh!).inSeconds < 20) {
      return;
    }
    _lastResumeRefresh = now;
    _triggerBackgroundRefresh();
  }

  void _onConnectivityChanged() {
    if (mounted) setState(() {});
  }

  String _homeCacheKey(String suffix) {
    final cityKey = CityScopeService.normalizeCityKey(
      CityScopeService.currentCity,
    );
    return 'home_${cityKey}_$suffix';
  }

  Future<void> _clearHomeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_homeCacheKey('timestamp'));
      await prefs.remove(_homeCacheKey('shops'));
      await prefs.remove(_homeCacheKey('items'));
    } catch (_) {}
  }

  Future<bool> _loadHomeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedAt = prefs.getInt(_homeCacheKey('timestamp'));
      if (cachedAt == null) return false;
      final ageMs = DateTime.now().millisecondsSinceEpoch - cachedAt;
      if (ageMs > _homeCacheTtl.inMilliseconds) return false;

      final shopsRaw = prefs.getString(_homeCacheKey('shops'));
      final itemsRaw = prefs.getString(_homeCacheKey('items'));
      if (shopsRaw == null || itemsRaw == null) return false;

      final shops = _decodeCachedList(shopsRaw);
      final items = _decodeCachedList(itemsRaw);
      if (shops.isEmpty && items.isEmpty) return false;

      if (!mounted) return true;
      _slowImageTimer?.cancel();
      setState(() {
        _shops = shops;
        _allMenuItems = items;
        _isLoading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _precacheInitialImages();
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveHomeCache(
    List<Map<String, dynamic>> shops,
    List<Map<String, dynamic>> items,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_homeCacheKey('shops'), jsonEncode(shops));
      await prefs.setString(_homeCacheKey('items'), jsonEncode(items));
      await prefs.setInt(
        _homeCacheKey('timestamp'),
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  List<Map<String, dynamic>> _decodeCachedList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _listenAppControl() async {
    try {
      await CityScopeService.ensureLoaded();
      _appControlSubscription?.cancel();
      _appControlSubscription = _database
          .child(_tenantPath('settings/app-control'))
          .onValue
          .listen((event) {
            if (!mounted) return;
            if (event.snapshot.exists && event.snapshot.value is Map) {
              final data = Map<String, dynamic>.from(
                event.snapshot.value as Map,
              );
              setState(() {
                _loyaltyPointsEnabled = data['loyaltyPointsEnabled'] != false;
                _instantDeliveryEnabled =
                    data['instantDeliveryEnabled'] != false;
              });
            } else {
              setState(() {
                _loyaltyPointsEnabled = true;
                _instantDeliveryEnabled = true;
              });
            }
          });
    } catch (_) {}
  }

  Future<void> _retryNetworkAndReload() async {
    if (_isRetryingNetwork) return;

    setState(() => _isRetryingNetwork = true);
    try {
      await _connectivity.refreshStatus(force: true);

      if (!_connectivity.isConnected) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Still no internet connection. Please try again.'),
              duration: Duration(seconds: 3),
              backgroundColor: Colors.red,
            ),
          );
        return;
      }

      await _loadData(forceRefresh: true);
    } finally {
      if (mounted) {
        setState(() => _isRetryingNetwork = false);
      }
    }
  }

  Future<void> _fetchLatestWinners() async {
    try {
      await CityScopeService.ensureLoaded();
      final snap = await _database
          .child(_tenantPath('weekly-rewards/latest-announcement'))
          .get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final winnersRaw = data['winners'];
        if (winnersRaw is Map) {
          final entries = <Map<String, dynamic>>[];
          winnersRaw.forEach((key, raw) {
            if (raw is Map) {
              entries.add(Map<String, dynamic>.from(raw));
            }
          });
          entries.sort((a, b) {
            final rankA = int.tryParse(a['rank'].toString()) ?? 99;
            final rankB = int.tryParse(b['rank'].toString()) ?? 99;
            return rankA.compareTo(rankB);
          });

          final winnerNames = <String>[];
          for (final e in entries) {
            final name = e['name']?.toString() ?? '';
            final rank = int.tryParse(e['rank'].toString()) ?? 0;
            if (name.isNotEmpty && rank >= 1 && rank <= 3) {
              final emoji = rank == 1 ? '🥇' : (rank == 2 ? '🥈' : '🥉');
              winnerNames.add('$emoji $name');
            }
          }

          if (mounted && winnerNames.isNotEmpty) {
            setState(() {
              _weeklyWinners = winnerNames;
            });
            _startWinnerTicker();
          }
        }
      }
    } catch (_) {}
  }

  void _startWinnerTicker() {
    // The weekly-winner ticker widget is no longer part of the home layout, so
    // the previous 3-second Timer.periodic was calling setState() and rebuilding
    // the ENTIRE home screen every 3 seconds for no visible reason — a constant
    // source of jank. We keep the fetched winner data but no longer schedule the
    // periodic full-screen rebuild.
    _winnerTickerTimer?.cancel();
    _winnerTickerTimer = null;
  }

  Future<void> _loadAds() async {
    try {
      await CityScopeService.ensureLoaded();
      final snap = await _database.child(_tenantPath('settings/ads')).get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final List<Map<String, dynamic>> ads = [];
        Map<String, dynamic>? trendingCardAd;

        for (int i = 0; i < 3; i++) {
          final key = 'ad$i';
          final raw = data[key];
          if (raw is! Map) continue;

          final normalized = _normalizeAdRecord(Map<String, dynamic>.from(raw));
          final enabled = _toBool(normalized['enabled'], fallback: true);
          if (!enabled) continue;
          ads.add(normalized);
        }

        final ad4Raw = data['ad3'];
        if (ad4Raw is Map) {
          final normalized = _normalizeAdRecord(
            Map<String, dynamic>.from(ad4Raw),
          );
          final enabled = _toBool(normalized['enabled'], fallback: true);
          if (enabled) {
            trendingCardAd = normalized;
          }
        }

        // Backward compatibility: if old data used placement on any ad and ad4 is empty.
        if (trendingCardAd == null) {
          for (final value in data.values) {
            if (value is! Map) continue;
            final normalized = _normalizeAdRecord(
              Map<String, dynamic>.from(value),
            );
            final placement = (normalized['placement'] ?? _adPlacementBanner)
                .toString();
            final enabled = _toBool(normalized['enabled'], fallback: true);
            if (enabled && placement == _adPlacementTrendingFirst) {
              trendingCardAd = normalized;
              break;
            }
          }
        }

        if (mounted) {
          setState(() {
            _ads = ads;
            _trendingFirstCardAd = trendingCardAd;
            _currentAdIndex = 0;
          });
          _startAdTimer();
        }
      } else if (mounted) {
        setState(() {
          _ads = [];
          _trendingFirstCardAd = null;
          _currentAdIndex = 0;
        });
      }
    } catch (_) {}
  }

  void _startAdTimer() {
    _adTimer?.cancel();
    if (_ads.length < 2) return;
    _adTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _ads.isEmpty) return;
      final next = (_currentAdIndex + 1) % _ads.length;
      _adPageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  Future<void> _loadData({bool forceRefresh = false}) async {
    await CityScopeService.ensureLoaded();
    unawaited(_loadHomeCategories());
    _currentUser = _authService.currentUser;
    if (_currentUser != null) {
      _userData = await _authService.getUserData(_currentUser!.uid);
    }

    if (!forceRefresh) {
      final loadedFromCache = await _loadHomeCache();
      if (loadedFromCache) {
        final fallback = _allMenuItems
            .where((item) => _isTimeTrendingItem(item))
            .toList();
        await _loadTrendingSnapshot(fallbackItems: fallback);
        _triggerBackgroundRefresh();
        return;
      }
    } else {
      await _clearHomeCache();
    }

    // Show slow-internet warning if data hasn't arrived within 8 seconds
    _slowImageTimer?.cancel();
    _slowImageTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoading) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your internet connection is slow, try another network',
            ),
            duration: Duration(seconds: 4),
            backgroundColor: Color(0xFFFF6B00),
          ),
        );
      }
    });

    try {
      final shopsSnap = await _database
          .child(_tenantPath('shops'))
          .get()
          .timeout(const Duration(seconds: 10));
      List<Map<String, dynamic>> allItems = [];
      List<Map<String, dynamic>> shopsList = [];

      if (shopsSnap.exists) {
        final shopsData = shopsSnap.value as Map<dynamic, dynamic>;
        shopsData.forEach((shopKey, shopVal) {
          final shop = Map<String, dynamic>.from(shopVal);
          if (!_toBool(shop['isVisible'], fallback: true)) {
            return;
          }
          shop['id'] = shopKey;
          shop['imageUrl'] = _resolveImageFromMap(shop);
          shopsList.add(shop);

          // Load menu items from this shop
          if (shop['menu'] != null) {
            final menuData = Map<dynamic, dynamic>.from(shop['menu']);
            menuData.forEach((menuKey, menuVal) {
              final item = Map<String, dynamic>.from(menuVal);
              item['id'] = menuKey;
              item['shopId'] = shopKey;
              item['shopName'] = shop['name'] ?? 'Unknown Shop';
              item['shopCategory'] = shop['category'] ?? 'Other';
              item['imageUrl'] = _resolveImageFromMap(item);
              if (!_isProductVisibleToCustomer(item)) {
                return;
              }
              allItems.add(item);
            });
          }
        });
      }

      shopsList.shuffle();
      allItems.shuffle();
      final homeItems = allItems.where(_isTimeTrendingItem).toList();

      if (mounted) {
        _slowImageTimer?.cancel();
        setState(() {
          _shops = shopsList;
          _allMenuItems = allItems;
          _isLoading = false;
        });
        _saveHomeCache(shopsList, allItems);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _precacheInitialImages();
        });
        await _loadTrendingSnapshot(fallbackItems: homeItems);
      }
    } catch (e) {
      if (mounted) {
        _slowImageTimer?.cancel();
        setState(() {
          _isLoading = false;
        });

        if (!_connectivity.isConnected) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text(
                  'Unable to refresh data. Please check your network and retry.',
                ),
                duration: Duration(seconds: 3),
                backgroundColor: Colors.red,
              ),
            );
        }
      }
    }

    _checkForUnratedOrders();
  }

  Future<void> _checkForUnratedOrders() async {
    if (_currentUser == null) return;
    try {
      final snap = await _database
          .child(_tenantPath('orders/${_currentUser!.uid}'))
          .get();
      if (!snap.exists || snap.value is! Map) return;

      final orders = Map<String, dynamic>.from(snap.value as Map);
      for (final entry in orders.entries) {
        final orderId = entry.key;
        if (entry.value is! Map) continue;
        final orderData = Map<String, dynamic>.from(entry.value as Map);

        final status = (orderData['status'] ?? '').toString().toLowerCase();
        final isRated = orderData['isRated'] == true;
        final shopId = (orderData['shopId'] ?? '').toString();

        if (status == 'delivered' && !isRated && shopId.isNotEmpty) {
          if (!mounted) return;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => RatingDialog(
              orderId: orderId,
              userId: _currentUser!.uid,
              shopId: shopId,
              onSubmitted: () {
                Navigator.pop(ctx);
              },
            ),
          );
          break; // Show one at a time
        }
      }
    } catch (e) {
      debugPrint('Error checking unrated orders: $e');
    }
  }

  String _categoryKey(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('&', 'and')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  bool get _isIslamabadHome =>
      CityScopeService.normalizeCity(CityScopeService.currentCity) ==
      CityScopeService.islamabad;

  String? _defaultAssetForCategory(String label) {
    for (final category in _categories) {
      if ((category['label'] ?? '').toString().toLowerCase() ==
          label.toLowerCase()) {
        return category['imagePath'] as String?;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _parseHomeCategoriesFromSnapshot(
    DataSnapshot snap,
  ) {
    if (!snap.exists || snap.value is! Map) return [];

    final data = Map<String, dynamic>.from(snap.value as Map);
    final parsed = <Map<String, dynamic>>[];

    data.forEach((key, raw) {
      if (raw is! Map) return;
      final record = Map<String, dynamic>.from(raw);
      final label = (record['label'] ?? key).toString().trim();
      if (label.isEmpty) return;

      final imageUrl =
          (record['imageUrl'] ?? record['image'] ?? '').toString().trim();
      parsed.add({
        'key': key.toString(),
        'label': label,
        'imageUrl': imageUrl,
        'imagePath': _defaultAssetForCategory(label),
        'order': record['order'] is int
            ? record['order'] as int
            : int.tryParse(record['order']?.toString() ?? '') ?? 999,
      });
    });

    parsed.sort(
      (a, b) => (a['order'] as int).compareTo(b['order'] as int),
    );
    return parsed;
  }

  List<Map<String, dynamic>> _mergeHomeCategories(
    List<Map<String, dynamic>> remote,
  ) {
    final byKey = <String, Map<String, dynamic>>{};

    for (var i = 0; i < _categories.length; i++) {
      final cat = _categories[i];
      final label = (cat['label'] ?? '').toString();
      if (label.isEmpty) continue;
      final key = _categoryKey(label);
      byKey[key] = {
        'key': key,
        'label': label,
        'imageUrl': '',
        'imagePath': cat['imagePath'],
        'order': i,
      };
    }

    final remoteOnly = <Map<String, dynamic>>[];
    for (final remoteCat in remote) {
      final label = (remoteCat['label'] ?? '').toString().trim();
      if (label.isEmpty) continue;
      if (remoteCat['hidden'] == true) {
        byKey.remove(_categoryKey(label));
        continue;
      }

      final key = (remoteCat['key'] ?? _categoryKey(label)).toString();
      final order = remoteCat['order'] is int
          ? remoteCat['order'] as int
          : int.tryParse(remoteCat['order']?.toString() ?? '') ?? 999;

      if (byKey.containsKey(key)) {
        final existing = byKey[key]!;
        byKey[key] = {
          ...existing,
          'label': label,
          'imageUrl': (remoteCat['imageUrl'] ?? '').toString(),
          'order': order,
        };
      } else {
        remoteOnly.add({
          'key': key,
          'label': label,
          'imageUrl': (remoteCat['imageUrl'] ?? '').toString(),
          'imagePath': _defaultAssetForCategory(label),
          'order': order,
        });
      }
    }

    final merged = <Map<String, dynamic>>[...byKey.values, ...remoteOnly];
    merged.sort(
      (a, b) => (a['order'] as int).compareTo(b['order'] as int),
    );
    return merged;
  }

  Future<void> _loadHomeCategories() async {
    await CityScopeService.ensureLoaded();
    if (!_isIslamabadHome) {
      if (mounted) setState(() => _homeCategories = _categories.toList());
      return;
    }

    try {
      final snap = await _database
          .child(_tenantPath('settings/home-categories'))
          .get();
      final parsed = _parseHomeCategoriesFromSnapshot(snap);
      if (!mounted) return;
      setState(() {
        _homeCategories = _mergeHomeCategories(parsed);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _homeCategories = _mergeHomeCategories(const []));
      }
    }
  }

  Future<void> _listenHomeCategories() async {
    try {
      await CityScopeService.ensureLoaded();
      _homeCategoriesSub?.cancel();
      if (!_isIslamabadHome) return;

      _homeCategoriesSub = _database
          .child(_tenantPath('settings/home-categories'))
          .onValue
          .listen((event) {
            if (!mounted) return;
            final parsed = _parseHomeCategoriesFromSnapshot(event.snapshot);
            setState(() {
              _homeCategories = _mergeHomeCategories(parsed);
            });
          });
    } catch (_) {}
  }

  Widget _buildCategoryThumbnail(Map<String, dynamic> category) {
    final imageUrl = ImageHelper.getDirectImageUrl(
      (category['imageUrl'] ?? '').toString(),
    );
    final imagePath = category['imagePath'] as String?;

    if (imageUrl.isNotEmpty) {
      return ImageHelper.networkImage(
        url: imageUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorWidget: _buildCategoryImagePlaceholder(),
      );
    }

    if (imagePath != null && imagePath.isNotEmpty) {
      return Image.asset(
        imagePath,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildCategoryImagePlaceholder(),
      );
    }

    return _buildCategoryImagePlaceholder();
  }

  Widget _buildCategoryImagePlaceholder() {
    return Container(
      color: const Color(0xFFFFF3EB),
      child: const Icon(
        Icons.grid_view_rounded,
        color: _primary,
        size: 20,
      ),
    );
  }

  Future<void> _precacheInitialImages() async {
    final urls = <String>[];

    for (final shop in _shops.take(5)) {
      final image = _resolveImageFromMap(shop);
      if (image.isNotEmpty) urls.add(image);
    }

    for (final item in _allMenuItems.take(10)) {
      final image = _resolveImageFromMap(item);
      if (image.isNotEmpty) urls.add(image);
    }

    if (urls.isNotEmpty) {
      await ImageHelper.precacheImageUrls(context, urls, limit: 12);
    }
  }

  void _applyFilter() {
    setState(() {
      _filteredItems = _sortTrendingItems(_filterHomeItems(_homeMenuItems));
    });
  }

  bool _isFreeDeliveryItem(Map<String, dynamic> item) {
    return _toBool(item['freeDelivery'], fallback: false) ||
        _toBool(item['deliveryFree'], fallback: false);
  }

  List<Map<String, dynamic>> _sortTrendingItems(
    List<Map<String, dynamic>> items,
  ) {
    final ordered = items.asMap().entries.toList();
    ordered.sort((a, b) {
      final aItem = a.value;
      final bItem = b.value;

      final aFree = _isFreeDeliveryItem(aItem);
      final bFree = _isFreeDeliveryItem(bItem);
      if (aFree != bFree) return aFree ? -1 : 1;

      final aTrending = _isTimeTrendingItem(aItem);
      final bTrending = _isTimeTrendingItem(bItem);
      if (aTrending != bTrending) return aTrending ? -1 : 1;

      return a.key.compareTo(b.key);
    });
    return ordered.map((entry) => entry.value).toList();
  }

  List<Map<String, dynamic>> _filterHomeItems(
    List<Map<String, dynamic>> items,
  ) {
    final query = _searchController.text.toLowerCase();
    return items.where((item) {
      final matchesCategory =
          _selectedCategory == 'All' ||
          (item['shopCategory'] ?? '').toString().toLowerCase().contains(
            _selectedCategory.toLowerCase(),
          ) ||
          (item['name'] ?? '').toString().toLowerCase().contains(
            _selectedCategory.toLowerCase(),
          );
      final matchesQuery =
          query.isEmpty ||
          (item['name'] ?? '').toString().toLowerCase().contains(query) ||
          (item['shopName'] ?? '').toString().toLowerCase().contains(query);
      return matchesCategory && matchesQuery;
    }).toList();
  }

  Map<String, dynamic>? _normalizeTrendingSnapshotItem(
    Map<String, dynamic> raw,
  ) {
    final itemId = (raw['itemId'] ?? raw['productId'] ?? raw['id'] ?? '')
        .toString()
        .trim();
    final shopId = (raw['shopId'] ?? raw['shop_id'] ?? '').toString().trim();
    if (itemId.isEmpty || shopId.isEmpty) return null;

    final name = (raw['name'] ?? raw['title'] ?? '').toString().trim();
    final price = _tryToDouble(raw['price']) ?? 0.0;
    final originalPrice = _tryToDouble(raw['originalPrice']) ?? 0.0;
    final imageUrl = _resolveImageFromMap(raw);

    return {
      'id': itemId,
      'shopId': shopId,
      'shopName': raw['shopName'] ?? raw['shop'] ?? '',
      'shopCategory': raw['shopCategory'] ?? raw['shopType'] ?? '',
      'name': name,
      'price': price,
      'originalPrice': originalPrice,
      'imageUrl': imageUrl,
      'category': raw['category'] ?? raw['type'] ?? '',
      'mealCategory':
          raw['mealCategory'] ?? raw['meal'] ?? raw['mealType'] ?? '',
      'trendingCategory':
          raw['trendingCategory'] ??
          raw['mealCategory'] ??
          raw['category'] ??
          raw['type'] ??
          '',
      'trendingStartTime':
          raw['trendingStartTime'] ?? raw['trendingOpenTime'] ?? '',
      'trendingEndTime':
          raw['trendingEndTime'] ?? raw['trendingCloseTime'] ?? '',
      'trendingEnabled': raw['trendingEnabled'] ?? true,
      'isAvailable': raw['isAvailable'] ?? raw['available'] ?? true,
      'isVisible': raw['isVisible'] ?? true,
      'isTrending': true,
      'tag': raw['tag'] ?? raw['label'] ?? '',
    };
  }

  Future<void> _loadTrendingSnapshot({
    List<Map<String, dynamic>>? fallbackItems,
  }) async {
    try {
      await CityScopeService.ensureLoaded();
      final snap = await _database
          .child(_tenantPath(_trendingSnapshotPath))
          .get()
          .timeout(const Duration(seconds: 6));
      final trending = <Map<String, dynamic>>[];

      if (snap.exists) {
        final raw = snap.value;
        if (raw is List) {
          for (final entry in raw) {
            if (entry is! Map) continue;
            final normalized = _normalizeTrendingSnapshotItem(
              Map<String, dynamic>.from(entry),
            );
            if (normalized != null) trending.add(normalized);
          }
        } else if (raw is Map) {
          final map = Map<dynamic, dynamic>.from(raw);
          for (final entry in map.values) {
            if (entry is! Map) continue;
            final normalized = _normalizeTrendingSnapshotItem(
              Map<String, dynamic>.from(entry),
            );
            if (normalized != null) trending.add(normalized);
          }
        }
      }

      final filteredTrending = trending
          .where((item) => _isTimeTrendingItem(item))
          .toList();
      final fallback = fallbackItems ?? <Map<String, dynamic>>[];

      final merged = <Map<String, dynamic>>[];
      final seen = <String>{};
      void addUnique(Map<String, dynamic> item) {
        final key = '${item['shopId'] ?? ''}|${item['id'] ?? ''}';
        if (key == '|' || seen.contains(key)) return;
        seen.add(key);
        merged.add(item);
      }

      for (final item in filteredTrending) {
        addUnique(item);
      }
      for (final item in fallback) {
        addUnique(item);
      }

      final nextItems = merged.isNotEmpty ? merged : fallback;

      if (mounted) {
        setState(() {
          _homeMenuItems = _sortTrendingItems(nextItems);
          _filteredItems = _sortTrendingItems(_filterHomeItems(nextItems));
        });
      }
    } catch (_) {
      if (fallbackItems != null && mounted) {
        setState(() {
          _homeMenuItems = _sortTrendingItems(fallbackItems);
          _filteredItems = _sortTrendingItems(_filterHomeItems(fallbackItems));
        });
      }
    }
  }

  void _triggerBackgroundRefresh() {
    if (_isBackgroundRefreshing) return;
    _isBackgroundRefreshing = true;
    Future(() async {
      await _loadData(forceRefresh: true);
    }).whenComplete(() {
      _isBackgroundRefreshing = false;
    });
  }

  bool _isTrendingProduct(dynamic value) {
    if (value is bool) return value;
    return value?.toString().toLowerCase() == 'true';
  }

  bool _isTimeTrendingItem(Map<String, dynamic> item) {
    final enabled = item['trendingEnabled'];
    if (enabled is bool && !enabled) return false;
    return CategoryTimingService.isProductTrendingNow(item);
  }

  bool _toBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _isProductVisibleToCustomer(Map<String, dynamic> item) {
    return _toBool(item['isVisible'], fallback: true);
  }

  bool _isCategoryAvailableForItem(Map<String, dynamic> item) {
    final shop = _findShopById(item['shopId']);
    return CategoryTimingService.isCategoryAvailable(
      schedules: shop?['categorySchedules'],
      category: item['category'] ?? item['type'],
    );
  }

  bool _isProductOutOfStock(Map<String, dynamic> item) {
    final manualOutOfStock = _toBool(item['outOfStock'], fallback: false);
    if (manualOutOfStock) return true;

    return !_isCategoryAvailableForItem(item);
  }

  bool _isProductPurchasable(Map<String, dynamic> item) {
    final available = _toBool(
      item['isAvailable'] ?? item['available'],
      fallback: true,
    );
    return _isProductVisibleToCustomer(item) &&
        available &&
        !_isProductOutOfStock(item);
  }

  bool _isShopOpenNow(Map<String, dynamic> shop) {
    if (shop['isOpen'] == false || shop['status'] == 'closed') return false;

    final closedDays =
        (shop['closedDays'] as List?)?.map((e) => e.toString()).toList() ?? [];
    const daysOfWeek = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
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

  Map<String, dynamic>? _findShopById(dynamic shopId) {
    if (shopId == null) return null;
    final target = shopId.toString();
    for (final shop in _shops) {
      if ((shop['id'] ?? '').toString() == target) {
        return shop;
      }
    }
    return null;
  }

  bool _isItemFromOpenShop(Map<String, dynamic> item) {
    final shop = _findShopById(item['shopId']);
    if (shop == null) return true;
    return _isShopOpenNow(shop);
  }

  Map<String, dynamic> _resolveFullItem(Map<String, dynamic> item) {
    final itemId = (item['id'] ?? '').toString();
    final shopId = (item['shopId'] ?? '').toString();
    if (itemId.isEmpty || _allMenuItems.isEmpty) return item;
    for (final existing in _allMenuItems) {
      if ((existing['id'] ?? '').toString() != itemId) continue;
      if (shopId.isNotEmpty &&
          (existing['shopId'] ?? '').toString() != shopId) {
        continue;
      }
      return existing;
    }
    return item;
  }

  void _showShopClosedSnack(Map<String, dynamic> item) {
    if (!mounted) return;
    final shopName = (item['shopName'] ?? 'This shop').toString();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$shopName is closed right now.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
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

  String _resolveImageValue(dynamic raw) {
    if (raw == null) return '';
    return ImageHelper.getDirectImageUrl(raw.toString());
  }

  String _resolveImageFromMap(Map<dynamic, dynamic> data) {
    const keys = <String>[
      'imageUrl',
      'image',
      'logo',
      'imageURL',
      'image_url',
      'bannerImage',
      'bannerUrl',
      'banner_url',
      'url',
      'photoUrl',
      'photoURL',
      'thumbnail',
      'thumbnailUrl',
      'secure_url',
    ];

    for (final key in keys) {
      final value = _resolveImageValue(data[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {
    final normalized = Map<String, dynamic>.from(ad);
    normalized['imageUrl'] = _resolveImageFromMap(normalized);

    final title = (normalized['title'] ?? '').toString().trim();
    if (title.isEmpty) {
      normalized['title'] = (normalized['heading'] ?? '').toString().trim();
    }

    final subtitle = (normalized['subtitle'] ?? '').toString().trim();
    if (subtitle.isEmpty) {
      normalized['subtitle'] = (normalized['description'] ?? '')
          .toString()
          .trim();
    }

    normalized['fit'] = (normalized['fit'] ?? 'cover').toString();
    normalized['alignment'] = (normalized['alignment'] ?? 'center').toString();
    normalized['placement'] = (normalized['placement'] ?? _adPlacementBanner)
        .toString();

    final link =
        (normalized['linkUrl'] ??
                normalized['targetUrl'] ??
                normalized['websiteUrl'] ??
                normalized['instagramUrl'] ??
                normalized['link'] ??
                '')
            .toString()
            .trim();
    normalized['linkUrl'] = link;

    return normalized;
  }

  String _resolveAdLink(Map<String, dynamic> ad) {
    return (ad['linkUrl'] ?? '').toString().trim();
  }

  Future<void> _openAdLink(Map<String, dynamic> ad) async {
    final raw = _resolveAdLink(ad);
    if (raw.isEmpty) return;

    Uri? uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.isEmpty) {
      uri = Uri.tryParse('https://$raw');
    }
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid ad link')));
      return;
    }

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to open ad link')));
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  String _getCityLabel() {
    final raw = (_userData?['userCity'] ?? CityScopeService.currentCity)
        .toString()
        .trim();
    final cityLabel = CityScopeService.cityLabel(raw);

    if (cityLabel.isEmpty) return 'Pakistan';
    // Capitalize first letter of city
    final formattedCity = cityLabel[0].toUpperCase() + cityLabel.substring(1);
    return '$formattedCity, Pakistan';
  }

  String _getUserName() {
    return _userData?['name'] ?? _currentUser?.displayName ?? 'there';
  }

  void _addToCart(Map<String, dynamic> item) async {
    final resolvedItem = _resolveFullItem(item);
    if (!_isItemFromOpenShop(resolvedItem)) {
      _showShopClosedSnack(resolvedItem);
      return;
    }

    if (!_isProductPurchasable(resolvedItem)) {
      final outOfStock = _isProductOutOfStock(resolvedItem);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                outOfStock
                    ? '${resolvedItem['name'] ?? 'This product'} is out of stock.'
                    : '${resolvedItem['name'] ?? 'This product'} is unavailable right now.',
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
      }
      return;
    }

    final cartId = CartService.defaultCartItemId(resolvedItem);
    // Normal browsing always uses the standard cart (instant cart is only for
    // the dedicated Instant Delivery page).
    const cartScope = CartScope.standard;
    final currentQty = _cartService.getItemQuantity(
      cartId,
      scope: cartScope,
    );

    // Show product detail bottom sheet
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProductDetailBottomSheet(
        product: resolvedItem,
        currentQuantity: currentQty,
      ),
    );

    if (result != null) {
      if (!_isItemFromOpenShop(resolvedItem)) {
        _showShopClosedSnack(resolvedItem);
        return;
      }

      final quantity = result['quantity'] as int;
      final variantId = result['variantId'] as String?;
      final size = result['size'] as String?;
      final price = result['price'] as double;

      final resolvedCartId = CartService.resolveCartItemId(
        resolvedItem,
        variantId: variantId,
        size: size,
      );

      final added = _cartService.upsertItem(
        CartItem(
          id: resolvedCartId,
          name: resolvedItem['name'] ?? 'Item',
          shopName: resolvedItem['shopName'] ?? '',
          shopId: resolvedItem['shopId'] ?? '',
          category: (resolvedItem['category'] ?? resolvedItem['type'] ?? '')
              .toString(),
          price: price,
          imageUrl: _resolveImageFromMap(resolvedItem),
          quantity: quantity,
        ),
        scope: cartScope,
      );

      if (!added) return;

      AnalyticsService.addToCart(
        resolvedItem['id']?.toString() ?? '',
        resolvedItem['name']?.toString() ?? 'Item',
        price,
        resolvedItem['shopId']?.toString() ?? '',
      );

      if (mounted) {
        Fluttertoast.showToast(
          msg: '$quantity × ${resolvedItem['name']} added to cart!',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.TOP,
          backgroundColor: _primary,
          textColor: Colors.white,
          fontSize: 13,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIslamabad =
        CityScopeService.normalizeCity(CityScopeService.currentCity) ==
        CityScopeService.islamabad;

    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: isIslamabad
          ? null
          : Stack(
        clipBehavior: Clip.none,
        children: [
          FloatingActionButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const UserChatsListPage(),
                ),
              );
            },
            backgroundColor: Colors.white,
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.support_agent_rounded, color: Colors.blue, size: 32),
          ),
          if (_unreadChatCount > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  _unreadChatCount > 9 ? '9+' : _unreadChatCount.toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverToBoxAdapter(child: _buildHeader()),
                    SliverAppBar(
                      backgroundColor: Colors.white,
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      pinned: true,
                      floating: true,
                      titleSpacing: 0,
                      toolbarHeight: 60,
                      title: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: AnimatedSearchBar(onTap: _showSearchModal),
                      ),
                    ),
                  ];
                },
                body: Container(
                  color: Colors.white,
                  child: RefreshIndicator(
                    color: _primary,
                    onRefresh: () => _loadData(forceRefresh: true),
                    child: _buildFoodGrid(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_rounded,
                          size: 14,
                          color: Colors.black54,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _getCityLabel(),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black54,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _getGreeting(),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_getUserName()} 👋',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_isIslamabadHome && _instantDeliveryEnabled)
                _buildInstantDeliveryButton()
              else ...[
                _buildLoyaltyButton(),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    AnalyticsService.notificationClick(
                      'header_icon',
                      'open_notifications',
                    );
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocalNotificationsPage(),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[200]!),
                    ),
                    child: const Icon(
                      Icons.notifications_none_rounded,
                      color: Colors.black87,
                      size: 22,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CartPage()),
                  );
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[200]!),
                      ),
                      child: const Icon(
                        Icons.shopping_cart_outlined,
                        color: Colors.black87,
                        size: 22,
                      ),
                    ),
                    if (_cartService.itemCount > 0)
                      Positioned(
                        top: -4,
                        right: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${_cartService.itemCount}',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHomeSkeleton() {
    Widget circle(double size) => Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Color(0xFFEDEDED),
            shape: BoxShape.circle,
          ),
        );

    return _Shimmer(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Promo banner
          _skeletonBox(height: 150, radius: 18),
          const SizedBox(height: 22),
          // Categories row (circles + labels)
          SizedBox(
            height: 86,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(
                4,
                (_) => Column(
                  children: [
                    circle(58),
                    const SizedBox(height: 8),
                    _skeletonBox(height: 10, width: 46, radius: 6),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          // Section title
          _skeletonBox(height: 18, width: 180, radius: 8),
          const SizedBox(height: 14),
          // Horizontal rail
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 4,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, __) =>
                  _skeletonBox(height: 150, width: 130, radius: 14),
            ),
          ),
          const SizedBox(height: 24),
          // Recommended grid title
          _skeletonBox(height: 18, width: 150, radius: 8),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 6,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.72,
            ),
            itemBuilder: (_, __) => _buildSkeletonCard(),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeletonCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _skeletonBox(height: 96, radius: 12),
          const SizedBox(height: 10),
          _skeletonBox(height: 12, width: 120, radius: 6),
          const SizedBox(height: 6),
          _skeletonBox(height: 10, width: 80, radius: 6),
          const Spacer(),
          _skeletonBox(height: 14, width: 60, radius: 8),
        ],
      ),
    );
  }

  Widget _skeletonBox({
    required double height,
    double? width,
    double radius = 12,
  }) {
    return Container(
      height: height,
      width: width ?? double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFEDEDED),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  Widget _buildInstantDeliveryButton() {
    final button = ScaleTap(
      onTap: () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const InstantDeliveryPage()),
        );
      },
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFFFF3D00), Color(0xFFFF6B00), Color(0xFFFFB300)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.45),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF6B00).withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
            BoxShadow(
              color: const Color(0xFFFF3D00).withValues(alpha: 0.2),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.22),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.35),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  InstantDeliveryService.headerLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 10.5,
                    height: 1,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  InstantDeliveryService.headerSubtitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 9.5,
                    height: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return button
        .animate(onPlay: (controller) => controller.repeat(reverse: true))
        .shimmer(
          duration: const Duration(milliseconds: 1800),
          color: Colors.white.withValues(alpha: 0.35),
        )
        .scale(
          begin: const Offset(1, 1),
          end: const Offset(1.04, 1.04),
          duration: const Duration(milliseconds: 1400),
          curve: Curves.easeInOut,
        );
  }

  Widget _buildLoyaltyButton() {
    final enabled = _loyaltyPointsEnabled;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? _openLoyaltyPointsPage : null,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: enabled ? _primary.withValues(alpha: 0.1) : Colors.grey[100],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled
                  ? _primary.withValues(alpha: 0.2)
                  : Colors.grey[200]!,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: _primary.withValues(alpha: 0.10),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Icon(
              Icons.loyalty_rounded,
              size: 22,
              color: enabled ? _primary : Colors.grey[400],
            ),
          ),
        ),
      ),
    );
  }

  void _openLoyaltyPointsPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoyaltyPointsPage()),
    );
  }

  void _showSearchModal() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GlobalSearchPage(
          allItems: _allMenuItems,
          shops: _shops,
          primary: _primary,
          initialQuery: _searchController.text.isNotEmpty
              ? _searchController.text
              : null,
        ),
      ),
    ).then((result) {
      if (result != null &&
          result is Map<String, dynamic> &&
          result['type'] == 'shop') {
        final shopData = result['data'] as Map<String, dynamic>;
        // We can navigate to the shop page from here if we want.
        // E.g., Navigator.push(context, MaterialPageRoute(builder: (_) => ShopMenuPage(shop: shopData)));
      }
    });
  }

  Widget _buildFoodGrid() {
    const midAt = 6; // insert mid-banner after this many items
    final items = _filteredItems;
    final firstChunk = items.length > midAt ? items.sublist(0, midAt) : items;
    final secondChunk = items.length > midAt
        ? items.sublist(midAt)
        : <Map<String, dynamic>>[];

    final firstChunkCards = List<Map<String, dynamic>>.from(firstChunk);
    if (_trendingFirstCardAd != null && firstChunkCards.isNotEmpty) {
      firstChunkCards[0] = {'__isAdCard': true, ..._trendingFirstCardAd!};
    }

    // First load (no cache yet): show a full-page shimmer skeleton instead of
    // the half-empty default template, so the screen looks intentional while
    // data arrives. Once loaded (or served from cache) real content shows.
    if (_isLoading) {
      return _buildHomeSkeleton();
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildPromoBanner()),
        SliverToBoxAdapter(child: _buildHomeCategories()),
        SliverToBoxAdapter(child: _buildGroceriesSection()),

        // Hot & Discounts rail: prioritized selection
        SliverToBoxAdapter(child: _buildHotAndDiscounts()),
        if (!_isLoading && items.isNotEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Text(
                'Recommended for you',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ),
          ),
        if (!_isLoading && items.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 24, 12, 4),
              child: Column(
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    size: 64,
                    color: Colors.grey[300],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Trending items abhi available nahi hain',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Banners, reward line aur baaki sections phir bhi visible rahenge.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          )
        else if (_allMenuItems.isEmpty)
          _buildShopsGrid()
        else ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate((context, index) {
                final card = firstChunkCards[index];
                if (card['__isAdCard'] == true) {
                  return _buildTrendingAdCard(card).animateListItem(index: index);
                }
                return _buildFoodCard(card).animateListItem(index: index);
              }, childCount: firstChunkCards.length),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.68,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
            ),
          ),
          if (secondChunk.isNotEmpty) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildFoodCard(secondChunk[index])
                      .animateListItem(index: index + firstChunkCards.length),
                  childCount: secondChunk.length,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.68,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
              ),
            ),
          ] else
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
        ],
      ],
    );
  }

  void _openWeeklyRewardPage() {
    AnalyticsService.promoBannerClick(
      'weekly_reward',
      'Weekly Reward Cashback',
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WeeklyRewardPage()),
    );
  }

  Widget _buildWeeklyRewardTicker() {
    final displayText = _weeklyWinners.isNotEmpty
        ? _weeklyWinners[_currentWinnerIndex]
        : '🏆 Weekly Rewards';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: GestureDetector(
        onTap: _openWeeklyRewardPage,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                  child: Text(
                    displayText,
                    key: ValueKey<String>(displayText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF1A1A1A),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeCategories() {
    final filteredCategories = _homeCategories.where((c) {
      return (c['label'] ?? '').toString().toLowerCase() != 'all';
    }).toList();

    if (filteredCategories.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
      child: SizedBox(
        height: 100,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: filteredCategories.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final category = filteredCategories[index];
            final label = (category['label'] ?? '').toString();

            return ScaleTap(
              onTap: () {
                if (label != 'All') {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          CategoryProductsPage(categoryName: label),
                    ),
                  );
                } else {
                  // If "All" is tapped, we could reset search or do nothing.
                  _searchController.clear();
                  _showSearchModal();
                }
              },
              child: Container(
                width: 80,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                  border: Border.all(color: Colors.black12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildCategoryThumbnail(category),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 2,
                      ),
                      child: Text(
                        label,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ).animateHorizontalItem(index: index);
          },
        ),
      ),
    );
  }

  Widget _buildShopsGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildShopCard(_shops[index]),
          childCount: _shops.length,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 315,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
        ),
      ),
    );
  }

  Widget _buildPromoBanner() {
    if (_ads.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          children: [
            SizedBox(
              height: 140,
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _adPageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _currentAdIndex = i),
                    itemCount: _ads.length,
                    itemBuilder: (_, i) {
                      final ad = _ads[i];
                      final imageUrl = _resolveImageFromMap(ad);
                      final title = (ad['title'] ?? '').toString();
                      final subtitle = (ad['subtitle'] ?? '').toString();
                      final bgColor = _parseColor(ad['bgColor'] ?? '#FF5722');
                      final hasLink = _resolveAdLink(ad).isNotEmpty;

                      return GestureDetector(
                        onTap: hasLink
                            ? () {
                                AnalyticsService.bannerClick(
                                  ad['id']?.toString() ?? i.toString(),
                                  title,
                                );
                                _openAdLink(ad);
                              }
                            : null,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: bgColor,
                            boxShadow: [
                              BoxShadow(
                                color: bgColor.withValues(alpha: 0.3),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Stack(
                              children: [
                                if (imageUrl.isNotEmpty)
                                  Positioned.fill(
                                    child: ImageHelper.networkImage(
                                      url: imageUrl,
                                      fit: _parseFit((ad['fit'] as String?)),
                                      alignment: _parseAlignment(
                                        (ad['alignment'] as String?),
                                      ),
                                      errorWidget: const SizedBox.shrink(),
                                    ),
                                  ),
                                // Gradient overlay only when there is text to show
                                if (title.isNotEmpty || subtitle.isNotEmpty)
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Colors.black.withValues(
                                              alpha: 0.52,
                                            ),
                                            Colors.transparent,
                                          ],
                                          begin: Alignment.centerLeft,
                                          end: Alignment.centerRight,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (title.isNotEmpty || subtitle.isNotEmpty)
                                  Positioned(
                                    left: 18,
                                    top: 0,
                                    bottom: 0,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (subtitle.isNotEmpty)
                                          Text(
                                            subtitle,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        if (title.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_ads.length, (i) {
                        final isActive = i == _currentAdIndex;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: isActive ? 18 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: isActive
                                ? _primary
                                : Colors.white.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // Fallback: static banner
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Container(
        height: 128,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFF6B00), Color(0xFFFF8A65)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF6B00).withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: -16,
              bottom: -16,
              child: Icon(
                Icons.restaurant,
                size: 110,
                color: Colors.white.withValues(alpha: 0.15),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'LIMITED OFFER',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '50% OFF',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    'On your first order!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHotAndDiscounts() {
    final visible = _allMenuItems.where(_isProductVisibleToCustomer).toList();

    final discounted = <Map<String, dynamic>>[];
    final hot = <Map<String, dynamic>>[];

    for (final item in visible) {
      final price = _tryToDouble(item['price']) ?? 0.0;
      final original = _tryToDouble(item['originalPrice']) ?? 0.0;
      
      bool isDiscounted = item['isDiscount'] == true || (original > 0 && original > price);
      bool isHotItem = item['isHot'] == true || (item['tag'] ?? '').toString().toLowerCase().contains('hot');

      if (isDiscounted) {
        discounted.add(item);
      } 
      if (isHotItem && !isDiscounted) {
        hot.add(item);
      }
    }

    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    void addUnique(Map<String, dynamic> it) {
      final key = '${it['shopId'] ?? ''}|${it['id'] ?? ''}';
      if (key == '|' || seen.contains(key)) return;
      seen.add(key);
      merged.add(it);
    }

    for (final it in discounted) addUnique(it);
    for (final it in hot) addUnique(it);

    final shown = merged.take(8).toList();

    if (shown.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Hot & Discounts',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                GestureDetector(
                  onTap: () {},
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'See all',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: shown.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final item = shown[i];
                return SizedBox(
                  width: 140,
                  height: 200,
                  child: _buildFoodCard(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroceriesSection() {
    final visible = _allMenuItems.where(_isProductVisibleToCustomer).toList();

    final groceriesItems = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final item in visible) {
      final cat = (item['category'] ?? item['type'] ?? '')
          .toString()
          .toLowerCase();
      final shopCat = (item['shopCategory'] ?? '').toString().toLowerCase();
      if (cat == 'groceries' || shopCat == 'groceries') {
        final key = '${item['shopId'] ?? ''}|${item['id'] ?? ''}';
        if (key != '|' && !seen.contains(key)) {
          seen.add(key);
          groceriesItems.add(item);
        }
      }
    }

    if (groceriesItems.isEmpty) return const SizedBox.shrink();

    // Optionally sort or limit
    final shown = groceriesItems.take(8).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Groceries',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const CategoryProductsPage(
                          categoryName: 'Groceries',
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'See all',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: shown.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final item = shown[i];
                return SizedBox(
                  width: 140,
                  height: 200,
                  child: _buildFoodCard(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  BoxFit _parseFit(String? fit) {
    switch (fit) {
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

  Widget _buildTrendingAdCard(Map<String, dynamic> ad) {
    final imageUrl = _resolveImageFromMap(ad);
    final title = (ad['title'] ?? 'Sponsored').toString().trim();
    final subtitle = (ad['subtitle'] ?? '').toString().trim();
    final hasLink = _resolveAdLink(ad).isNotEmpty;

    return GestureDetector(
      onTap: () => _openAdLink(ad),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
          border: Border.all(color: Colors.orange.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    child: SizedBox.expand(
                      child: imageUrl.isNotEmpty
                          ? ImageHelper.networkImage(
                              url: imageUrl,
                              fit: _parseFit((ad['fit'] as String?)),
                              alignment: _parseAlignment(
                                (ad['alignment'] as String?),
                              ),
                              errorWidget: Container(
                                color: Colors.orange[50],
                                child: const Center(
                                  child: Icon(
                                    Icons.campaign_rounded,
                                    color: _primary,
                                    size: 38,
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              color: Colors.orange[50],
                              child: const Center(
                                child: Icon(
                                  Icons.campaign_rounded,
                                  color: _primary,
                                  size: 38,
                                ),
                              ),
                            ),
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
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'AD',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? 'Sponsored' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle.isEmpty ? 'Tap to view promotion' : subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: hasLink ? _primary : Colors.grey[400],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        hasLink ? 'Visit' : 'No Link',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Alignment _parseAlignment(String? al) {
    switch (al) {
      case 'top':
        return Alignment.topCenter;
      case 'bottom':
        return Alignment.bottomCenter;
      case 'topLeft':
        return Alignment.topLeft;
      case 'topRight':
        return Alignment.topRight;
      default:
        return Alignment.center;
    }
  }

  Color _parseColor(String hexColor) {
    try {
      final hex = hexColor.replaceAll('#', '');
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) {
      return _primary;
    }
  }

  Widget _buildFoodCard(Map<String, dynamic> item) {
    final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0.0;
    final originalPrice =
        double.tryParse(item['originalPrice']?.toString() ?? '0') ?? 0.0;
    final imageUrl = _resolveImageFromMap(item);
    final qty = _cartService.getItemQuantity(
      CartService.defaultCartItemId(item),
      scope: CartScope.standard,
    );
    final shopIsOpen = _isItemFromOpenShop(item);
    final isHot = (item['tag'] ?? '').toString().toLowerCase().contains('hot');
    final isFreeDelivery = _isFreeDeliveryItem(item);
    final outOfStock = _isProductOutOfStock(item);
    final canOrder = _isProductPurchasable(item) && shopIsOpen;

    return ScaleTap(
      onTap: () => _addToCart(item),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.black12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 3),
              spreadRadius: 0,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  if (isFreeDelivery)
                    Positioned(
                      left: -8,
                      top: 18,
                      bottom: 18,
                      child: Container(
                        width: 16,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFFFF1C9).withValues(alpha: 0.95),
                              const Color(0xFFFF6B00).withValues(alpha: 0.35),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: BorderRadius.circular(99),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFFFB14A,
                              ).withValues(alpha: 0.45),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (isFreeDelivery)
                    Positioned(
                      right: -8,
                      top: 18,
                      bottom: 18,
                      child: Container(
                        width: 16,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFFFF1C9).withValues(alpha: 0.95),
                              const Color(0xFFFF6B00).withValues(alpha: 0.35),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: BorderRadius.circular(99),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFFFB14A,
                              ).withValues(alpha: 0.45),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    child: SizedBox.expand(
                      child: imageUrl.isNotEmpty
                          ? ImageHelper.networkImage(
                              url: imageUrl,
                              fit: BoxFit.cover,
                              errorWidget: Container(
                                color: Colors.orange[50],
                                child: const Center(
                                  child: Icon(
                                    Icons.restaurant,
                                    color: Color(0xFFFF6B00),
                                    size: 40,
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              color: Colors.orange[50],
                              child: const Center(
                                child: Icon(
                                  Icons.restaurant,
                                  color: Color(0xFFFF6B00),
                                  size: 40,
                                ),
                              ),
                            ),
                    ),
                  ),
                  if (isHot)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red[600],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'HOT',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                  if (isFreeDelivery)
                    Positioned(
                      top: 8,
                      left: 6,
                      right: 6,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF6B00),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFFFF6B00,
                                  ).withValues(alpha: 0.35),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Text(
                              'FREE DELIVERY',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!shopIsOpen)
                    Positioned(
                      top: 8,
                      right: 6,
                      left: 6,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red[700],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'SHOP IS CLOSED',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else if (outOfStock || !canOrder)
                    Positioned(
                      top: 8,
                      right: 6,
                      left: 6,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: outOfStock
                                  ? Colors.red[700]
                                  : Colors.grey[700],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              outOfStock ? 'OUT OF STOCK' : 'UNAVAILABLE',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['name'] ?? 'Item',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item['shopName'] ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Rs. ${price.toStringAsFixed(0)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFFF6B00),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              if (originalPrice > 0 && originalPrice > price)
                                Text(
                                  'Rs. ${originalPrice.toStringAsFixed(0)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey[600],
                                    decoration: TextDecoration.lineThrough,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        !canOrder
                            ? Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[300],
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'Unavailable',
                                      style: TextStyle(
                                        color: Colors.grey[700],
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            : Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: GestureDetector(
                                    onTap: () => _addToCart(item),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _primary,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        qty > 0 ? '$qty Added' : '+ Add',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildStarRating(double rating) {
    final full = rating.floor();
    final half = (rating - full) >= 0.5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        if (i < full)
          return const Icon(
            Icons.star_rounded,
            size: 12,
            color: Color(0xFFFFB300),
          );
        if (i == full && half)
          return const Icon(
            Icons.star_half_rounded,
            size: 12,
            color: Color(0xFFFFB300),
          );
        return const Icon(
          Icons.star_border_rounded,
          size: 12,
          color: Color(0xFFFFB300),
        );
      }),
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
    }

    return Container(
      color: bgColor,
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 40))),
    );
  }

  Widget _buildShopCard(Map<String, dynamic> shop) {
    final imageUrl = _resolveImageFromMap(shop);
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
    final showDeliveryFee =
        shopDeliveryFee != null &&
        (shopDeliveryFee - standardFeeBase).abs() >= 0.01;

    void openMenu() {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ShopMenuPage(shop: shop)),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: openMenu,
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
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                    child: AspectRatio(
                      aspectRatio: 1 / 1,
                      child: imageUrl.isNotEmpty
                          ? ImageHelper.networkImage(
                              url: imageUrl,
                              fit: _parseFit(shop['imageFit']?.toString()),
                            )
                          : _buildShopImagePlaceholder(category),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isOpen ? Colors.green : Colors.red,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        isOpen ? 'Open' : 'Closed',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
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
                          Text(
                            rating,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.access_time_rounded,
                            size: 12,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${deliveryTime}m',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                            ),
                          ),
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
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: openMenu,
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: Colors.grey.shade300),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                'Menu',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                          ),
                          if (dealsCount > 0) ...[
                            const SizedBox(width: 6),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ShopDealsPage(shop: shop),
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFFF6B00),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  elevation: 0,
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text(
                                  'Deals',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
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
}

class _MovingRewardLine extends StatefulWidget {
  const _MovingRewardLine({
    required this.text,
    required this.onTap,
    required this.primary,
  });

  final String text;
  final VoidCallback onTap;
  final Color primary;

  @override
  State<_MovingRewardLine> createState() => _MovingRewardLineState();
}

class _MovingRewardLineState extends State<_MovingRewardLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 11),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _measureTextWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  Widget _tickerText(String text, TextStyle style) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.visible,
      softWrap: false,
      style: style,
    );
  }

  @override
  Widget build(BuildContext context) {
    const movingStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w800,
      fontSize: 13,
    );

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [widget.primary, const Color(0xFFFF8A3D)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: widget.primary.withValues(alpha: 0.24),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(
              Icons.emoji_events_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 28.0;
                  final textWidth = _measureTextWidth(widget.text, movingStyle);
                  final minSegment = constraints.maxWidth + gap;
                  final naturalSegment = textWidth + gap;
                  final segmentWidth = naturalSegment < minSegment
                      ? minSegment
                      : naturalSegment;

                  return ClipRect(
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (_, __) {
                        final shiftX = -(_controller.value * segmentWidth);

                        return Transform.translate(
                          offset: Offset(shiftX, 0),
                          child: SizedBox(
                            width: segmentWidth * 3,
                            child: Row(
                              children: [
                                _tickerText(widget.text, movingStyle),
                                const SizedBox(width: gap),
                                _tickerText(widget.text, movingStyle),
                                const SizedBox(width: gap),
                                _tickerText(widget.text, movingStyle),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

// ── Search Modal ─────────────────────────────────────────────────────────────
class _SearchModal extends StatefulWidget {
  final List<Map<String, dynamic>> allItems;
  final List<Map<String, dynamic>> categories;
  final void Function(Map<String, dynamic>) onAddToCart;
  final List<Map<String, dynamic>> shops;
  final Color primary;

  const _SearchModal({
    required this.allItems,
    required this.categories,
    required this.onAddToCart,
    required this.shops,
    required this.primary,
  });

  @override
  State<_SearchModal> createState() => _SearchModalState();
}

class _SearchModalState extends State<_SearchModal> {
  final TextEditingController _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  String _selectedCategory = 'All';

  String _resolveImageValue(dynamic raw) {
    if (raw == null) return '';
    return ImageHelper.getDirectImageUrl(raw.toString());
  }

  String _resolveImageFromMap(Map<dynamic, dynamic> data) {
    const keys = <String>[
      'thumbnailUrl',
      'thumbnail',
      'thumb',
      'imageUrl',
      'image',
      'logo',
      'imageURL',
      'image_url',
      'bannerImage',
      'bannerUrl',
      'banner_url',
      'url',
      'photoUrl',
      'photoURL',
      'thumbnailUrl',
      'secure_url',
    ];

    for (final key in keys) {
      final value = _resolveImageValue(data[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  bool _toBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  bool _isProductVisibleToCustomer(Map<String, dynamic> item) {
    return _toBool(item['isVisible'], fallback: true);
  }

  bool _isCategoryAvailableForItem(Map<String, dynamic> item) {
    final shop = _findShopById(item['shopId']);
    return CategoryTimingService.isCategoryAvailable(
      schedules: shop?['categorySchedules'],
      category: item['category'] ?? item['type'],
    );
  }

  bool _isProductOutOfStock(Map<String, dynamic> item) {
    final manualOutOfStock = _toBool(item['outOfStock'], fallback: false);
    if (manualOutOfStock) return true;

    return !_isCategoryAvailableForItem(item);
  }

  bool _isProductPurchasable(Map<String, dynamic> item) {
    final available = _toBool(
      item['isAvailable'] ?? item['available'],
      fallback: true,
    );
    return _isProductVisibleToCustomer(item) &&
        available &&
        !_isProductOutOfStock(item);
  }

  Map<String, dynamic>? _findShopById(dynamic shopId) {
    if (shopId == null) return null;
    final target = shopId.toString();
    for (final shop in widget.shops) {
      if ((shop['id'] ?? '').toString() == target) {
        return shop;
      }
    }
    return null;
  }

  bool _isItemFromOpenShop(Map<String, dynamic> item) {
    final shop = _findShopById(item['shopId']);
    if (shop == null) return true;
    return _isShopOpenNow(shop);
  }

  bool _isShopOpenNow(Map<String, dynamic> shop) {
    if (shop['isOpen'] == false || shop['status'] == 'closed') return false;

    final closedDays =
        (shop['closedDays'] as List?)?.map((e) => e.toString()).toList() ?? [];
    const daysOfWeek = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final todayName = daysOfWeek[DateTime.now().weekday - 1];
    if (closedDays.contains(todayName)) {
      return false;
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

  @override
  void initState() {
    super.initState();
    _results = widget.allItems.where(_isProductVisibleToCustomer).toList();
    _ctrl.addListener(_filter);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_filter);
    _ctrl.dispose();
    super.dispose();
  }

  void _filter() {
    final q = _ctrl.text.toLowerCase();
    setState(() {
      _results = widget.allItems.where((item) {
        if (!_isProductVisibleToCustomer(item)) {
          return false;
        }
        final matchCat =
            _selectedCategory == 'All' ||
            (item['shopCategory'] ?? '').toString().toLowerCase().contains(
              _selectedCategory.toLowerCase(),
            ) ||
            (item['name'] ?? '').toString().toLowerCase().contains(
              _selectedCategory.toLowerCase(),
            );
        final matchQ =
            q.isEmpty ||
            (item['name'] ?? '').toString().toLowerCase().contains(q) ||
            (item['shopName'] ?? '').toString().toLowerCase().contains(q);
        return matchCat && matchQ;
      }).toList();
    });
  }

  void _selectCategory(String cat) {
    _selectedCategory = cat;
    _filter();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      maxChildSize: 0.97,
      minChildSize: 0.5,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: TextField(
                        controller: _ctrl,
                        autofocus: true,
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            AnalyticsService.search(
                              val.trim(),
                              _results.length,
                            );
                          }
                        },
                        decoration: InputDecoration(
                          hintText: 'Burger, Biryani, Pizza...',
                          hintStyle: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 14,
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: widget.primary,
                            size: 20,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: widget.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Category filter chips
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: widget.categories.length,
                itemBuilder: (_, i) {
                  final cat = widget.categories[i];
                  final isSelected = _selectedCategory == cat['label'];
                  return GestureDetector(
                    onTap: () => _selectCategory(cat['label']),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? widget.primary
                            : const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            cat['icon'] as IconData,
                            size: 13,
                            color: isSelected ? Colors.white : Colors.grey[600],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            cat['label'],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Divider(color: Colors.grey[100], height: 1),
            // Results
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.search_off_rounded,
                            size: 56,
                            color: Colors.grey[300],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Koi cheez nahi mili',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Alag naam try karein',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.only(bottom: 40),
                      itemCount: _results.length,
                      itemBuilder: (_, i) {
                        final item = _results[i];
                        final price =
                            double.tryParse(item['price']?.toString() ?? '0') ??
                            0.0;
                        final imageUrl = _resolveImageFromMap(item);
                        final outOfStock = _isProductOutOfStock(item);
                        final shopIsOpen = _isItemFromOpenShop(item);
                        final canOrder =
                            _isProductPurchasable(item) && shopIsOpen;
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          leading: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.orange[50],
                            ),
                            child: imageUrl.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: ImageHelper.networkImage(
                                      url: imageUrl,
                                      fit: BoxFit.cover,
                                      errorWidget: Icon(
                                        Icons.fastfood,
                                        color: widget.primary,
                                      ),
                                    ),
                                  )
                                : Icon(Icons.fastfood, color: widget.primary),
                          ),
                          title: Text(
                            item['name'] ?? 'Item',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            !shopIsOpen
                                ? '${item['shopName'] ?? ''} • Shop is Closed'
                                : outOfStock
                                ? '${item['shopName'] ?? ''} • Out of Stock'
                                : (item['shopName'] ?? ''),
                            style: TextStyle(
                              fontSize: 12,
                              color: (!shopIsOpen || outOfStock)
                                  ? Colors.red[700]
                                  : Colors.grey[600],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          trailing: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Rs. ${price.toStringAsFixed(0)}',
                                style: TextStyle(
                                  color: widget.primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              canOrder
                                  ? GestureDetector(
                                      onTap: () {
                                        Navigator.pop(context);
                                        WidgetsBinding.instance
                                            .addPostFrameCallback((_) {
                                              widget.onAddToCart(item);
                                            });
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.only(top: 4),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: widget.primary,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: const Text(
                                          'Add',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      margin: const EdgeInsets.only(top: 4),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.grey[300],
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        !shopIsOpen
                                            ? 'Closed'
                                            : (outOfStock ? 'Out' : 'NA'),
                                        style: TextStyle(
                                          color: Colors.grey[700],
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
