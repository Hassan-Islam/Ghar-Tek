import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/city_scope_service.dart';
import '../services/image_upload_service.dart';
import '../services/notification_service.dart';

class MerchantPanel extends StatefulWidget {
  const MerchantPanel({super.key});

  @override
  State<MerchantPanel> createState() => _MerchantPanelState();
}

class _MerchantPanelState extends State<MerchantPanel> with WidgetsBindingObserver {
  static const Color _primary = Color(0xFFFF6B00);

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseDatabase.instance.ref();

  int _index = 0;
  String _shopId = '';
  Map<String, dynamic>? _shop;
  Map<String, dynamic> _permissions = {'canManageProducts': false};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProfile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadProfile();
    }
  }

  Future<void> _loadProfile() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _db.child('users/$uid').get(),
        _db.child('merchant_profiles/$uid').get(),
        _db.child('shops').get(),
      ]);

      final userSnap = results[0];
      final profileSnap = results[1];
      final shopsSnap = results[2];

      final user = userSnap.exists && userSnap.value is Map
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      final profile = profileSnap.exists && profileSnap.value is Map
          ? Map<String, dynamic>.from(profileSnap.value as Map)
          : <String, dynamic>{};

        final permissions = profile['permissions'] is Map
          ? Map<String, dynamic>.from(profile['permissions'] as Map)
          : <String, dynamic>{'canManageProducts': false};

      String shopId = (user['shopId'] ?? '').toString();

      if (shopId.isEmpty && shopsSnap.exists && shopsSnap.value is Map) {
        final assignedShopIds = <String>{};
        final assignedRaw = profile['assignedShopIds'];
        if (assignedRaw is Map) {
          assignedRaw.forEach((key, value) {
            if (value == true) assignedShopIds.add(key.toString());
          });
        }

        final shopsMap = shopsSnap.value as Map<dynamic, dynamic>;

        for (final entry in shopsMap.entries) {
          final key = entry.key.toString();
          final raw = entry.value;
          if (raw is! Map) continue;
          final shop = Map<String, dynamic>.from(raw);
          final merchantId = (shop['merchantId'] ?? '').toString();
          if (merchantId == uid || assignedShopIds.contains(key)) {
            shopId = key;
            break;
          }
        }
      }

      Map<String, dynamic>? shop;
      if (shopId.isNotEmpty) {
        final shopSnap = await _db.child('shops/$shopId').get();
        if (shopSnap.exists && shopSnap.value is Map) {
          shop = Map<String, dynamic>.from(shopSnap.value as Map);
          shop['id'] = shopId;
        }
      }
      if (!mounted) return;
      setState(() {
        _shopId = shopId;
        _shop = shop;
        _permissions = permissions;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _primary)),
      );
    }

    if (_shopId.isEmpty || _shop == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Merchant Panel')),
        body: const Center(child: Text('No shop linked to your account.')),
      );
    }

    final canManageProducts = _permissions['canManageProducts'] == true;
    final pages = [
      MerchantDashboardScreen(shopId: _shopId, shop: _shop ?? {}),
      if (canManageProducts) MerchantProductsScreen(shopId: _shopId),
      MerchantOrdersScreen(shopId: _shopId),
      MerchantSettingsScreen(shopId: _shopId, shop: _shop ?? {}, onUpdated: _loadProfile),
    ];

    final items = [
      const BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Dashboard'),
      if (canManageProducts) const BottomNavigationBarItem(icon: Icon(Icons.inventory_2_rounded), label: 'Products'),
      const BottomNavigationBarItem(icon: Icon(Icons.receipt_long_rounded), label: 'Orders'),
      const BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Settings'),
    ];

    if (_index >= pages.length) {
      _index = 0;
    }

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        selectedItemColor: _primary,
        onTap: (i) => setState(() => _index = i),
        items: items,
      ),
    );
  }
}

class MerchantDashboardScreen extends StatelessWidget {
  static const Color _primary = Color(0xFFFF6B00);

  final String shopId;
  final Map<String, dynamic> shop;

  const MerchantDashboardScreen({super.key, required this.shopId, required this.shop});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Merchant Dashboard'),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: db.child('shop-orders').onValue,
        builder: (context, snapshot) {
          int todayOrders = 0;
          double todayRevenue = 0;

          if (snapshot.hasData && snapshot.data!.snapshot.exists) {
            final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
            final today = DateTime.now();

            data.forEach((_, value) {
              if (value is! Map) return;
              final order = Map<String, dynamic>.from(value);
              if ((order['shopId'] ?? '').toString() != shopId) return;
              final createdAt = int.tryParse((order['createdAt'] ?? '0').toString()) ?? 0;
              if (createdAt <= 0) return;
              final dt = DateTime.fromMillisecondsSinceEpoch(createdAt);
              if (dt.year == today.year && dt.month == today.month && dt.day == today.day) {
                todayOrders += 1;
                if ((order['status'] ?? '').toString().toLowerCase() == 'delivered') {
                  todayRevenue += double.tryParse((order['grandTotal'] ?? order['subtotal'] ?? 0).toString()) ?? 0;
                }
              }
            });
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(shop['name'] ?? 'Shop', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              SwitchListTile(
                value: shop['isOpen'] == true,
                onChanged: (value) => db.child('shops/$shopId').update({'isOpen': value}),
                title: const Text('Shop Open'),
              ),
              const SizedBox(height: 12),
              _statCard('Today Orders', '$todayOrders'),
              const SizedBox(height: 8),
              _statCard('Today Revenue', 'Rs. ${todayRevenue.toStringAsFixed(0)}'),
            ],
          );
        },
      ),
    );
  }

  Widget _statCard(String title, String value) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class MerchantProductsScreen extends StatefulWidget {
  final String shopId;

  const MerchantProductsScreen({super.key, required this.shopId});

  @override
  State<MerchantProductsScreen> createState() => _MerchantProductsScreenState();
}

class _MerchantProductsScreenState extends State<MerchantProductsScreen> {
  static const Color _primary = Color(0xFFFF6B00);
  static const List<String> _mealCategories = [
    'Breakfast',
    'Lunch',
    'Dinner',
  ];

  final _db = FirebaseDatabase.instance.ref();
  final _picker = ImagePicker();

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _editingId = '';
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _imageCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _mealCategory = '';
  bool _available = true;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _priceCtrl.dispose();
    _imageCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() => _loading = true);
    try {
      final snap = await _db.child('shops/${widget.shopId}/menu').get();
      final list = <Map<String, dynamic>>[];
      if (snap.exists && snap.value is Map) {
        final map = snap.value as Map<dynamic, dynamic>;
        map.forEach((key, value) {
          if (value is! Map) return;
          final item = Map<String, dynamic>.from(value);
          item['id'] = key.toString();
          list.add(item);
        });
      }
      list.sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _resetForm() {
    _editingId = '';
    _nameCtrl.clear();
    _categoryCtrl.clear();
    _priceCtrl.clear();
    _imageCtrl.clear();
    _descCtrl.clear();
    _mealCategory = '';
    _available = true;
    setState(() {});
  }

  String _buildItemSubtitle(Map<String, dynamic> item) {
    final category = (item['category'] ?? '-').toString();
    final meal = (item['mealCategory'] ?? '').toString().trim();
    if (meal.isEmpty) return category;
    return 'Category: $category | Meal: $meal';
  }

  String _normalizeMealCategory(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    final lower = raw.toLowerCase();
    if (lower == 'breakfast' || lower == 'nashta') return 'Breakfast';
    if (lower == 'lunch') return 'Lunch';
    if (lower == 'dinner') return 'Dinner';
    return '';
  }

  Future<void> _uploadImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 88);
    if (picked == null) return;
    final result = await ImageUploadService.uploadImage(file: picked, useCase: ImageUploadUseCase.product);
    _imageCtrl.text = result.url;
    setState(() {});
  }

  Future<void> _saveProduct() async {
    final payload = {
      'name': _nameCtrl.text.trim(),
      'category': _categoryCtrl.text.trim(),
      'mealCategory': _mealCategory,
      'price': double.tryParse(_priceCtrl.text.trim()) ?? 0,
      'imageUrl': _imageCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'available': _available,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };

    if (payload['name'] == '') return;

    if (_editingId.isEmpty) {
      await _db.child('shops/${widget.shopId}/menu').push().set({
        ...payload,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      await _db.child('shops/${widget.shopId}/menu/$_editingId').update(payload);
    }

    _resetForm();
    _loadProducts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Products'), backgroundColor: _primary, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Product Name')),
          TextField(controller: _categoryCtrl, decoration: const InputDecoration(labelText: 'Category')),
          DropdownButtonFormField<String>(
            value: _mealCategory.isEmpty ? 'None' : _mealCategory,
            items: const [
              DropdownMenuItem(value: 'None', child: Text('None')),
              DropdownMenuItem(value: 'Breakfast', child: Text('Breakfast')),
              DropdownMenuItem(value: 'Lunch', child: Text('Lunch')),
              DropdownMenuItem(value: 'Dinner', child: Text('Dinner')),
            ],
            onChanged: (value) {
              setState(() {
                _mealCategory = value == null || value == 'None' ? '' : value;
              });
            },
            decoration: const InputDecoration(labelText: 'Meal Category (Trending)'),
          ),
          TextField(controller: _priceCtrl, decoration: const InputDecoration(labelText: 'Price'), keyboardType: TextInputType.number),
          TextField(controller: _imageCtrl, decoration: const InputDecoration(labelText: 'Image URL')),
          TextField(controller: _descCtrl, decoration: const InputDecoration(labelText: 'Description')),
          SwitchListTile(value: _available, onChanged: (v) => setState(() => _available = v), title: const Text('Available')),
          Row(
            children: [
              ElevatedButton(onPressed: _saveProduct, child: Text(_editingId.isEmpty ? 'Add Product' : 'Update Product')),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: _uploadImage, child: const Text('Upload Image')),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading) const Center(child: CircularProgressIndicator(color: _primary)),
          if (!_loading && _items.isEmpty) const Text('No products found.'),
          if (!_loading)
            ..._items.map((item) => ListTile(
                  title: Text(item['name'] ?? 'Item'),
                  subtitle: Text(_buildItemSubtitle(item)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_rounded),
                        onPressed: () {
                          _editingId = item['id'] ?? '';
                          _nameCtrl.text = item['name'] ?? '';
                          _categoryCtrl.text = item['category'] ?? '';
                          _mealCategory = _normalizeMealCategory(item['mealCategory'] ?? '');
                          _priceCtrl.text = (item['price'] ?? '').toString();
                          _imageCtrl.text = item['imageUrl'] ?? '';
                          _descCtrl.text = item['description'] ?? '';
                          _available = item['available'] != false;
                          setState(() {});
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_rounded),
                        onPressed: () async {
                          await _db.child('shops/${widget.shopId}/menu/${item['id']}').remove();
                          _loadProducts();
                        },
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}

class MerchantOrdersScreen extends StatelessWidget {
  static const Color _primary = Color(0xFFFF6B00);

  final String shopId;

  const MerchantOrdersScreen({super.key, required this.shopId});

  Future<void> _updateOrderStatus(
    DatabaseReference db,
    Map<String, dynamic> order,
    String nextStatus,
  ) async {
    final orderId = (order['id'] ?? '').toString();
    if (orderId.isEmpty) return;

    final customOrderId = (order['customOrderId'] ?? orderId).toString();
    final shopName = (order['shopName'] ?? order['shop'] ?? 'Shop').toString();
    final customerUserId = (order['userId'] ?? '').toString();

    // Perform database update
    await db.child('shop-orders/$orderId').update({
      'status': nextStatus,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });

    final orderCity = CityScopeService.currentCity;
    final cityName = CityScopeService.cityLabel(orderCity);

    // 1. Notify Riders if the status becomes available for riders (confirmed or preparing)
    if (nextStatus == 'confirmed' || nextStatus == 'preparing') {
      final riderTitle = 'New Delivery Order Available';
      final riderBody = 'Order #$customOrderId from $shopName is available in city $cityName.';
      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'rider',
          city: orderCity,
          title: riderTitle,
          body: riderBody,
          channelId: 'rider_new_order',
          data: {
            'type': 'available',
            'orderId': orderId,
            'orderCode': customOrderId,
            'city': orderCity,
          },
        ).catchError((_) => {}),
      );
    }

    // 2. Notify Customer of status update
    if (customerUserId.isNotEmpty) {
      unawaited(
        NotificationService.sendOrderStatusNotification(
          targetUserId: customerUserId,
          status: nextStatus,
          orderId: orderId,
          orderCode: customOrderId,
          shopName: (order['shopName'] ?? '').toString(),
        ).catchError((_) => {}),
      );
    }

    // 3. Notify Admins that merchant updated status
    final adminTitle = 'Merchant Status Update';
    final adminBody = 'Order #$customOrderId updated to $nextStatus by merchant.';
    unawaited(
      NotificationService.sendNotificationToRole(
        role: 'admin',
        city: orderCity,
        title: adminTitle,
        body: adminBody,
        data: {
          'type': 'merchant_status_update',
          'orderId': orderId,
          'orderCode': customOrderId,
          'city': orderCity,
        },
      ).catchError((_) => {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance.ref();

    return Scaffold(
      appBar: AppBar(title: const Text('Orders'), backgroundColor: _primary, foregroundColor: Colors.white),
      body: StreamBuilder<DatabaseEvent>(
        stream: db.child('shop-orders').onValue,
        builder: (context, snapshot) {
          final orders = <Map<String, dynamic>>[];
          if (snapshot.hasData && snapshot.data!.snapshot.exists) {
            final map = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
            map.forEach((key, value) {
              if (value is! Map) return;
              final order = Map<String, dynamic>.from(value);
              if ((order['shopId'] ?? '').toString() != shopId) return;
              final status = (order['status'] ?? '').toString().toLowerCase();
              if (status == 'pending') return;
              order['id'] = key.toString();
              orders.add(order);
            });
          }
          orders.sort((a, b) => (b['createdAt'] ?? 0).compareTo(a['createdAt'] ?? 0));

          if (orders.isEmpty) {
            return const Center(child: Text('No orders found.'));
          }

          return ListView.builder(
            itemCount: orders.length,
            itemBuilder: (_, index) {
              final order = orders[index];
              final status = (order['status'] ?? 'pending').toString();
              return Card(
                child: ListTile(
                  title: Text('Order #${(order['customOrderId'] ?? order['id']).toString().substring(0, 6)}'),
                  subtitle: Text('Status: $status'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (next) {
                      _updateOrderStatus(db, order, next);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'pending', child: Text('Pending')),
                      PopupMenuItem(value: 'confirmed', child: Text('Confirmed')),
                      PopupMenuItem(value: 'preparing', child: Text('Preparing')),
                      PopupMenuItem(value: 'on_the_way', child: Text('On The Way')),
                      PopupMenuItem(value: 'delivered', child: Text('Delivered')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class MerchantSettingsScreen extends StatefulWidget {
  static const Color _primary = Color(0xFFFF6B00);

  final String shopId;
  final Map<String, dynamic> shop;
  final VoidCallback onUpdated;

  const MerchantSettingsScreen({super.key, required this.shopId, required this.shop, required this.onUpdated});

  @override
  State<MerchantSettingsScreen> createState() => _MerchantSettingsScreenState();
}

class _MerchantSettingsScreenState extends State<MerchantSettingsScreen> {
  final _db = FirebaseDatabase.instance.ref();
  final _picker = ImagePicker();

  late TextEditingController _nameCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _categoryCtrl;
  late TextEditingController _imageCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.shop['name'] ?? '');
    _addressCtrl = TextEditingController(text: widget.shop['address'] ?? '');
    _categoryCtrl = TextEditingController(text: widget.shop['category'] ?? '');
    _imageCtrl = TextEditingController(text: widget.shop['imageUrl'] ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _categoryCtrl.dispose();
    _imageCtrl.dispose();
    super.dispose();
  }

  Future<void> _uploadImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 88);
    if (picked == null) return;
    final result = await ImageUploadService.uploadImage(file: picked, useCase: ImageUploadUseCase.shop);
    _imageCtrl.text = result.url;
    setState(() {});
  }

  Future<void> _save() async {
    await _db.child('shops/${widget.shopId}').update({
      'name': _nameCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'category': _categoryCtrl.text.trim(),
      'imageUrl': _imageCtrl.text.trim(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    widget.onUpdated();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), backgroundColor: MerchantSettingsScreen._primary, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Shop Name')),
          TextField(controller: _addressCtrl, decoration: const InputDecoration(labelText: 'Address')),
          TextField(controller: _categoryCtrl, decoration: const InputDecoration(labelText: 'Category')),
          TextField(controller: _imageCtrl, decoration: const InputDecoration(labelText: 'Image URL')),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(onPressed: _save, child: const Text('Save')),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: _uploadImage, child: const Text('Upload Image')),
            ],
          ),
        ],
      ),
    );
  }
}
