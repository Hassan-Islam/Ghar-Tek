import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../services/cart_service.dart';
import '../services/instant_delivery_service.dart';
import '../services/category_timing_service.dart';
import '../services/city_scope_service.dart';
import '../services/location_service.dart';
import '../services/loyalty_service.dart';
import '../widgets/delivery_speed_card.dart';
import '../services/image_helper.dart';
import '../services/notification_service.dart';
import 'order_success_page.dart';
import '../services/shops_cache_service.dart';
import '../services/analytics_service.dart';

class CheckoutPage extends StatefulWidget {
  final CartScope cartScope;

  const CheckoutPage({super.key, this.cartScope = CartScope.standard});

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const String _defaultAdMobRewardedAdUnitId =
      'ca-app-pub-6268553487157911/9854686784';
  static const String _otherOptionLabel = 'Other';

  final CartService _cartService = CartService();
  CartScope get _scope => widget.cartScope;
  List<CartItem> get _items => _cartService.itemsFor(_scope);
  final LoyaltyService _loyaltyService = LoyaltyService();
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final TextEditingController _instructionsController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _promoController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _address2Controller = TextEditingController();
  final TextEditingController _otherHostelCtrl = TextEditingController();
  final TextEditingController _otherRoomCtrl = TextEditingController();
  final TextEditingController _otherDepartmentCtrl = TextEditingController();

  String _paymentMethod = 'Cash on Delivery';
  bool _isPlacingOrder = false;
  bool _promoExpanded = false;
  double? _latitude;
  double? _longitude;

  // Silent GPS — fetched in background, saved with order for rider navigation
  String _autoAddress = '';
  double? _autoLatitude;
  double? _autoLongitude;

  // Promo code state
  String? _appliedPromoCode;
  double _promoDiscount = 0.0;
  bool _promoLoading = false;
  String? _promoError;

  // Weekly winner voucher (auto-applied)
  String? _activeWeeklyVoucherId;
  String? _activeWeeklyVoucherWeekKey;
  double _weeklyRewardDiscount = 0.0;
  String? _weeklyRewardLabel;
  bool _weeklyRewardLoading = false;

  // Rewarded ad state for loyalty points
  bool _adMobInitialized = false;
  RewardedAd? _rewardedAd;
  bool _rewardedAdLoaded = false;
  bool _isLoadingRewardedAd = false;
  String? _rewardAdError;
  String _adMobRewardedAdUnitId = _defaultAdMobRewardedAdUnitId;

  // Admin-controlled payment methods
  List<Map<String, dynamic>> _paymentMethods = [];
  bool _isIslamabadCheckout = false;
  bool _hostelOptionsLoading = true;
  String _selectedHostelType = 'boys';
  String _selectedHostel = '';
  String _selectedRoom = '';
  String _selectedDepartment = '';
  List<String> _boysHostels = [];
  List<String> _girlsHostels = [];
  List<String> _boysRooms = [];
  List<String> _girlsRooms = [];
  List<String> _departments = [];
  bool _checkoutInstructionEnabled = false;
  bool _loyaltyPointsEnabled = true;
  int _loyaltyPoints = 0;
  int _loyaltyFreeDeliveryCredits = 0;
  StreamSubscription<DatabaseEvent>? _loyaltySubscription;
  String _checkoutInstructionMessage = '';
  StreamSubscription<DatabaseEvent>? _appControlSubscription;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  bool get _isAndroidRewardFlowEnabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    AnalyticsService.checkoutVisit(
      _cartService.itemCountFor(_scope),
      _cartService.subtotalFor(_scope),
    );
    _loadCityMode();
    _cartService.addListener(_onCartChanged);
    _instructionsController.text = _cartService.deliveryInstructionsFor(_scope);
    _cartService.loadFeeSettings();
    _cartService.startFeeListener();
    _loadUserProfile();
    _silentlyFetchGps();
    _loadPaymentMethods();
    _loadCheckoutInstruction();
    _loadActiveWeeklyRewardVoucher();
    _listenLoyaltyPoints();
    ShopsCacheService.instance.warmUp();
  }

  Future<void> _loadCityMode() async {
    await CityScopeService.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _isIslamabadCheckout =
          CityScopeService.normalizeCity(CityScopeService.currentCity) ==
          CityScopeService.islamabad;
    });
    await _loadHostelOptions();
  }

  void _onCartChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _cartService.removeListener(_onCartChanged);
    _cartService.stopFeeListener();
    _instructionsController.dispose();
    _addressController.dispose();
    _promoController.dispose();
    _phoneController.dispose();
    _nameController.dispose();
    _address2Controller.dispose();
    _otherHostelCtrl.dispose();
    _otherRoomCtrl.dispose();
    _otherDepartmentCtrl.dispose();
    _appControlSubscription?.cancel();
    _loyaltySubscription?.cancel();
    _rewardedAd?.dispose();
    super.dispose();
  }

  bool get _isLoyaltyFreeDeliveryActive =>
      _loyaltyPointsEnabled && _loyaltyFreeDeliveryCredits > 0;
  double _effectiveDeliveryFee() {
    if (_cartService.isFreeDeliveryAppliedFor(_scope) ||
        _isLoyaltyFreeDeliveryActive) {
      return 0.0;
    }
    return _cartService.deliveryFeeFor(_scope).clamp(0.0, double.infinity);
  }

  double _baseTotalBeforeDiscounts() {
    return _cartService.subtotalFor(_scope) +
        _effectiveDeliveryFee() +
        _cartService.taxFor(_scope) +
        _cartService.totalExtraChargeFor(_scope);
  }

  Future<void> _initAdMobRewardedAds() async {
    if (!_isAndroidRewardFlowEnabled) return;

    try {
      await MobileAds.instance.initialize();
      if (!mounted) return;
      setState(() {
        _adMobInitialized = true;
        _rewardAdError = null;
      });
      _loadRewardedAd(forceReload: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _adMobInitialized = false;
        _rewardedAdLoaded = false;
        _isLoadingRewardedAd = false;
        _rewardAdError = 'Unable to initialize ads on this device.';
      });
    }
  }

  void _loadRewardedAd({bool forceReload = false}) {
    if (!_adMobInitialized ||
        _isLoadingRewardedAd ||
        !_isAndroidRewardFlowEnabled) {
      return;
    }
    if (!forceReload && _rewardedAdLoaded && _rewardedAd != null) {
      return;
    }

    _rewardedAd?.dispose();
    _rewardedAd = null;

    setState(() {
      _isLoadingRewardedAd = true;
      _rewardedAdLoaded = false;
      _rewardAdError = null;
    });

    RewardedAd.load(
      adUnitId: _adMobRewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() {
            _rewardedAd = ad;
            _rewardedAdLoaded = true;
            _isLoadingRewardedAd = false;
            _rewardAdError = null;
          });
        },
        onAdFailedToLoad: (error) {
          if (!mounted) return;
          setState(() {
            _rewardedAd = null;
            _rewardedAdLoaded = false;
            _isLoadingRewardedAd = false;
            _rewardAdError = 'Rewarded ad not available right now.';
          });
        },
      ),
    );
  }

  Future<void> _loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap = await _database.child('users/${user.uid}').get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final phone = (data['phoneNumber'] ?? '').toString().trim();
        final name = (data['name'] ?? '').toString().trim();
        final address = (data['address'] ?? '').toString().trim();
        if (mounted) {
          setState(() {
            _phoneController.text = phone;
            _nameController.text = name;
            if (address.isNotEmpty) {
              _addressController.text = address;
            }
          });
        }

        final hostelData = data['checkoutHostel'];
        if (_isIslamabadCheckout && hostelData is Map && mounted) {
          setState(() {
            _applySavedHostelSelection(
              Map<String, dynamic>.from(hostelData as Map),
            );
          });
        }
      }
    } catch (_) {}
  }

  List<String> _normalizeStringList(dynamic raw) {
    final items = <String>[];
    if (raw is List) {
      for (final value in raw) {
        final text = value?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        items.add(text);
      }
    } else if (raw is Map) {
      for (final value in raw.values) {
        final text = value?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        items.add(text);
      }
    }
    final seen = <String>{};
    final cleaned = <String>[];
    for (final item in items) {
      final key = item.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      cleaned.add(item);
    }
    return cleaned;
  }

  List<String> _hostelsForType(String type) {
    return type == 'girls' ? _girlsHostels : _boysHostels;
  }

  List<String> _roomsForType(String type) {
    if (type == 'department') return const <String>[];
    return type == 'girls' ? _girlsRooms : _boysRooms;
  }

  List<String> _departmentOptions() {
    return _departments;
  }

  Future<void> _loadHostelOptions() async {
    if (!_isIslamabadCheckout) {
      if (mounted) setState(() => _hostelOptionsLoading = false);
      return;
    }
    try {
      final snap = await _database
          .child(_tenantPath('settings/checkout-hostel-options'))
          .get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final boys = data['boys'];
        final girls = data['girls'];
        final boysMap = boys is Map ? Map<String, dynamic>.from(boys) : <String, dynamic>{};
        final girlsMap = girls is Map ? Map<String, dynamic>.from(girls) : <String, dynamic>{};
        _boysHostels = _normalizeStringList(boysMap['hostels']);
        _girlsHostels = _normalizeStringList(girlsMap['hostels']);
        _boysRooms = _normalizeStringList(boysMap['rooms']);
        _girlsRooms = _normalizeStringList(girlsMap['rooms']);
        _departments = _normalizeStringList(data['departments']);
      } else {
        _boysHostels = [];
        _girlsHostels = [];
        _boysRooms = [];
        _girlsRooms = [];
        _departments = [];
      }
    } catch (_) {
      _boysHostels = [];
      _girlsHostels = [];
      _boysRooms = [];
      _girlsRooms = [];
      _departments = [];
    }

    if (mounted) {
      setState(() {
        _hostelOptionsLoading = false;
        _ensureHostelDefaults();
      });
    }
  }

  void _ensureHostelDefaults() {
    if (_selectedHostelType == 'department') {
      final departments = _departmentOptions();
      if (_selectedDepartment.isEmpty) {
        _selectedDepartment =
            departments.isNotEmpty ? departments.first : _otherOptionLabel;
      }
      return;
    }

    final hostels = _hostelsForType(_selectedHostelType);
    final rooms = _roomsForType(_selectedHostelType);
    if (_selectedHostel.isEmpty) {
      _selectedHostel = hostels.isNotEmpty ? hostels.first : _otherOptionLabel;
    }
    if (_selectedRoom.isEmpty) {
      _selectedRoom = rooms.isNotEmpty ? rooms.first : _otherOptionLabel;
    }
  }

  void _applySavedHostelSelection(Map<String, dynamic> data) {
    final type = (data['hostelType'] ?? '').toString().trim().toLowerCase();
    if (type == 'boys' || type == 'girls' || type == 'department') {
      _selectedHostelType = type;
    }

    final savedHostel = (data['hostelName'] ?? '').toString().trim();
    final savedRoom = (data['roomNumber'] ?? '').toString().trim();
    final savedDepartment = (data['departmentName'] ?? '').toString().trim();
    final hostelOther = (data['hostelOther'] ?? '').toString().trim();
    final roomOther = (data['roomOther'] ?? '').toString().trim();
    final departmentOther = (data['departmentOther'] ?? '').toString().trim();

    if (_selectedHostelType == 'department') {
      final departments = _departmentOptions();
      if (departmentOther.isNotEmpty ||
          (savedDepartment.isNotEmpty && !departments.contains(savedDepartment))) {
        _selectedDepartment = _otherOptionLabel;
        _otherDepartmentCtrl.text =
            departmentOther.isNotEmpty ? departmentOther : savedDepartment;
      } else {
        _selectedDepartment =
            savedDepartment.isNotEmpty ? savedDepartment : _selectedDepartment;
      }
      return;
    }

    final hostels = _hostelsForType(_selectedHostelType);
    final rooms = _roomsForType(_selectedHostelType);

    if (hostelOther.isNotEmpty || (savedHostel.isNotEmpty && !hostels.contains(savedHostel))) {
      _selectedHostel = _otherOptionLabel;
      _otherHostelCtrl.text = hostelOther.isNotEmpty ? hostelOther : savedHostel;
    } else {
      _selectedHostel = savedHostel.isNotEmpty ? savedHostel : _selectedHostel;
    }

    if (roomOther.isNotEmpty || (savedRoom.isNotEmpty && !rooms.contains(savedRoom))) {
      _selectedRoom = _otherOptionLabel;
      _otherRoomCtrl.text = roomOther.isNotEmpty ? roomOther : savedRoom;
    } else {
      _selectedRoom = savedRoom.isNotEmpty ? savedRoom : _selectedRoom;
    }
  }

  String _resolveSelectedHostelName() {
    if (_selectedHostel == _otherOptionLabel) {
      return _otherHostelCtrl.text.trim();
    }
    return _selectedHostel.trim();
  }

  String _resolveSelectedRoomName() {
    if (_selectedRoom == _otherOptionLabel) {
      return _otherRoomCtrl.text.trim();
    }
    return _selectedRoom.trim();
  }

  String _resolveSelectedDepartmentName() {
    if (_selectedDepartment == _otherOptionLabel) {
      return _otherDepartmentCtrl.text.trim();
    }
    return _selectedDepartment.trim();
  }

  Future<String?> _showSearchablePicker({
    required String title,
    required List<String> options,
    required String selectedValue,
    String? hintText,
  }) async {
    final searchController = TextEditingController();

    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final query = searchController.text.trim().toLowerCase();
            final visibleOptions = query.isEmpty
                ? options
                : options.where((item) => item.toLowerCase().contains(query)).toList();

            return Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 14,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: searchController,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      hintText: hintText ?? 'Search...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: visibleOptions.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Center(
                              child: Text(
                                'No matching options found.',
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: visibleOptions.length,
                            separatorBuilder: (_, __) =>
                                Divider(height: 1, color: Colors.grey[200]),
                            itemBuilder: (_, index) {
                              final option = visibleOptions[index];
                              final isSelected = option == selectedValue;
                              return ListTile(
                                title: Text(option),
                                trailing: isSelected
                                    ? const Icon(
                                        Icons.check_circle_rounded,
                                        color: _primary,
                                      )
                                    : null,
                                onTap: () => Navigator.pop(sheetContext, option),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    searchController.dispose();
    return result;
  }

  Widget _buildSearchableField({
    required String label,
    required String value,
    required List<String> options,
    required String hintText,
    required ValueChanged<String> onChanged,
    bool loading = false,
  }) {
    final displayValue = value.trim().isEmpty ? hintText : value.trim();

    return InkWell(
      onTap: loading
          ? null
          : () async {
              final pickerOptions = <String>[...options];
              if (!pickerOptions.any(
                (item) => item.toLowerCase() == _otherOptionLabel.toLowerCase(),
              )) {
                pickerOptions.add(_otherOptionLabel);
              }
              final picked = await _showSearchablePicker(
                title: label,
                options: pickerOptions,
                selectedValue: value,
                hintText: 'Search $label',
              );
              if (picked == null || !mounted) return;
              setState(() => onChanged(picked));
            },
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          hintText: loading ? 'Loading...' : hintText,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                displayValue,
                style: TextStyle(
                  color: value.trim().isEmpty ? Colors.grey[500] : Colors.black87,
                ),
              ),
            ),
            const Icon(Icons.arrow_drop_down_rounded),
          ],
        ),
      ),
    );
  }

  Future<void> _loadPaymentMethods() async {
    try {
      await CityScopeService.ensureLoaded();
      final snap = await _database
          .child(_tenantPath('settings/payment-methods'))
          .get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final List<Map<String, dynamic>> methods = [];
        data.forEach((key, val) {
          if (val is Map) {
            final m = Map<String, dynamic>.from(val);
            if (m['enabled'] == true) {
              methods.add({
                'key': key.toString(),
                'label': m['label'] ?? key.toString(),
                'icon': m['icon'] ?? 'payment',
              });
            }
          }
        });
        if (methods.isNotEmpty && mounted) {
          setState(() {
            // Only keep Cash on Delivery
            _paymentMethods = methods.where((m) => m['key'] == 'cod').toList();
            if (_paymentMethods.isEmpty) {
              _paymentMethods = [
                {'key': 'cod', 'label': 'Cash on Delivery', 'icon': 'money'},
              ];
            }
            _paymentMethod = _paymentMethods.first['label'];
          });
        }
      }
    } catch (_) {}
    // If nothing loaded, use Cash on Delivery only
    if (_paymentMethods.isEmpty && mounted) {
      setState(() {
        _paymentMethods = [
          {'key': 'cod', 'label': 'Cash on Delivery', 'icon': 'money'},
        ];
      });
    }
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

  String _resolveAdMobRewardedAdUnitId(Map<String, dynamic> data) {
    final candidates = <dynamic>[
      data['admobRewardedAdUnitId'],
      data['admobPointsRewardedAdUnitId'],
      data['pointsRewardedAdUnitId'],
      data['rewardedAdUnitId'],
    ];

    for (final candidate in candidates) {
      final value = candidate?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    return _defaultAdMobRewardedAdUnitId;
  }

  Future<void> _loadCheckoutInstruction() async {
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
                _checkoutInstructionEnabled = _toBool(
                  data['checkoutInstructionEnabled'],
                  fallback: false,
                );
                _checkoutInstructionMessage =
                    (data['checkoutInstructionMessage'] ?? '')
                        .toString()
                        .trim();
                _loyaltyPointsEnabled =
                    data['loyaltyPointsEnabled'] != false;
              });
            } else {
              setState(() {
                _checkoutInstructionEnabled = false;
                _checkoutInstructionMessage = '';
                _loyaltyPointsEnabled = true;
              });
            }
          });
    } catch (_) {}
  }

  Future<void> _listenLoyaltyPoints() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _loyaltyPoints = 0;
          _loyaltyFreeDeliveryCredits = 0;
        });
      }
      return;
    }

    _loyaltySubscription?.cancel();
    _loyaltySubscription = _database
        .child('users/${user.uid}')
        .onValue
        .listen((event) {
          if (!mounted) return;
          final data = event.snapshot.value is Map
              ? Map<String, dynamic>.from(event.snapshot.value as Map)
              : <String, dynamic>{};
          final points = _toInt(data['loyaltyPoints']);
          final credits = _toInt(data['loyaltyFreeDeliveryCredits']);
          setState(() {
            _loyaltyPoints = points;
            _loyaltyFreeDeliveryCredits = credits;
          });
        });
  }

  Future<void> _applyPromoCode() async {
    final code = _promoController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    if (_activeWeeklyVoucherId != null &&
        _effectiveWeeklyRewardDiscount() > 0) {
      setState(() {
        _promoError =
            'Weekly winner reward is already auto-applied on this order.';
      });
      return;
    }

    setState(() {
      _promoLoading = true;
      _promoError = null;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in');
      await CityScopeService.ensureLoaded();
      final snap = await _database
          .child(_tenantPath('settings/promo-codes'))
          .child(code)
          .get();
      if (!snap.exists) {
        setState(() {
          _promoError = 'Invalid promo code';
          _promoLoading = false;
        });
        return;
      }
      final data = Map<String, dynamic>.from(snap.value as Map);
      // Check enabled
      if (data['enabled'] == false) {
        setState(() {
          _promoError = 'This promo code is disabled';
          _promoLoading = false;
        });
        return;
      }
      // Check expiry
      final expiresAt = data['expiresAt'];
      if (expiresAt != null && expiresAt is int) {
        if (DateTime.now().millisecondsSinceEpoch > expiresAt) {
          setState(() {
            _promoError = 'Promo code has expired';
            _promoLoading = false;
          });
          return;
        }
      }
      // Check per-user limit
      final maxPerUser = (data['maxPerUser'] ?? 1) as int;
      final usedBy = data['usedBy'];
      if (usedBy is Map) {
        final userUses = usedBy[user.uid];
        if (userUses != null && (userUses as int) >= maxPerUser) {
          setState(() {
            _promoError = 'You\'ve already used this promo code';
            _promoLoading = false;
          });
          return;
        }
      }
      // Check minimum order
      final minOrder = _toDouble(data['minOrder']);
      if (_cartService.subtotalFor(_scope) < minOrder) {
        setState(() {
          _promoError =
              'Minimum order Rs. ${minOrder.toStringAsFixed(0)} required';
          _promoLoading = false;
        });
        return;
      }
      // Calculate discount
      double discount = 0;
      final type = (data['type'] ?? 'percent').toString();
      final value = _toDouble(data['value']);
      if (type == 'percent') {
        discount = _cartService.subtotalFor(_scope) * (value / 100);
        final maxDiscount = _toDouble(data['maxDiscount']);
        if (discount > maxDiscount) discount = maxDiscount;
      } else {
        discount = value;
      }
      if (mounted) {
        setState(() {
          _appliedPromoCode = code;
          _promoDiscount = discount;
          _promoError = null;
          _promoLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Promo applied! -Rs. ${discount.toStringAsFixed(0)}'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _promoError = 'Error: $e';
          _promoLoading = false;
        });
      }
    }
  }

  void _removePromo() {
    setState(() {
      _appliedPromoCode = null;
      _promoDiscount = 0;
      _promoController.clear();
      _promoError = null;
    });
  }

  Future<void> _silentlyFetchGps() async {
    try {
      final locationData = await LocationService.getCurrentLocationSilently();
      if (locationData != null && mounted) {
        setState(() {
          _autoAddress = (locationData['address'] ?? '') as String;
          _autoLatitude = (locationData['latitude'] as num?)?.toDouble();
          _autoLongitude = (locationData['longitude'] as num?)?.toDouble();
          _latitude ??= _autoLatitude;
          _longitude ??= _autoLongitude;
        });
      }
    } catch (_) {}
  }

  Future<void> _ensureLocationReadyForOrder() async {
    // Skip fresh fetch when we already have usable location payload.
    if (_autoLatitude != null &&
        _autoLongitude != null &&
        _autoAddress.trim().isNotEmpty) {
      return;
    }

    // Keep checkout responsive: cap fresh GPS wait time.
    try {
      final locationData = await LocationService.getCurrentLocationSilently()
          .timeout(const Duration(milliseconds: 800), onTimeout: () => null);
      if (locationData != null) {
        _autoAddress = (locationData['address'] ?? '').toString().trim();
        _autoLatitude = (locationData['latitude'] as num?)?.toDouble();
        _autoLongitude = (locationData['longitude'] as num?)?.toDouble();
        _latitude = _autoLatitude ?? _latitude;
        _longitude = _autoLongitude ?? _longitude;
      }
    } catch (_) {}
  }

  String _formatAddressForDisplay(String address) {
    final parts = address.split(',').map((segment) => segment.trim()).where((
      segment,
    ) {
      if (segment.isEmpty) return false;
      final lower = segment.toLowerCase();
      if (lower.contains('postal code')) return false;
      if (lower == 'pakistan') return false;
      return true;
    }).toList();

    if (parts.isEmpty) return address;
    if (parts.length <= 3) return parts.join(', ');
    return parts.take(3).join(', ');
  }

  Future<String> _generateOrderId() async {
    final now = DateTime.now();
    final year = now.year.toString().substring(2);
    final dateKey =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    await CityScopeService.ensureLoaded();
    final counterRef = _database.child(
      _tenantPath('meta/orderCounters/$dateKey'),
    );

    final result = await counterRef.runTransaction((current) {
      final currentValue = current is int ? current : 0;
      return Transaction.success(currentValue + 1);
    });

    final counter = (result.snapshot.value as int?) ?? 1;
    final counterStr = counter.toString().padLeft(4, '0');
    return 'GT$year$counterStr';
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

  List<Map<String, String>> _extractShopTimingSlots(
    Map<dynamic, dynamic> shopData,
  ) {
    final slots = <Map<String, String>>[];
    final raw = shopData['timingSlots'];

    void addSlot(dynamic value) {
      if (value is! Map) return;
      final row = Map<dynamic, dynamic>.from(value);
      final open = (row['openTime'] ?? '').toString().trim();
      final close = (row['closeTime'] ?? '').toString().trim();
      if (open.isEmpty || close.isEmpty) return;
      slots.add({'openTime': open, 'closeTime': close});
    }

    if (raw is List) {
      for (final value in raw) {
        addSlot(value);
      }
    } else if (raw is Map) {
      final map = Map<dynamic, dynamic>.from(raw);
      for (final value in map.values) {
        addSlot(value);
      }
    }

    return slots;
  }

  bool _isWithinWindowMinutes({
    required int nowMinutes,
    required int openMinutes,
    required int closeMinutes,
  }) {
    if (openMinutes == closeMinutes) return true;
    if (openMinutes < closeMinutes) {
      return nowMinutes >= openMinutes && nowMinutes < closeMinutes;
    }
    return nowMinutes >= openMinutes || nowMinutes < closeMinutes;
  }

  bool _isShopOpenNow(Map<dynamic, dynamic> shopData) {
    if (shopData['isOpen'] == false || shopData['status'] == 'closed') {
      return false;
    }

    final closedDays = (shopData['closedDays'] as List?)?.map((e) => e.toString()).toList() ?? [];
    const daysOfWeek = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final todayName = daysOfWeek[DateTime.now().weekday - 1];
    if (closedDays.contains(todayName)) {
      return false;
    }

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    final slots = _extractShopTimingSlots(shopData);
    if (slots.isNotEmpty) {
      var hasValidSlot = false;
      for (final slot in slots) {
        final openMinutes = _parseTimeToMinutes(slot['openTime'] ?? '');
        final closeMinutes = _parseTimeToMinutes(slot['closeTime'] ?? '');
        if (openMinutes == null || closeMinutes == null) continue;
        hasValidSlot = true;

        if (_isWithinWindowMinutes(
          nowMinutes: nowMinutes,
          openMinutes: openMinutes,
          closeMinutes: closeMinutes,
        )) {
          return true;
        }
      }

      if (hasValidSlot) {
        return false;
      }
    }

    final openTimeRaw = (shopData['openTime'] ?? '').toString().trim();
    final closeTimeRaw = (shopData['closeTime'] ?? '').toString().trim();
    if (openTimeRaw.isEmpty || closeTimeRaw.isEmpty) return true;

    final openMinutes = _parseTimeToMinutes(openTimeRaw);
    final closeMinutes = _parseTimeToMinutes(closeTimeRaw);
    if (openMinutes == null || closeMinutes == null) return true;

    return _isWithinWindowMinutes(
      nowMinutes: nowMinutes,
      openMinutes: openMinutes,
      closeMinutes: closeMinutes,
    );
  }

  String _normalizeShopName(String value) => value.trim().toLowerCase();

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '0') ?? 0.0;
  }

  int? _toEpochMs(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final asDate = DateTime.tryParse(raw);
    return asDate?.millisecondsSinceEpoch;
  }

  double _weeklyRewardDiscountForBaseTotal(double baseTotalBeforeDiscounts) {
    if (_weeklyRewardDiscount <= 0) return 0.0;
    final beforeReward = (baseTotalBeforeDiscounts - _promoDiscount).clamp(
      0.0,
      double.infinity,
    );
    if (_weeklyRewardDiscount > beforeReward) {
      return beforeReward;
    }
    return _weeklyRewardDiscount;
  }

  double _effectiveWeeklyRewardDiscount() {
    return _weeklyRewardDiscountForBaseTotal(_baseTotalBeforeDiscounts());
  }

  double _grandTotalAfterDiscounts() {
    final total =
        _baseTotalBeforeDiscounts() -
        _promoDiscount -
        _effectiveWeeklyRewardDiscount();
    return total.clamp(0.0, double.infinity);
  }

  Future<void> _loadActiveWeeklyRewardVoucher() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (mounted) {
      setState(() => _weeklyRewardLoading = true);
    }

    try {
      await CityScopeService.ensureLoaded();
      final normalizedCity = CityScopeService.normalizeCity(
        CityScopeService.currentCity,
      );
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      final snap = await _database
          .child('users/${user.uid}/weeklyRewardVouchers')
          .get();

      String? bestVoucherId;
      String? bestWeekKey;
      String? bestLabel;
      double bestAmount = 0;

      if (snap.exists && snap.value is Map) {
        final vouchers = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in vouchers.entries) {
          if (entry.value is! Map) continue;
          final row = Map<String, dynamic>.from(entry.value as Map);

          final status = (row['status'] ?? 'active').toString().toLowerCase();
          if (status != 'active') continue;
          if (row['used'] == true) continue;

          final voucherCity = CityScopeService.normalizeCity(
            (row['city'] ?? normalizedCity).toString(),
          );
          if (voucherCity != normalizedCity) continue;

          final expiresAt = _toEpochMs(row['expiresAt']);
          if (expiresAt != null && nowMs > expiresAt) continue;

          final amount = _toDouble(row['amount']);
          if (amount <= 0) continue;

          if (amount > bestAmount) {
            bestAmount = amount;
            bestVoucherId = entry.key.toString();
            bestWeekKey = (row['weekKey'] ?? '').toString();
            final rank = (row['rank'] ?? '').toString();
            bestLabel = rank.isNotEmpty
                ? 'Weekly Winner #$rank Reward'
                : 'Weekly Winner Reward';
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _activeWeeklyVoucherId = bestVoucherId;
        _activeWeeklyVoucherWeekKey = bestWeekKey;
        _weeklyRewardDiscount = bestAmount;
        _weeklyRewardLabel = bestLabel;
        _weeklyRewardLoading = false;

        if (bestVoucherId != null && _appliedPromoCode != null) {
          _appliedPromoCode = null;
          _promoDiscount = 0;
          _promoController.clear();
          _promoError = 'Promo removed. Weekly winner reward is auto-applied.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _weeklyRewardLoading = false;
      });
    }
  }

  Map<String, Map<String, String>> _parseShopLookupsFromMap(
    Map<dynamic, dynamic> shops,
  ) {
    final nameToId = <String, String>{};
    final idToName = <String, String>{};

    shops.forEach((key, value) {
      if (value is! Map) return;
      final shopId = key.toString();
      final name = (value['name'] ?? '').toString().trim();
      if (shopId.isNotEmpty) {
        idToName[shopId] = name;
      }
      if (name.isNotEmpty) {
        nameToId[_normalizeShopName(name)] = shopId;
      }
    });

    return {'nameToId': nameToId, 'idToName': idToName};
  }

  Map<String, Map<String, String>> _parseShopLookupsFromSnap(DataSnapshot snap) {
    if (!snap.exists || snap.value is! Map) {
      return {'nameToId': <String, String>{}, 'idToName': <String, String>{}};
    }
    return _parseShopLookupsFromMap(snap.value as Map<dynamic, dynamic>);
  }

  Future<Map<String, Map<String, String>>> _loadShopLookups({
    DataSnapshot? shopsSnap,
  }) async {
    await CityScopeService.ensureLoaded();
    if (shopsSnap != null) return _parseShopLookupsFromSnap(shopsSnap);
    final shopsData = await ShopsCacheService.instance.getShopsMap();
    return _parseShopLookupsFromMap(shopsData);
  }

  Future<List<Map<String, dynamic>>> _buildOrderGroupsFromCart({
    Map<dynamic, dynamic>? shopsData,
    DataSnapshot? shopsSnap,
  }) async {
    final lookups = shopsData != null
        ? _parseShopLookupsFromMap(shopsData)
        : shopsSnap != null
            ? _parseShopLookupsFromSnap(shopsSnap)
            : await _loadShopLookups();
    final nameToId = lookups['nameToId'] ?? <String, String>{};
    final idToName = lookups['idToName'] ?? <String, String>{};

    final groups = <String, Map<String, dynamic>>{};

    for (final cartItem in _items) {
      var shopId = cartItem.shopId.trim();
      var shopName = cartItem.shopName.trim();

      if (shopId.isEmpty && shopName.isNotEmpty) {
        shopId = nameToId[_normalizeShopName(shopName)] ?? '';
      }
      if (shopName.isEmpty && shopId.isNotEmpty) {
        shopName = idToName[shopId] ?? '';
      }

      final groupKey = shopId.isNotEmpty
          ? 'id:$shopId'
          : 'name:${_normalizeShopName(shopName)}';

      final group = groups.putIfAbsent(
        groupKey,
        () => {
          'shopId': shopId,
          'shopName': shopName,
          'items': <Map<String, dynamic>>[],
          'subtotal': 0.0,
        },
      );

      final itemMap = cartItem.toMap();
      itemMap['shopId'] = shopId;
      itemMap['shopName'] = shopName;
      (group['items'] as List<Map<String, dynamic>>).add(itemMap);

      final lineSubtotal = _toDouble(cartItem.price) * cartItem.quantity;
      group['subtotal'] = _toDouble(group['subtotal']) + lineSubtotal;

      if ((group['shopId'] as String).isEmpty && shopId.isNotEmpty) {
        group['shopId'] = shopId;
      }
      if ((group['shopName'] as String).isEmpty && shopName.isNotEmpty) {
        group['shopName'] = shopName;
      }
    }

    return groups.values.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<bool> _canPlaceOrderForGroups(
    List<Map<String, dynamic>> groups, {
    Map<dynamic, dynamic>? shopsData,
    DataSnapshot? shopsSnap,
    Map<String, dynamic>? appControlData,
    DataSnapshot? appControlSnap,
  }) async {
    if (groups.isEmpty) return false;

    try {
      await CityScopeService.ensureLoaded();
      final appData = appControlData ??
          (appControlSnap != null && appControlSnap.exists && appControlSnap.value is Map
              ? Map<String, dynamic>.from(appControlSnap.value as Map)
              : await ShopsCacheService.instance.getAppControl());
      if (appData.isNotEmpty) {
        if (appData['temporarilyClosed'] == true) {
          final msg =
              (appData['closePopupMessage'] ??
                      'App is temporarily closed due to maintenance.')
                  .toString();
          if (mounted) {
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: const Text('Shop is Closed'),
                content: Text(msg),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
          return false;
        }
      }

      final shopsDataResolved = shopsData ??
          (shopsSnap != null && shopsSnap.exists && shopsSnap.value is Map
              ? Map<dynamic, dynamic>.from(shopsSnap.value as Map)
              : await ShopsCacheService.instance.getShopsMap());
      final shopsDataMap = shopsDataResolved;

      for (final group in groups) {
        final shopId = (group['shopId'] ?? '').toString().trim();
        if (shopId.isEmpty) continue;

        final rawShop = shopsDataMap[shopId];
        if (rawShop is! Map) continue;
        final shopData = Map<dynamic, dynamic>.from(rawShop);
        final shopVisible = CategoryTimingService.toBool(
          shopData['isVisible'],
          fallback: true,
        );
        if (!shopVisible) {
          if (mounted) {
            final shopName = (group['shopName'] ?? shopData['name'] ?? 'Shop')
                .toString();
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: const Text('Shop Unavailable'),
                content: Text(
                  '$shopName is currently hidden by admin and cannot accept orders.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
          return false;
        }
        final isOpen = _isShopOpenNow(shopData);
        if (!isOpen) {
          if (mounted) {
            final shopName = (group['shopName'] ?? shopData['name'] ?? 'Shop')
                .toString();
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: const Text('Shop is Closed'),
                content: Text(
                  '$shopName is currently closed. Please place your order during open hours.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
          return false;
        }

        final categorySchedules = shopData['categorySchedules'];
        final groupedItems = group['items'];
        if (groupedItems is List) {
          for (final rawItem in groupedItems) {
            if (rawItem is! Map) continue;
            final item = Map<dynamic, dynamic>.from(rawItem);
            final category = (item['category'] ?? item['type'] ?? '')
                .toString()
                .trim();
            if (category.isEmpty) continue;

            final categoryOpen = CategoryTimingService.isCategoryAvailable(
              schedules: categorySchedules,
              category: category,
            );
            if (!categoryOpen) {
              final schedule = CategoryTimingService.resolveCategorySchedule(
                schedules: categorySchedules,
                category: category,
              );
              final openTime = (schedule?['openTime'] ?? '').toString();
              final closeTime = (schedule?['closeTime'] ?? '').toString();
              final timing = openTime.isNotEmpty && closeTime.isNotEmpty
                  ? '\nAvailable: $openTime - $closeTime'
                  : '';

              if (mounted) {
                final shopName =
                    (group['shopName'] ?? shopData['name'] ?? 'Shop')
                        .toString();
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    title: const Text('Category is Out of Stock'),
                    content: Text(
                      '$category items in $shopName are unavailable right now.$timing',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              }
              return false;
            }
          }
        }
      }

      return true;
    } catch (_) {
      return true;
    }
  }

  Future<void> _placeOrder() async {
    if (_isPlacingOrder) return;

    if (_isIslamabadCheckout) {
      final hostelName = _resolveSelectedHostelName();
      final roomName = _resolveSelectedRoomName();
      final departmentName = _resolveSelectedDepartmentName();
      final isDepartmentMode = _selectedHostelType == 'department';
      if (isDepartmentMode) {
        if (departmentName.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please select department name'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
      } else if (hostelName.isEmpty || roomName.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select hostel and room details'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    } else {
      if (_addressController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter your delivery address'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your name'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your phone number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isPlacingOrder = true);

    final loyaltyFreeDeliveryApplied = _isLoyaltyFreeDeliveryActive;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in');
      await CityScopeService.ensureLoaded();

      final shopsFuture = ShopsCacheService.instance.getShopsMap();
      final appControlFuture = ShopsCacheService.instance.getAppControl();
      unawaited(_ensureLocationReadyForOrder());

      final shopsData = await shopsFuture;
      final orderGroups =
          await _buildOrderGroupsFromCart(shopsData: shopsData);
      if (orderGroups.isEmpty) {
        throw Exception('No valid items found in cart for checkout.');
      }

      final appControlData = await appControlFuture;
      final canPlace = await _canPlaceOrderForGroups(
        orderGroups,
        shopsData: shopsData,
        appControlData: appControlData,
      );
      if (!canPlace) {
        if (mounted) {
          setState(() => _isPlacingOrder = false);
        }
        return;
      }

      final orderCodeFuture = _generateOrderId();

      final hostelName = _resolveSelectedHostelName();
      final roomName = _resolveSelectedRoomName();
        final departmentName = _resolveSelectedDepartmentName();
        final hostelTypeLabel = _selectedHostelType == 'girls'
          ? 'Girls'
          : _selectedHostelType == 'department'
            ? 'Department'
            : 'Boys';

      final primaryAddress = _isIslamabadCheckout
          ? _selectedHostelType == 'department'
            ? 'Department, $departmentName'
            : '$hostelTypeLabel Hostel, $hostelName, $roomName'
          : _addressController.text.trim();
      final optionalAddress = '';
      final fullAddress = <String>[
        if (primaryAddress.isNotEmpty) primaryAddress,
      ].join(', ');

      final resolvedAutoAddress = _autoAddress.trim().isNotEmpty
          ? _autoAddress.trim()
          : fullAddress;
      final resolvedAutoAddressFormatted = _formatAddressForDisplay(
        resolvedAutoAddress,
      );
      final resolvedLatitude = _autoLatitude ?? _latitude;
      final resolvedLongitude = _autoLongitude ?? _longitude;

      // Save checkout profile details on every order
      final updates = <String, dynamic>{};
      if (_nameController.text.trim().isNotEmpty) {
        updates['name'] = _nameController.text.trim();
      }
      if (_phoneController.text.trim().isNotEmpty) {
        updates['phoneNumber'] = _phoneController.text.trim();
      }
      if (primaryAddress.isNotEmpty) {
        updates['address'] = primaryAddress;
      }
      if (_isIslamabadCheckout) {
        updates['checkoutHostel'] = {
          'hostelType': _selectedHostelType,
          'hostelName': hostelName,
          'roomNumber': roomName,
          'departmentName': departmentName,
          'hostelOther': _selectedHostel == _otherOptionLabel
              ? _otherHostelCtrl.text.trim()
              : '',
          'roomOther': _selectedRoom == _otherOptionLabel
              ? _otherRoomCtrl.text.trim()
              : '',
          'departmentOther': _selectedHostelType == 'department' &&
                  _selectedDepartment == _otherOptionLabel
              ? _otherDepartmentCtrl.text.trim()
              : '',
          'updatedAt': ServerValue.timestamp,
        };
      }
      if (updates.isNotEmpty) {
        unawaited(_database.child('users/${user.uid}').update(updates));
      }

      // Get user name for order
      String userName = _nameController.text.trim();
      if (userName.isEmpty) {
        userName = (user.displayName ?? '').trim();
      }
      if (userName.isEmpty) {
        userName = (user.email ?? '').split('@').first;
      }

      final firstGroup = orderGroups.first;
      final firstShopName = (firstGroup['shopName'] ?? '').toString().trim();
      final firstShopId = (firstGroup['shopId'] ?? '').toString().trim();
      final groupCount = orderGroups.length;
      final orderGroupId =
          'GRP-${DateTime.now().millisecondsSinceEpoch}-${user.uid.substring(0, 6)}';

      final items = _items.map((i) => i.toMap()).toList();
      final subtotal = _cartService.subtotalFor(_scope);
      final deliveryFee = _effectiveDeliveryFee();
      final tax = _cartService.taxFor(_scope);
      final extraCharge = _cartService.totalExtraChargeFor(_scope);
      final baseTotalBeforeDiscounts = subtotal + deliveryFee + tax + extraCharge;
      final weeklyRewardDiscount = _weeklyRewardDiscountForBaseTotal(
        baseTotalBeforeDiscounts,
      );
      final grandTotal = _grandTotalAfterDiscounts();
      final createdAtClient = DateTime.now().millisecondsSinceEpoch;
      final orderCode = await orderCodeFuture;
      final orderRef = _database.child(_tenantPath('shop-orders')).push();

      await orderRef.set({
        'userId': user.uid,
        'userEmail': user.email ?? '',
        'userName': userName,
        'userPhone': _phoneController.text.trim(),
        'contact': _phoneController.text.trim(),
        'shopId': firstShopId,
        'shopName': groupCount > 1 ? 'Multiple Shops' : firstShopName,
        'items': items,
        'subtotal': subtotal,
        'deliveryFee': deliveryFee,
        'deliveryFeeOriginal': _cartService.deliveryFeeFor(_scope),
        'deliverySpeed': _scope == CartScope.instant ? 'instant' : 'standard',
        'isInstantOrder': _scope == CartScope.instant,
        'instantDeliveryMinutes': _scope == CartScope.instant
            ? InstantDeliveryService.deliveryMinutes
            : null,
        'freeDeliveryApplied':
          _cartService.isFreeDeliveryAppliedFor(_scope) ||
              loyaltyFreeDeliveryApplied,
        'freeDeliveryEnabled': _cartService.freeDeliveryEnabled,
        'freeDeliveryAbove': _cartService.freeDeliveryAboveAmount,
        'adDeliveryDiscountApplied': false,
        'adsWatchedForDeliveryDiscount': 0,
        'adsRequiredForDeliveryDiscount': 0,
        'adDeliveryDiscountAmount': 0,
        'adDeliveryDiscountCap': 0,
        'loyaltyFreeDeliveryApplied': loyaltyFreeDeliveryApplied,
        'loyaltyPointsAtOrder': _loyaltyPoints,
        'tax': tax,
        'extraCharge': extraCharge,
        'promoCode': _appliedPromoCode,
        'promoDiscount': _promoDiscount,
        'weeklyRewardVoucherId': _activeWeeklyVoucherId,
        'weeklyRewardWeekKey': _activeWeeklyVoucherWeekKey,
        'weeklyRewardDiscount': weeklyRewardDiscount,
        'grandTotal': grandTotal,
        'address': primaryAddress,
        'manualAddress': primaryAddress,
        'address2': optionalAddress,
        'fullAddress': fullAddress,
        'hostelType': _isIslamabadCheckout ? _selectedHostelType : null,
        'hostelName': _isIslamabadCheckout ? hostelName : null,
        'roomNumber': _isIslamabadCheckout ? roomName : null,
        'departmentName': _isIslamabadCheckout && _selectedHostelType == 'department'
            ? departmentName
            : null,
        'hostelOther': _isIslamabadCheckout && _selectedHostel == _otherOptionLabel
          ? _otherHostelCtrl.text.trim()
          : null,
        'roomOther': _isIslamabadCheckout && _selectedRoom == _otherOptionLabel
          ? _otherRoomCtrl.text.trim()
          : null,
        'departmentOther': _isIslamabadCheckout &&
                _selectedHostelType == 'department' &&
                _selectedDepartment == _otherOptionLabel
            ? _otherDepartmentCtrl.text.trim()
            : null,
        'autoAddress': resolvedAutoAddress,
        'autoAddressFormatted': resolvedAutoAddressFormatted,
        'autoLatitude': resolvedLatitude,
        'autoLongitude': resolvedLongitude,
        'deliveryInstructions': _instructionsController.text.trim(),
        'paymentMethod': _paymentMethod,
        'customOrderId': orderCode,
        'status': 'available',
        'adminApprovalStatus': 'approved',
        'merchantDecision': 'auto_approved_by_admin',
        'customerStatusMessage': 'Order placed. Waiting for rider pickup.',
        'adminApprovedAt': createdAtClient,
        'availableAt': createdAtClient,
        'latitude': resolvedLatitude,
        'longitude': resolvedLongitude,
        'createdAt': ServerValue.timestamp,
        'createdAtClient': createdAtClient,
        'isMultiShopOrder': groupCount > 1,
        'orderGroupId': orderGroupId,
        'groupOrderCount': groupCount,
      });

      final details = {
        'orderId': orderRef.key,
        'orderCode': orderCode,
        'shopId': firstShopId,
        'shopName': groupCount > 1 ? 'Multiple Shops' : firstShopName,
        'total': grandTotal,
        'adDeliveryDiscountApplied': false,
        'adsWatchedForDeliveryDiscount': 0,
        'adDeliveryDiscountAmount': 0,
        'loyaltyFreeDeliveryApplied': loyaltyFreeDeliveryApplied,
        'loyaltyPointsAtOrder': _loyaltyPoints,
        'itemCount': items.length,
        'weeklyRewardDiscount': weeklyRewardDiscount,
        'status': 'available',
        'isMultiShopOrder': groupCount > 1,
        'orderGroupId': orderGroupId,
        'groupOrderCount': groupCount,
      };

      final postOrderTasks = <Future<void>>[
        _database.child(_tenantPath('notifications/user')).child(user.uid).push().set({
          'title': groupCount > 1
              ? 'Multi-Shop Order Placed'
              : 'Order Placed Successfully',
          'body': groupCount > 1
              ? 'Your combined order ($groupCount shops) is submitted and now visible to riders.'
              : 'Order $orderCode from $firstShopName is submitted and now visible to riders.',
          'type': groupCount > 1 ? 'multi_shop_order_placed' : 'order_placed',
          'orderId': orderRef.key,
          'details': details,
          'createdAt': ServerValue.timestamp,
          'createdAtClient': createdAtClient,
          'read': false,
        }),
        _database.child(_tenantPath('notifications/admin/inbox')).push().set({
          'title': 'New Customer Order',
          'body': groupCount > 1
              ? 'Combined order $orderCode ($groupCount shops) received from ${userName.isEmpty ? 'customer' : userName}.'
              : 'Order $orderCode received from ${userName.isEmpty ? 'customer' : userName} and sent to rider queue.',
          'details': details,
          'createdAt': ServerValue.timestamp,
          'createdAtClient': createdAtClient,
          'read': false,
        }),
      ];

      if (loyaltyFreeDeliveryApplied) {
        postOrderTasks.add(
          _loyaltyService.consumeFreeDeliveryCredit(user.uid),
        );
      }


      if (_appliedPromoCode != null) {
        postOrderTasks.add(() async {
          final promoRef = _database
              .child(_tenantPath('settings/promo-codes'))
              .child(_appliedPromoCode!)
              .child('usedBy')
              .child(user.uid);
          final usedSnap = await promoRef.get();
          final currentUses = usedSnap.exists
              ? (usedSnap.value as int? ?? 0)
              : 0;
          await promoRef.set(currentUses + 1);
        }());
      }

      if (_activeWeeklyVoucherId != null && weeklyRewardDiscount > 0) {
        postOrderTasks.add(
          _database
              .child(
                'users/${user.uid}/weeklyRewardVouchers/${_activeWeeklyVoucherId!}',
              )
              .update({
                'used': true,
                'status': 'used',
                'usedOrderId': orderRef.key,
                'usedAt': ServerValue.timestamp,
                'usedAtClient': createdAtClient,
              }),
        );
      }

      AnalyticsService.orderPlaced(
        orderRef.key ?? orderCode,
        grandTotal,
        _cartService.itemCountFor(_scope),
      );
      _cartService.clearCart(scope: _scope);

      if (mounted) {
        setState(() => _isPlacingOrder = false);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const OrderSuccessPage()),
          (route) => false,
        );
      }

      unawaited(
        Future.wait(postOrderTasks)
            .timeout(const Duration(seconds: 10))
            .catchError((_) {}),
      );

      // Trigger FCM background push notifications to Admins and Riders
      final orderCity = CityScopeService.currentCity;
      final cityName = CityScopeService.cityLabel(orderCity);
      final adminTitle = 'New Customer Order';
      final adminBody = groupCount > 1
          ? 'Combined order $orderCode ($groupCount shops) received from ${userName.isEmpty ? 'customer' : userName}.'
          : 'Order $orderCode received from ${userName.isEmpty ? 'customer' : userName} and sent to rider queue.';
      
      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'admin',
          city: orderCity,
          title: adminTitle,
          body: adminBody,
          data: {
            'type': 'new_order',
            'orderId': orderRef.key ?? '',
            'orderCode': orderCode,
            'city': orderCity,
          },
        ).catchError((_) => {}),
      );

      final riderTitle = groupCount > 1
          ? 'New Multi-Shop Delivery Available'
          : 'New Delivery Order Available';
      final riderBody = groupCount > 1
          ? 'A new combined order ($groupCount shops) is available in city $cityName.'
          : 'New order from $firstShopName is available in city $cityName.';

      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'rider',
          city: orderCity,
          title: riderTitle,
          body: riderBody,
          channelId: 'rider_new_order',
          data: {
            'type': 'available',
            'orderId': orderRef.key ?? '',
            'orderCode': orderCode,
            'city': orderCity,
          },
        ).catchError((_) => {}),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isPlacingOrder = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error placing order: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7F6),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 120),
                child: Column(
                  children: [
                    if (_checkoutInstructionEnabled &&
                        _checkoutInstructionMessage.isNotEmpty)
                      _buildCheckoutInstructionBanner(),
                    if (_items.isNotEmpty) _buildShopInfo(),
                    _buildItemsList(),
                    _buildDeliveryAddress(),
                    _buildContactInfo(),
                    _buildDeliveryInstructions(),
                    _buildPromoCode(),
                    _buildBillSummary(),
                  ],
                ),
              ),
            ),
            _buildStickyBottom(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 12),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
          const Expanded(
            child: Text(
              'Checkout',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildShopInfo() {
    final firstItem = _items.first;
    final uniqueShops = _items
        .map((e) {
          final id = e.shopId.trim();
          if (id.isNotEmpty) return 'id:$id';
          return 'name:${_normalizeShopName(e.shopName)}';
        })
        .toSet()
        .length;
    final multiShop = uniqueShops > 1;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.orange[50],
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.storefront, color: _primary, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              multiShop
                  ? '$uniqueShops Shops in this checkout'
                  : firstItem.shopName,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
          if (!multiShop)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('View Menu', style: TextStyle(color: _primary)),
            ),
        ],
      ),
    );
  }

  Widget _buildCheckoutInstructionBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5E8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD7AA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.campaign_rounded, color: _primary, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _checkoutInstructionMessage,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF7A4A16),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsList() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: _items
            .map(
              (item) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.grey[100]!),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: Colors.orange[50],
                      ),
                      child: item.imageUrl != null && item.imageUrl!.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: ImageHelper.networkImage(
                                url: item.imageUrl!,
                                fit: BoxFit.cover,
                                errorWidget: const Icon(
                                  Icons.fastfood,
                                  color: _primary,
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.fastfood,
                              color: _primary,
                              size: 30,
                            ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Rs. ${item.price.toStringAsFixed(0)}',
                            style: const TextStyle(
                              color: _primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () =>
                                _cartService.decreaseQuantity(item.id, scope: _scope),
                            child: const Icon(
                              Icons.remove,
                              size: 16,
                              color: Colors.grey,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              '${item.quantity}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () =>
                                _cartService.increaseQuantity(item.id, scope: _scope),
                            child: const Icon(Icons.add, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildDeliveryAddress() {
    if (_isIslamabadCheckout) {
      return _buildIslamabadHostelAddress();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Delivery Address',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              'Street / House Number *',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          TextField(
            controller: _addressController,
            decoration: InputDecoration(
              hintText: 'Street No, House No (e.g. Street 4, House 22)',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: const Icon(Icons.location_on, color: _primary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[200]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIslamabadHostelAddress() {
    final hostels = <String>[..._hostelsForType(_selectedHostelType)];
    if (!hostels.any((h) => h.toLowerCase() == _otherOptionLabel.toLowerCase())) {
      hostels.add(_otherOptionLabel);
    }
    final rooms = <String>[..._roomsForType(_selectedHostelType)];
    if (!rooms.any((r) => r.toLowerCase() == _otherOptionLabel.toLowerCase())) {
      rooms.add(_otherOptionLabel);
    }
    final departments = <String>[..._departmentOptions()];
    if (!departments.any((d) => d.toLowerCase() == _otherOptionLabel.toLowerCase())) {
      departments.add(_otherOptionLabel);
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Delivery Address',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 12),
          const Text(
            'Hostel Type *',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildHostelTypeCard(
                  label: 'Boys',
                  icon: Icons.boy_rounded,
                  isSelected: _selectedHostelType == 'boys',
                  onTap: () {
                    setState(() {
                      _selectedHostelType = 'boys';
                      _selectedHostel = '';
                      _selectedRoom = '';
                      _otherHostelCtrl.clear();
                      _otherRoomCtrl.clear();
                      _ensureHostelDefaults();
                    });
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildHostelTypeCard(
                  label: 'Girls',
                  icon: Icons.girl_rounded,
                  isSelected: _selectedHostelType == 'girls',
                  onTap: () {
                    setState(() {
                      _selectedHostelType = 'girls';
                      _selectedHostel = '';
                      _selectedRoom = '';
                      _otherHostelCtrl.clear();
                      _otherRoomCtrl.clear();
                      _ensureHostelDefaults();
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: _buildHostelTypeCard(
              label: 'Dept.',
              icon: Icons.apartment_rounded,
              isSelected: _selectedHostelType == 'department',
              onTap: () {
                setState(() {
                  _selectedHostelType = 'department';
                  _selectedHostel = '';
                  _selectedRoom = '';
                  _selectedDepartment = '';
                  _otherHostelCtrl.clear();
                  _otherRoomCtrl.clear();
                  _otherDepartmentCtrl.clear();
                  _ensureHostelDefaults();
                });
              },
            ),
          ),
          const SizedBox(height: 12),
          if (_selectedHostelType == 'department') ...[
            const Text(
              'Select Department *',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            _buildSearchableField(
              label: 'Department',
              value: _selectedDepartment,
              options: departments,
              hintText: 'Select department',
              loading: _hostelOptionsLoading,
              onChanged: (value) {
                _selectedDepartment = value;
                AnalyticsService.hostelDropdownUsed('department', value);
                if (value != _otherOptionLabel) {
                  _otherDepartmentCtrl.clear();
                }
              },
            ),
            if (_selectedDepartment == _otherOptionLabel) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _otherDepartmentCtrl,
                decoration: InputDecoration(
                  hintText: 'Type your department name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ] else ...[
            const Text(
              'Select Hostel *',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            _buildSearchableField(
              label: 'Hostel',
              value: _selectedHostel,
              options: hostels,
              hintText: 'Select hostel',
              loading: _hostelOptionsLoading,
              onChanged: (value) {
                _selectedHostel = value;
                AnalyticsService.hostelDropdownUsed('hostel', value);
                if (value != _otherOptionLabel) {
                  _otherHostelCtrl.clear();
                }
              },
            ),
            if (_selectedHostel == _otherOptionLabel) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _otherHostelCtrl,
                decoration: InputDecoration(
                  hintText: 'Type your hostel name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Room Number *',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            _buildSearchableField(
              label: 'Room Number',
              value: _selectedRoom,
              options: rooms,
              hintText: 'Select room',
              loading: _hostelOptionsLoading,
              onChanged: (value) {
                _selectedRoom = value;
                AnalyticsService.hostelDropdownUsed('room', value);
                if (value != _otherOptionLabel) {
                  _otherRoomCtrl.clear();
                }
              },
            ),
            if (_selectedRoom == _otherOptionLabel) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _otherRoomCtrl,
                decoration: InputDecoration(
                  hintText: 'Type your room number',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildHostelTypeCard({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final borderColor = isSelected ? _primary : Colors.grey[300]!;
    final bgColor = isSelected ? const Color(0xFFFFF3E8) : Colors.white;
    final textColor = isSelected ? _primary : Colors.grey[600];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1.4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactInfo() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline, color: _primary, size: 18),
              const SizedBox(width: 6),
              const Text(
                'Contact Info',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              hintText: 'Your full name',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: const Icon(Icons.person, color: _primary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[200]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            decoration: InputDecoration(
              hintText: 'Phone number (e.g. 03001234567)',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: const Icon(Icons.phone, color: _primary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[200]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildDeliveryInstructions() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Delivery Instructions',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _instructionsController,
            onChanged: (value) =>
                _cartService.setDeliveryInstructions(value, scope: _scope),
            decoration: InputDecoration(
              hintText: 'e.g., Ring the bell, leave at gate...',
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
              prefixIcon: const Icon(Icons.edit_note, color: _primary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[200]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromoCode() {
    final weeklyDiscount = _effectiveWeeklyRewardDiscount();
    final hasWeeklyReward =
        _activeWeeklyVoucherId != null && weeklyDiscount > 0;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (_appliedPromoCode != null || hasWeeklyReward)
              ? Colors.green[200]!
              : Colors.grey[100]!,
        ),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: (_appliedPromoCode != null || hasWeeklyReward)
                ? null
                : () => setState(() => _promoExpanded = !_promoExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    hasWeeklyReward ? Icons.emoji_events : Icons.local_offer,
                    color: (_appliedPromoCode != null || hasWeeklyReward)
                        ? Colors.green
                        : _primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: hasWeeklyReward
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _weeklyRewardLabel ??
                                    'Weekly Winner Reward Applied',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: Colors.green,
                                ),
                              ),
                              Text(
                                '-Rs. ${weeklyDiscount.toStringAsFixed(0)} auto discount',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green[700],
                                ),
                              ),
                              if ((_activeWeeklyVoucherWeekKey ?? '')
                                  .isNotEmpty)
                                Text(
                                  'Week: ${_activeWeeklyVoucherWeekKey!}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          )
                        : _appliedPromoCode != null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Promo Applied: $_appliedPromoCode',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: Colors.green,
                                ),
                              ),
                              Text(
                                '-Rs. ${_promoDiscount.toStringAsFixed(0)} discount',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green[700],
                                ),
                              ),
                            ],
                          )
                        : const Text(
                            'Have a promo code?',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                  ),
                  if (_appliedPromoCode != null)
                    GestureDetector(
                      onTap: _removePromo,
                      child: Icon(
                        Icons.close_rounded,
                        color: Colors.red[400],
                        size: 20,
                      ),
                    )
                  else if (hasWeeklyReward)
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 20,
                    )
                  else
                    Icon(
                      _promoExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.grey,
                    ),
                ],
              ),
            ),
          ),
          if (_weeklyRewardLoading)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: LinearProgressIndicator(minHeight: 2, color: _primary),
            ),
          if (_promoExpanded && _appliedPromoCode == null && !hasWeeklyReward)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _promoController,
                          textCapitalization: TextCapitalization.characters,
                          decoration: InputDecoration(
                            hintText: 'Enter promo code',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.grey[200]!),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: _primary),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: _promoLoading ? null : _applyPromoCode,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        child: _promoLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Apply'),
                      ),
                    ],
                  ),
                  if (_promoError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _promoError!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBillSummary() {
    final weeklyRewardDiscount = _effectiveWeeklyRewardDiscount();
    final grandTotal = _grandTotalAfterDiscounts();
    final hasFreeDeliveryOffer =
        _cartService.freeDeliveryEnabled &&
        _cartService.freeDeliveryAboveAmount > 0;
    final effectiveDeliveryFee = _effectiveDeliveryFee();
    final isDeliveryFree = effectiveDeliveryFee <= 0.0;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Bill Summary',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 12),
          _billRow(
            'Item Total',
            'Rs. ${_cartService.subtotalFor(_scope).toStringAsFixed(0)}',
          ),
          const SizedBox(height: 6),
          _billRow(
            'Delivery Fee',
            isDeliveryFree
                ? 'FREE'
                : 'Rs. ${effectiveDeliveryFee.toStringAsFixed(0)}',
            valueColor: isDeliveryFree ? Colors.green : null,
          ),
          if (_isLoyaltyFreeDeliveryActive && isDeliveryFree) ...[
            const SizedBox(height: 4),
            Text(
              'Loyalty points applied: Free Delivery',
              style: TextStyle(
                fontSize: 11,
                color: Colors.green[700],
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (hasFreeDeliveryOffer && !isDeliveryFree) ...[
            const SizedBox(height: 4),
            Text(
              'Free delivery above Rs. ${_cartService.freeDeliveryAboveAmount.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[600],
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 6),
          _billRow(
            'Tax (${_cartService.taxPercent.toStringAsFixed(0)}%)',
            'Rs. ${_cartService.taxFor(_scope).toStringAsFixed(0)}',
          ),
          if (_cartService.totalExtraChargeFor(_scope) > 0) ...[
            const SizedBox(height: 6),
            _billRow(
              'Extra Charges',
              'Rs. ${_cartService.totalExtraChargeFor(_scope).toStringAsFixed(0)}',
            ),
          ],
          if (_promoDiscount > 0) ...[
            const SizedBox(height: 6),
            _billRow(
              'Promo Discount ($_appliedPromoCode)',
              '-Rs. ${_promoDiscount.toStringAsFixed(0)}',
              valueColor: Colors.green,
            ),
          ],
          if (weeklyRewardDiscount > 0) ...[
            const SizedBox(height: 6),
            _billRow(
              _weeklyRewardLabel ?? 'Weekly Winner Reward',
              '-Rs. ${weeklyRewardDiscount.toStringAsFixed(0)}',
              valueColor: Colors.green,
            ),
          ],
          const Divider(height: 16),
          _billRow(
            'Grand Total',
            'Rs. ${grandTotal.toStringAsFixed(0)}',
            isBold: true,
            valueColor: _primary,
          ),
        ],
      ),
    );
  }

  Widget _billRow(
    String label,
    String value, {
    bool isBold = false,
    Color? valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[600],
            fontWeight: isBold ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: isBold ? 15 : 13,
            fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
            color: valueColor ?? const Color(0xFF1A1A1A),
          ),
        ),
      ],
    );
  }

  Widget _buildStickyBottom() {
    final grandTotal = _grandTotalAfterDiscounts();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.payments_outlined, color: _primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _paymentMethod,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    builder: (_) => Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Select Payment Method',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ..._paymentMethods.map(
                            (method) => ListTile(
                              title: Text(method['label']),
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.orange[50],
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.payment,
                                  color: _primary,
                                ),
                              ),
                              trailing: _paymentMethod == method['label']
                                  ? const Icon(
                                      Icons.check_circle,
                                      color: _primary,
                                    )
                                  : null,
                              onTap: () {
                                setState(
                                  () => _paymentMethod = method['label'],
                                );
                                Navigator.pop(context);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: const Text(
                  'Change',
                  style: TextStyle(
                    color: _primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _isPlacingOrder ? null : _placeOrder,
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B00), Color(0xFFFF6B35)],
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF6B00).withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 24),
                    child: Text(
                      'Place Order',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (_isPlacingOrder)
                    const Padding(
                      padding: EdgeInsets.only(right: 20),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  else
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Rs. ${grandTotal.toStringAsFixed(0)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
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
}
