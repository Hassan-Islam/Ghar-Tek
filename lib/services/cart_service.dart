import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'city_scope_service.dart';
import 'instant_delivery_service.dart';
import 'shops_cache_service.dart';
import 'analytics_service.dart';

enum CartScope { standard, instant }

class CartItem {
  final String id;
  final String name;
  final String shopName;
  final String shopId;
  final String? category;
  final double price;
  final String? imageUrl;
  final String? note;
  final String? extraChargeType;
  final double extraChargeValue;
  int quantity;

  CartItem({
    required this.id,
    required this.name,
    required this.shopName,
    required this.shopId,
    this.category,
    required this.price,
    this.imageUrl,
    this.note,
    this.extraChargeType,
    this.extraChargeValue = 0.0,
    this.quantity = 1,
  });

  double get totalPrice => price * quantity;

  double get productExtraCharge {
    if (extraChargeValue <= 0) return 0.0;
    if (extraChargeType == 'percent') {
      return totalPrice * (extraChargeValue / 100);
    } else if (extraChargeType == 'fixed') {
      return extraChargeValue * quantity;
    }
    return 0.0;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'shopName': shopName,
      'shopId': shopId,
      'category': category ?? '',
      'price': price,
      'imageUrl': imageUrl ?? '',
      'note': note ?? '',
      'extraChargeType': extraChargeType ?? 'none',
      'extraChargeValue': extraChargeValue,
      'quantity': quantity,
    };
  }
}

class CartService extends ChangeNotifier {
  static final CartService _instance = CartService._internal();
  factory CartService() => _instance;
  CartService._internal();

  final List<CartItem> _standardItems = [];
  final List<CartItem> _instantItems = [];
  String _standardInstructions = '';
  String _instantInstructions = '';

  List<CartItem> _list(CartScope scope) =>
      scope == CartScope.instant ? _instantItems : _standardItems;

  String _instructionsFor(CartScope scope) =>
      scope == CartScope.instant ? _instantInstructions : _standardInstructions;

  void _setInstructionsFor(CartScope scope, String value) {
    if (scope == CartScope.instant) {
      _instantInstructions = value;
    } else {
      _standardInstructions = value;
    }
  }

  List<CartItem> itemsFor(CartScope scope) => List.unmodifiable(_list(scope));
  List<CartItem> get items => itemsFor(CartScope.standard);

  int itemCountFor(CartScope scope) =>
      _list(scope).fold(0, (sum, item) => sum + item.quantity);
  int get itemCount => itemCountFor(CartScope.standard);
  int get instantItemCount => itemCountFor(CartScope.instant);

  bool isEmptyFor(CartScope scope) => _list(scope).isEmpty;
  bool get isEmpty => isEmptyFor(CartScope.standard);

  String? currentShopIdFor(CartScope scope) {
    final scopedItems = _list(scope);
    if (scopedItems.isEmpty) return null;
    return scopedItems.first.shopId;
  }

  String? get currentShopId => currentShopIdFor(CartScope.standard);

  double subtotalFor(CartScope scope) =>
      _list(scope).fold(0.0, (sum, item) => sum + item.totalPrice);
  double get subtotal => subtotalFor(CartScope.standard);

  String? _singleCartShopIdFor(CartScope scope) {
    final ids = _list(scope)
        .map((item) => item.shopId.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.length != 1) return null;
    return ids.first;
  }

  double _deliveryFee = 50.0;
  double _instantDeliveryFee = 70.0;
  final Map<String, double> _shopStandardDeliveryFeeOverrides = {};
  final Map<String, String> _shopExtraChargeTypes = {};
  final Map<String, double> _shopExtraChargeValues = {};
  double _taxPercent = 3.0;
  bool _freeDeliveryEnabled = false;
  double _freeDeliveryAbove = 0.0;
  String _standardTime = '30-45';

  double _effectiveStandardDeliveryFeeBaseFor(CartScope scope) {
    final shopId = _singleCartShopIdFor(scope);
    if (shopId != null) {
      final override = _shopStandardDeliveryFeeOverrides[shopId];
      if (override != null && override >= 0) return override;
    }
    return _deliveryFee;
  }

  double deliveryFeeFor(CartScope scope) {
    if (isEmptyFor(scope)) return 0.0;
    if (scope == CartScope.instant) return _instantDeliveryFee;
    if (isFreeDeliveryAppliedFor(scope)) return 0.0;
    return _effectiveStandardDeliveryFeeBaseFor(scope);
  }

  double get deliveryFee => deliveryFeeFor(CartScope.standard);

  double taxFor(CartScope scope) => subtotalFor(scope) * (_taxPercent / 100);
  double get tax => taxFor(CartScope.standard);

  double productExtraChargeFor(CartScope scope) =>
      _list(scope).fold(0.0, (sum, item) => sum + item.productExtraCharge);
  double get productExtraCharge => productExtraChargeFor(CartScope.standard);

  double shopExtraChargeFor(CartScope scope) {
    final shopId = _singleCartShopIdFor(scope);
    if (shopId == null) return 0.0;
    final type = _shopExtraChargeTypes[shopId] ?? 'none';
    final value = _shopExtraChargeValues[shopId] ?? 0.0;
    if (value <= 0) return 0.0;
    if (type == 'percent') return subtotalFor(scope) * (value / 100);
    if (type == 'fixed') return value;
    return 0.0;
  }

  double get shopExtraCharge => shopExtraChargeFor(CartScope.standard);

  double totalExtraChargeFor(CartScope scope) =>
      productExtraChargeFor(scope) + shopExtraChargeFor(scope);
  double get totalExtraCharge => totalExtraChargeFor(CartScope.standard);

  double grandTotalFor(CartScope scope) =>
      subtotalFor(scope) +
      deliveryFeeFor(scope) +
      taxFor(scope) +
      totalExtraChargeFor(scope);
  double get grandTotal => grandTotalFor(CartScope.standard);

  bool isFreeDeliveryAppliedFor(CartScope scope) =>
      !isEmptyFor(scope) &&
      _freeDeliveryEnabled &&
      _freeDeliveryAbove > 0 &&
      subtotalFor(scope) >= _freeDeliveryAbove;
  bool get isFreeDeliveryApplied =>
      isFreeDeliveryAppliedFor(CartScope.standard);

  bool hasShopSpecificDeliveryFeeAppliedFor(CartScope scope) {
    final shopId = _singleCartShopIdFor(scope);
    if (shopId == null) return false;
    return _shopStandardDeliveryFeeOverrides.containsKey(shopId);
  }

  bool get hasShopSpecificDeliveryFeeApplied =>
      hasShopSpecificDeliveryFeeAppliedFor(CartScope.standard);

  double deliveryFeeRawFor(CartScope scope) => scope == CartScope.instant
      ? _instantDeliveryFee
      : _effectiveStandardDeliveryFeeBaseFor(scope);
  double get deliveryFeeRaw => deliveryFeeRawFor(CartScope.standard);

  String deliveryInstructionsFor(CartScope scope) => _instructionsFor(scope);
  String get deliveryInstructions => deliveryInstructionsFor(CartScope.standard);

  void setDeliveryInstructions(String value,
      {CartScope scope = CartScope.standard}) {
    _setInstructionsFor(scope, value);
    notifyListeners();
  }

  double get standardDeliveryFeeBase => _deliveryFee;
  double get instantDeliveryFeeBase => _instantDeliveryFee;
  double get taxPercent => _taxPercent;
  bool get freeDeliveryEnabled => _freeDeliveryEnabled;
  double get freeDeliveryAboveAmount => _freeDeliveryAbove;
  String get standardTime => _standardTime;

  double _toDouble(dynamic value, {double fallback = 0.0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  double? _tryToDouble(dynamic value) {
    if (value is num) return value.toDouble();
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  bool _toBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'on') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == '0' ||
        normalized == 'no' ||
        normalized == 'off') {
      return false;
    }
    return fallback;
  }

  void updateFeeSettings({
    required double deliveryFee,
    required double taxPercent,
    bool freeDeliveryEnabled = false,
    double freeDeliveryAbove = 0,
  }) {
    _deliveryFee = deliveryFee;
    _taxPercent = taxPercent;
    _freeDeliveryEnabled = freeDeliveryEnabled;
    _freeDeliveryAbove = freeDeliveryAbove;
    notifyListeners();
  }

  Future<void> loadFeeSettings() async {
    try {
      await CityScopeService.ensureLoaded();
      final snap = await FirebaseDatabase.instance
          .ref(CityScopeService.tenantPath('settings/fees'))
          .get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        _deliveryFee = _toDouble(data['deliveryFee'], fallback: 50);
        _instantDeliveryFee = _toDouble(
          data['instantDeliveryFee'],
          fallback: 70,
        );
        _taxPercent = _toDouble(data['taxPercent'], fallback: 3);
        _freeDeliveryEnabled = _toBool(
          data['freeDeliveryEnabled'],
          fallback: false,
        );
        _freeDeliveryAbove = _toDouble(data['freeDeliveryAbove'], fallback: 0);
        _standardTime = (data['standardTime'] ?? '30-45').toString();
      }
    } catch (_) {}
    await _loadShopDeliveryFeeOverrides();
    notifyListeners();
  }

  Future<void> _loadShopDeliveryFeeOverrides() async {
    try {
      await CityScopeService.ensureLoaded();
      final shopsData = await ShopsCacheService.instance.getShopsMap();
      final standard = <String, double>{};
      final chargeTypes = <String, String>{};
      final chargeValues = <String, double>{};

      if (shopsData.isNotEmpty) {
        shopsData.forEach((key, value) {
          if (value is! Map) return;
          final shopId = key.toString().trim();
          if (shopId.isEmpty) return;
          final row = Map<dynamic, dynamic>.from(value);
          final standardFee = _tryToDouble(row['deliveryFeeStandard']);
          if (standardFee != null && standardFee >= 0) {
            standard[shopId] = standardFee;
          }
          final chargeType = (row['extraChargeType'] ?? 'none').toString();
          final chargeValue = _tryToDouble(row['extraChargeValue']);
          if (chargeValue != null && chargeValue > 0) {
            chargeTypes[shopId] = chargeType;
            chargeValues[shopId] = chargeValue;
          }
        });
      }

      _shopStandardDeliveryFeeOverrides
        ..clear()
        ..addAll(standard);
      _shopExtraChargeTypes
        ..clear()
        ..addAll(chargeTypes);
      _shopExtraChargeValues
        ..clear()
        ..addAll(chargeValues);
      notifyListeners();
    } catch (_) {}
  }

  StreamSubscription? _feeSubscription;
  StreamSubscription? _shopFeeSubscription;

  void startFeeListener() {
    _feeSubscription?.cancel();
    _shopFeeSubscription?.cancel();
    _attachFeeListener();
  }

  Future<void> _attachFeeListener() async {
    await CityScopeService.ensureLoaded();
    _feeSubscription = FirebaseDatabase.instance
        .ref(CityScopeService.tenantPath('settings/fees'))
        .onValue
        .listen((event) {
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        _deliveryFee = _toDouble(data['deliveryFee'], fallback: 50);
        _instantDeliveryFee = _toDouble(
          data['instantDeliveryFee'],
          fallback: 70,
        );
        _taxPercent = _toDouble(data['taxPercent'], fallback: 3);
        _freeDeliveryEnabled = _toBool(
          data['freeDeliveryEnabled'],
          fallback: false,
        );
        _freeDeliveryAbove = _toDouble(data['freeDeliveryAbove'], fallback: 0);
        _standardTime = (data['standardTime'] ?? '30-45').toString();
        notifyListeners();
      }
    });

    unawaited(_loadShopDeliveryFeeOverrides());
    _shopFeeSubscription = Stream<void>.periodic(const Duration(minutes: 2))
        .listen((_) => _loadShopDeliveryFeeOverrides());
  }

  void stopFeeListener() {
    _feeSubscription?.cancel();
    _feeSubscription = null;
    _shopFeeSubscription?.cancel();
    _shopFeeSubscription = null;
  }

  static CartScope scopeForProduct(
    Map<String, dynamic> product, {
    CartScope? forced,
  }) {
    if (forced != null) return forced;
    return InstantDeliveryService.isInstantProduct(product)
        ? CartScope.instant
        : CartScope.standard;
  }

  bool addItem(CartItem item, {CartScope scope = CartScope.standard}) {
    final items = _list(scope);
    final existingIndex = items.indexWhere((i) => i.id == item.id);
    if (existingIndex != -1) {
      items[existingIndex].quantity += item.quantity;
    } else {
      items.add(item);
    }
    notifyListeners();
    return true;
  }

  bool upsertItem(CartItem item, {CartScope scope = CartScope.standard}) {
    final items = _list(scope);
    final existingIndex = items.indexWhere((i) => i.id == item.id);
    if (item.quantity <= 0) {
      if (existingIndex != -1) items.removeAt(existingIndex);
      notifyListeners();
      return true;
    }

    if (existingIndex != -1) {
      final existing = items[existingIndex];
      existing.quantity = item.quantity;
      if (item.price != existing.price) {
        items[existingIndex] = CartItem(
          id: item.id,
          name: item.name,
          shopName: item.shopName,
          shopId: item.shopId,
          category: item.category,
          price: item.price,
          imageUrl: item.imageUrl,
          note: item.note,
          extraChargeType: item.extraChargeType,
          extraChargeValue: item.extraChargeValue,
          quantity: item.quantity,
        );
      }
    } else {
      items.add(item);
    }
    notifyListeners();
    return true;
  }

  static String resolveCartItemId(
    Map<String, dynamic> product, {
    String? variantId,
    String? size,
  }) {
    final productId = product['id']?.toString() ?? '';
    if (variantId != null && variantId.isNotEmpty) {
      return '${productId}_$variantId';
    }
    if (size != null && size.isNotEmpty) {
      return '${productId}_$size';
    }
    return productId;
  }

  static String defaultCartItemId(Map<String, dynamic> product) {
    final hasSizes = product['hasSizes'] == true;
    if (hasSizes) {
      final sizes = product['sizes'];
      if (sizes is List && sizes.isNotEmpty) {
        final first = sizes.first;
        if (first is Map) {
          final label = (first['label'] ?? first['name'] ?? '').toString();
          if (label.isNotEmpty) {
            return resolveCartItemId(product, size: label);
          }
        }
      }
      final halfPrice =
          double.tryParse(product['halfPrice']?.toString() ?? '') ?? 0;
      if (halfPrice > 0) {
        return resolveCartItemId(product, size: 'Half Plate');
      }
    }

    final variants = product['variants'];
    if (variants is Map && variants.isNotEmpty) {
      return resolveCartItemId(
        product,
        variantId: variants.keys.first.toString(),
      );
    }

    return resolveCartItemId(product);
  }

  void removeItem(String itemId, {CartScope scope = CartScope.standard}) {
    _list(scope).removeWhere((i) => i.id == itemId);
    notifyListeners();
  }

  void increaseQuantity(String itemId, {CartScope scope = CartScope.standard}) {
    final items = _list(scope);
    final index = items.indexWhere((i) => i.id == itemId);
    if (index != -1) {
      items[index].quantity++;
      notifyListeners();
    }
  }

  void decreaseQuantity(String itemId, {CartScope scope = CartScope.standard}) {
    final items = _list(scope);
    final index = items.indexWhere((i) => i.id == itemId);
    if (index != -1) {
      if (items[index].quantity > 1) {
        items[index].quantity--;
      } else {
        items.removeAt(index);
      }
      notifyListeners();
    }
  }

  void clearCart({CartScope? scope}) {
    if (scope == null) {
      _standardItems.clear();
      _instantItems.clear();
      _standardInstructions = '';
      _instantInstructions = '';
    } else if (scope == CartScope.instant) {
      _instantItems.clear();
      _instantInstructions = '';
    } else {
      _standardItems.clear();
      _standardInstructions = '';
    }
    notifyListeners();
  }

  int loadFromOrderItems(
    List<dynamic> rawItems, {
    Map<String, dynamic>? orderFallback,
    bool clearFirst = true,
  }) {
    if (clearFirst) clearCart(scope: CartScope.standard);

    final fallbackShopId = (orderFallback?['shopId'] ?? '').toString();
    final fallbackShopName =
        (orderFallback?['shopName'] ?? orderFallback?['shop'] ?? '').toString();

    var added = 0;
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = (item['id'] ?? '').toString();
      if (id.isEmpty) continue;

      final qtyRaw = item['quantity'];
      final quantity = qtyRaw is int
          ? qtyRaw
          : int.tryParse(qtyRaw?.toString() ?? '') ?? 1;
      if (quantity <= 0) continue;

      final cartItem = CartItem(
        id: id,
        name: (item['name'] ?? item['productName'] ?? 'Item').toString(),
        shopName: (item['shopName'] ?? fallbackShopName).toString(),
        shopId: (item['shopId'] ?? fallbackShopId).toString(),
        category: item['category']?.toString(),
        price: item['price'] is num
            ? (item['price'] as num).toDouble()
            : double.tryParse(item['price']?.toString() ?? '') ?? 0.0,
        imageUrl: (item['imageUrl'] ?? item['image'])?.toString(),
        note: item['note']?.toString(),
        extraChargeType: item['extraChargeType']?.toString(),
        extraChargeValue: item['extraChargeValue'] is num
            ? (item['extraChargeValue'] as num).toDouble()
            : double.tryParse(item['extraChargeValue']?.toString() ?? '') ?? 0.0,
        quantity: quantity,
      );

      upsertItem(cartItem, scope: CartScope.standard);
      AnalyticsService.addToCart(
        cartItem.id,
        cartItem.name,
        cartItem.price,
        cartItem.shopId,
      );
      added++;
    }

    return added;
  }

  int getItemQuantity(String itemId, {CartScope scope = CartScope.standard}) {
    final index = _list(scope).indexWhere((i) => i.id == itemId);
    return index != -1 ? _list(scope)[index].quantity : 0;
  }
}
