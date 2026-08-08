import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/auth_service.dart';
import '../services/city_scope_service.dart';

class AdminMerchantManagementPage extends StatefulWidget {
  const AdminMerchantManagementPage({super.key});

  @override
  State<AdminMerchantManagementPage> createState() => _AdminMerchantManagementPageState();
}

class _AdminMerchantManagementPageState extends State<AdminMerchantManagementPage> {
  static const Color _primary = Color(0xFF0E7A6C);
  static const Map<String, bool> _defaultMerchantPermissions = {
    'canUpdateOrderStatus': true,
    'canManageProducts': false,
    'canEditPrices': true,
    'canToggleShopOpen': true,
    'canViewRevenue': true,
  };

  final _db = FirebaseDatabase.instance.ref();
  final _authService = AuthService();

  bool _loading = true;
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _allMerchants = [];
  List<Map<String, dynamic>> _filteredMerchants = [];

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    _loadMerchants();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMerchants() async {
    setState(() => _loading = true);
    try {
      await CityScopeService.ensureLoaded();
      final usersSnap = await _db.child('users').get();
      final tenantProfilesSnap = await _db.child(_tenantPath('merchant_profiles')).get();
      final profilesSnap = await _db.child('merchant_profiles').get();

      final profilesMap = <String, Map<String, dynamic>>{};
      if (tenantProfilesSnap.exists && tenantProfilesSnap.value is Map) {
        final raw = tenantProfilesSnap.value as Map<dynamic, dynamic>;
        raw.forEach((key, value) {
          profilesMap[key.toString()] = Map<String, dynamic>.from(value as Map);
        });
      }
      if (profilesSnap.exists && profilesSnap.value is Map) {
        final raw = profilesSnap.value as Map<dynamic, dynamic>;
        raw.forEach((key, value) {
          profilesMap.putIfAbsent(
            key.toString(),
            () => Map<String, dynamic>.from(value as Map),
          );
        });
      }

      final merchants = <Map<String, dynamic>>[];
      if (usersSnap.exists && usersSnap.value is Map) {
        final users = usersSnap.value as Map<dynamic, dynamic>;
        users.forEach((uid, value) {
          final user = Map<String, dynamic>.from(value as Map);
          if ((user['role'] ?? '').toString() != 'merchant') return;
          final id = uid.toString();
          final profile = profilesMap[id] ?? {};

          int assignedCount = 0;
          if (profile['assignedShopIds'] is Map) {
            final m = profile['assignedShopIds'] as Map;
            assignedCount = m.values.where((v) => v == true).length;
          }

          merchants.add({
            'uid': id,
            'name': (profile['ownerName'] ?? user['name'] ?? 'Merchant').toString(),
            'email': (profile['email'] ?? user['email'] ?? '').toString(),
            'phone': (profile['phoneNumber'] ?? user['phoneNumber'] ?? '').toString(),
            'businessName': (profile['businessName'] ?? 'Business').toString(),
            'businessAddress': (profile['businessAddress'] ?? '').toString(),
            'isActive': (profile['isActive'] ?? user['isMerchantActive'] ?? true) == true,
            'assignedCount': assignedCount,
            'permissions': profile['permissions'] is Map
                ? Map<String, dynamic>.from(profile['permissions'] as Map)
                : Map<String, dynamic>.from(_defaultMerchantPermissions),
          });
        });
      }

      merchants.sort((a, b) => a['businessName'].toString().compareTo(b['businessName'].toString()));

      if (!mounted) return;
      setState(() {
        _allMerchants = merchants;
        _filteredMerchants = merchants;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load merchants: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.toLowerCase().trim();
    setState(() {
      _filteredMerchants = q.isEmpty
          ? _allMerchants
          : _allMerchants.where((m) {
              return m['businessName'].toString().toLowerCase().contains(q) ||
                  m['name'].toString().toLowerCase().contains(q) ||
                  m['email'].toString().toLowerCase().contains(q);
            }).toList();
    });
  }

  Future<void> _toggleMerchantStatus(Map<String, dynamic> merchant) async {
    final uid = merchant['uid'].toString();
    final next = !(merchant['isActive'] == true);
    await _db.child(_tenantPath('merchant_profiles/$uid')).update({'isActive': next});
    await _db.child('merchant_profiles/$uid').update({'isActive': next});
    await _db.child('users/$uid').update({'isMerchantActive': next, 'banned': !next, 'isBanned': !next});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next ? 'Merchant activated' : 'Merchant suspended'),
        backgroundColor: next ? Colors.green : Colors.orange,
      ),
    );
    _loadMerchants();
  }

  Future<void> _makeCustomer(Map<String, dynamic> merchant) async {
    final uid = merchant['uid'].toString();
    await _db.child('users/$uid').update({'role': 'customer'});
    await _db.child(_tenantPath('merchant_profiles/$uid')).remove();
    await _db.child('merchant_profiles/$uid').remove();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Merchant moved to customer role'), backgroundColor: Colors.orange),
    );
    _loadMerchants();
  }

  Future<void> _showAssignShopsDialog(Map<String, dynamic> merchant) async {
    final uid = merchant['uid'].toString();

    final shopsSnap = await _db.child(_tenantPath('shops')).get();
    final profileSnap = await _db.child(_tenantPath('merchant_profiles/$uid/assignedShopIds')).get();

    final assigned = <String>{};
    if (profileSnap.exists && profileSnap.value is Map) {
      final data = profileSnap.value as Map<dynamic, dynamic>;
      data.forEach((k, v) {
        if (v == true) assigned.add(k.toString());
      });
    }

    final shops = <Map<String, dynamic>>[];
    if (shopsSnap.exists && shopsSnap.value is Map) {
      final map = shopsSnap.value as Map<dynamic, dynamic>;
      map.forEach((key, value) {
        final shop = Map<String, dynamic>.from(value as Map);
        shop['id'] = key.toString();
        shops.add(shop);
      });
    }

    if (!mounted) return;
    final selected = Set<String>.from(assigned);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModal) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.78,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Assign Shops',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    merchant['businessName'].toString(),
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: shops.isEmpty
                        ? const Center(child: Text('No shops available'))
                        : ListView.builder(
                            itemCount: shops.length,
                            itemBuilder: (context, index) {
                              final shop = shops[index];
                              final id = shop['id'].toString();
                              final checked = selected.contains(id);
                              return CheckboxListTile(
                                value: checked,
                                activeColor: _primary,
                                onChanged: (v) {
                                  setModal(() {
                                    if (v == true) {
                                      selected.add(id);
                                    } else {
                                      selected.remove(id);
                                    }
                                  });
                                },
                                title: Text((shop['name'] ?? 'Shop').toString()),
                                subtitle: Text((shop['category'] ?? 'General').toString()),
                                contentPadding: EdgeInsets.zero,
                              );
                            },
                          ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('Save Assignment'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (saved != true) return;

    final updates = <String, dynamic>{};
    for (final s in selected) {
      updates[s] = true;
    }
    await _db.child(_tenantPath('merchant_profiles/$uid/assignedShopIds')).set(updates);
    await _db.child('merchant_profiles/$uid/assignedShopIds').set(updates);

    for (final shop in shops) {
      final shopId = shop['id'].toString();
      final isSelected = selected.contains(shopId);
      final existingMerchant = (shop['merchantId'] ?? '').toString();
      if (isSelected) {
        await _db.child(_tenantPath('shops/$shopId')).update({
          'merchantId': uid,
          'merchantName': merchant['businessName'].toString(),
        });
      } else if (existingMerchant == uid) {
        await _db.child(_tenantPath('shops/$shopId')).update({
          'merchantId': '',
          'merchantName': '',
        });
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Shop assignment updated'), backgroundColor: Colors.green),
    );
    _loadMerchants();
  }

  Future<void> _showCreateMerchantDialog() async {
    final ownerCtrl = TextEditingController();
    final businessCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final shopNameCtrl = TextEditingController();
    final shopCategoryCtrl = TextEditingController(text: 'Food');
    final shopDeliveryCtrl = TextEditingController(text: '30');
    bool createShopNow = true;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('Create Merchant Account'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _input(ownerCtrl, 'Owner Name', Icons.person_rounded),
                  const SizedBox(height: 10),
                  _input(businessCtrl, 'Business Name', Icons.business_rounded),
                  const SizedBox(height: 10),
                  _input(emailCtrl, 'Email', Icons.email_rounded, keyboard: TextInputType.emailAddress),
                  const SizedBox(height: 10),
                  _input(phoneCtrl, 'Phone', Icons.phone_rounded, keyboard: TextInputType.phone),
                  const SizedBox(height: 10),
                  _input(passwordCtrl, 'Password', Icons.lock_rounded, obscure: true),
                  const SizedBox(height: 10),
                  _input(addressCtrl, 'Business Address (Optional)', Icons.location_on_rounded),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: _primary,
                    title: const Text('Create first shop now'),
                    subtitle: const Text('Merchant account ke sath initial shop create hogi.'),
                    value: createShopNow,
                    onChanged: (v) => setDialog(() => createShopNow = v),
                  ),
                  if (createShopNow) ...[
                    _input(shopNameCtrl, 'Shop Name', Icons.store_rounded),
                    const SizedBox(height: 10),
                    _input(shopCategoryCtrl, 'Shop Category', Icons.category_rounded),
                    const SizedBox(height: 10),
                    _input(shopDeliveryCtrl, 'Delivery Time (mins)', Icons.timer_rounded, keyboard: TextInputType.number),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;

    if (ownerCtrl.text.trim().isEmpty ||
        businessCtrl.text.trim().isEmpty ||
        emailCtrl.text.trim().isEmpty ||
        phoneCtrl.text.trim().isEmpty ||
        passwordCtrl.text.trim().length < 6) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields (password min 6 chars).'), backgroundColor: Colors.red),
      );
      return;
    }

    if (createShopNow && shopNameCtrl.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shop name required when creating first shop.'), backgroundColor: Colors.red),
      );
      return;
    }

    try {
      final merchantUid = await _authService.createMerchantAccountByAdmin(
        ownerName: ownerCtrl.text.trim(),
        businessName: businessCtrl.text.trim(),
        email: emailCtrl.text.trim(),
        phoneNumber: phoneCtrl.text.trim(),
        password: passwordCtrl.text,
        businessAddress: addressCtrl.text.trim(),
      );

      if (createShopNow && shopNameCtrl.text.trim().isNotEmpty) {
        final shopRef = _db.child(_tenantPath('shops')).push();
        await shopRef.set({
          'name': shopNameCtrl.text.trim(),
          'description': '',
          'address': addressCtrl.text.trim(),
          'phone': phoneCtrl.text.trim(),
          'imageUrl': '',
          'rating': 4.5,
          'deliveryTime': int.tryParse(shopDeliveryCtrl.text.trim()) ?? 30,
          'openTime': '09:00',
          'closeTime': '23:00',
          'isOpen': true,
          'category': shopCategoryCtrl.text.trim().isEmpty ? 'Food' : shopCategoryCtrl.text.trim(),
          'merchantId': merchantUid,
          'merchantName': businessCtrl.text.trim(),
          'createdAt': DateTime.now().toIso8601String(),
        });
        await _db.child(_tenantPath('merchant_profiles/$merchantUid/assignedShopIds/${shopRef.key}')).set(true);
        await _db.child('merchant_profiles/$merchantUid/assignedShopIds/${shopRef.key}').set(true);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Merchant account created successfully'), backgroundColor: Colors.green),
      );
      _loadMerchants();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _showPermissionDialog(Map<String, dynamic> merchant) async {
    final uid = merchant['uid'].toString();
    final current = Map<String, dynamic>.from(
      merchant['permissions'] as Map? ?? _defaultMerchantPermissions,
    );

    final canUpdateOrderStatus = ValueNotifier<bool>(
      (current['canUpdateOrderStatus'] as bool?) ?? true,
    );
    final canManageProducts = ValueNotifier<bool>(
      (current['canManageProducts'] as bool?) ?? false,
    );
    final canEditPrices = ValueNotifier<bool>(
      (current['canEditPrices'] as bool?) ?? true,
    );
    final canToggleShopOpen = ValueNotifier<bool>(
      (current['canToggleShopOpen'] as bool?) ?? true,
    );
    final canViewRevenue = ValueNotifier<bool>(
      (current['canViewRevenue'] as bool?) ?? true,
    );

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Permissions - ${merchant['businessName']}'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: canUpdateOrderStatus,
                builder: (_, value, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Order status update'),
                  subtitle: const Text('Merchant can update order state.'),
                  value: value,
                  onChanged: (v) => canUpdateOrderStatus.value = v,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: canManageProducts,
                builder: (_, value, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Manage products'),
                  subtitle: const Text('Merchant can add/remove product catalog.'),
                  value: value,
                  onChanged: (v) => canManageProducts.value = v,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: canEditPrices,
                builder: (_, value, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Edit prices'),
                  subtitle: const Text('Merchant can update product prices.'),
                  value: value,
                  onChanged: (v) => canEditPrices.value = v,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: canToggleShopOpen,
                builder: (_, value, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Open/close shop control'),
                  subtitle: const Text('Merchant can toggle shop operational status.'),
                  value: value,
                  onChanged: (v) => canToggleShopOpen.value = v,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: canViewRevenue,
                builder: (_, value, __) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('View revenue'),
                  subtitle: const Text('Merchant can view monetary totals.'),
                  value: value,
                  onChanged: (v) => canViewRevenue.value = v,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (save != true) return;

    await _db.child('merchant_profiles/$uid/permissions').set({
      'canUpdateOrderStatus': canUpdateOrderStatus.value,
      'canManageProducts': canManageProducts.value,
      'canEditPrices': canEditPrices.value,
      'canToggleShopOpen': canToggleShopOpen.value,
      'canViewRevenue': canViewRevenue.value,
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Merchant permissions updated'), backgroundColor: Colors.green),
    );
    _loadMerchants();
  }

  String _permissionSummary(Map<String, dynamic> merchant) {
    final p = Map<String, dynamic>.from(
      merchant['permissions'] as Map? ?? _defaultMerchantPermissions,
    );
    final items = <String>[];
    if ((p['canUpdateOrderStatus'] as bool? ?? true) == true) items.add('orders');
    if ((p['canManageProducts'] as bool? ?? true) == true) items.add('products');
    if ((p['canEditPrices'] as bool? ?? true) == true) items.add('prices');
    if ((p['canToggleShopOpen'] as bool? ?? true) == true) items.add('open/close');
    if ((p['canViewRevenue'] as bool? ?? true) == true) items.add('revenue');
    return items.isEmpty ? 'none' : items.join(', ');
  }

  Widget _input(
    TextEditingController c,
    String label,
    IconData icon, {
    TextInputType keyboard = TextInputType.text,
    bool obscure = false,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      maxLength: keyboard == TextInputType.phone ? 11 : null,
      inputFormatters: keyboard == TextInputType.phone ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)] : null,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _statChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _filteredMerchants.length;
    final active = _filteredMerchants.where((m) => m['isActive'] == true).length;
    final suspended = total - active;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F6),
      appBar: AppBar(
        title: const Text('Merchant Management', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: _loadMerchants, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateMerchantDialog,
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_business_rounded),
        label: const Text('Create Merchant'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  child: Column(
                    children: [
                      TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'Search merchant by business, owner, email',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _statChip('Total', '$total', Colors.grey),
                          const SizedBox(width: 8),
                          _statChip('Active', '$active', const Color(0xFF16A34A)),
                          const SizedBox(width: 8),
                          _statChip('Suspended', '$suspended', Colors.orange),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _filteredMerchants.isEmpty
                      ? const Center(child: Text('No merchant accounts found'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 90),
                          itemCount: _filteredMerchants.length,
                          itemBuilder: (context, index) {
                            final m = _filteredMerchants[index];
                            final isActive = m['isActive'] == true;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: _primary.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.store_rounded, color: _primary),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              m['businessName'].toString(),
                                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${m['name']} • ${m['email']}',
                                              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: isActive
                                              ? const Color(0xFF16A34A).withValues(alpha: 0.1)
                                              : Colors.orange.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          isActive ? 'Active' : 'Suspended',
                                          style: TextStyle(
                                            color: isActive ? const Color(0xFF16A34A) : Colors.orange,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Text(
                                        'Assigned shops: ${m['assignedCount']}',
                                        style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                                      ),
                                      const Spacer(),
                                      Text(
                                        m['phone'].toString().isEmpty ? '-' : m['phone'].toString(),
                                        style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Permissions: ${_permissionSummary(m)}',
                                      style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _actionButton('Permissions', Icons.tune_rounded, Colors.blueGrey, () => _showPermissionDialog(m)),
                                      _actionButton('Assign Shops', Icons.store_mall_directory_rounded, _primary, () => _showAssignShopsDialog(m)),
                                      _actionButton(
                                        isActive ? 'Suspend' : 'Activate',
                                        isActive ? Icons.block_rounded : Icons.check_circle_rounded,
                                        isActive ? Colors.orange : const Color(0xFF16A34A),
                                        () => _toggleMerchantStatus(m),
                                      ),
                                      _actionButton('Make Customer', Icons.person_outline_rounded, Colors.grey, () => _makeCustomer(m)),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _actionButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
