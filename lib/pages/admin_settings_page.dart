import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/auth_service.dart';
import '../services/city_scope_service.dart';

class AdminSettingsPage extends StatefulWidget {
  const AdminSettingsPage({super.key});

  @override
  State<AdminSettingsPage> createState() => _AdminSettingsPageState();
}

class _AdminSettingsPageState extends State<AdminSettingsPage>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFFFF6B00);

  final _db = FirebaseDatabase.instance.ref();
  final _authService = AuthService();
  final _currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

  late TabController _tabController;

  // ── Admins ──────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _admins = [];
  bool _adminsLoading = true;

  // ── All Users ────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  bool _usersLoading = true;
  final _searchCtrl = TextEditingController();

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  String _cityLabel(String city) => CityScopeService.cityLabel(city);

  Future<String?> _askAdminCityAssignment({
    required String title,
    String? initialCity,
  }) async {
    String selected = CityScopeService.normalizeCity(
      (initialCity ?? CityScopeService.currentCity),
    );

    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialog) {
          Widget cityOption({required String city, required String label}) {
            final isSelected = selected == city;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                isSelected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: isSelected ? _primary : Colors.grey[500],
              ),
              title: Text(label),
              onTap: () => setDialog(() => selected = city),
            );
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                cityOption(city: CityScopeService.vehari, label: 'Vehari Admin'),
                cityOption(city: CityScopeService.islamabad, label: 'Islamabad Admin'),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, selected),
                style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
                child: const Text('Assign City'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        if (_tabController.index == 0) _loadAdmins();
        if (_tabController.index == 1) _loadAllUsers();
      }
    });
    _loadAdmins();
    _loadAllUsers();
    _searchCtrl.addListener(_filterUsers);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAdmins() async {
    setState(() => _adminsLoading = true);
    try {
      final snap = await _db.child('users').get();
      if (!snap.exists) { setState(() => _adminsLoading = false); return; }
      final data = snap.value as Map<dynamic, dynamic>;
      final List<Map<String, dynamic>> admins = [];
      data.forEach((uid, val) {
        final u = Map<String, dynamic>.from(val as Map);
        if (u['role'] == 'admin') {
          u['uid'] = uid.toString();
          admins.add(u);
        }
      });
      if (mounted) setState(() { _admins = admins; _adminsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _adminsLoading = false);
    }
  }

  Future<void> _removeAdmin(String uid, String name) async {
    if (uid == _currentUid) {
      _snack('You cannot remove your own admin access', Colors.red);
      return;
    }
    await CityScopeService.ensureLoaded();
    final city = CityScopeService.currentCity;
    // Direct removal — no confirmation dialog
    await _db.child('users').child(uid).update({
      'role': 'user',
      'adminCity': null,
      'adminCityAssignedAt': null,
      'userCity': city,
      'userCityAssignedAt': ServerValue.timestamp,
    });
    _snack('"$name" removed from admins', Colors.green);
    _loadAdmins();
  }

  Future<void> _togglePermission(String uid, String key, bool value) async {
    await _db.child('users').child(uid).child('permissions').update({key: value});
    _loadAdmins();
  }

  void _showAddAdminDialog() {
    final controller = TextEditingController();
    String selectedCity = CityScopeService.currentCity;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('Add Admin by Email'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter the email of the user you want to promote to admin.',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'User Email',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedCity,
                decoration: InputDecoration(
                  labelText: 'Admin City',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.location_city_outlined),
                ),
                items: const [
                  DropdownMenuItem(value: CityScopeService.vehari, child: Text('Vehari')),
                  DropdownMenuItem(value: CityScopeService.islamabad, child: Text('Islamabad')),
                ],
                onChanged: (v) {
                  if (v != null) setDialog(() => selectedCity = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: const Icon(Icons.person_add_rounded, size: 16),
              label: const Text('Promote'),
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(ctx);
                await _promoteUserByEmail(controller.text.trim(), selectedCity);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promoteUserByEmail(String email, String adminCity) async {
    if (email.isEmpty) return;
    try {
      final snap = await _db.child('users').get();
      if (!snap.exists) return;
      final data = snap.value as Map<dynamic, dynamic>;
      String? foundUid;
      data.forEach((uid, val) {
        final u = Map<String, dynamic>.from(val as Map);
        if ((u['email'] ?? '').toString().toLowerCase() == email.toLowerCase()) {
          foundUid = uid.toString();
        }
      });
      if (foundUid == null) {
        _snack('No user found with email "$email"', Colors.red);
        return;
      }
      final normalizedCity = CityScopeService.normalizeCity(adminCity);
      await _db.child('users').child(foundUid!).update({
        'role': 'admin',
        'adminCity': normalizedCity,
        'adminCityAssignedAt': ServerValue.timestamp,
        'userCity': null,
        'userCityAssignedAt': null,
        'permissions': {
          'orders': true,
          'shops': true,
          'users': false,
          'finance': false,
          'notifications': true,
        },
      });
      _loadAdmins();
      _loadAllUsers();
      _snack('$email promoted to ${_cityLabel(normalizedCity)} admin!', Colors.green);
    } catch (e) {
      _snack('Error: $e', Colors.red);
    }
  }

  // ─── All Users ───────────────────────────────────────────────────────────────

  Future<void> _loadAllUsers() async {
    setState(() => _usersLoading = true);
    try {
      final snap = await _db.child('users').get();
      if (!snap.exists) {
        setState(() { _usersLoading = false; _allUsers = []; _filteredUsers = []; });
        return;
      }
      final data = snap.value as Map<dynamic, dynamic>;
      final List<Map<String, dynamic>> users = [];
      data.forEach((uid, val) {
        final u = Map<String, dynamic>.from(val as Map);
        u['uid'] = uid.toString();
        users.add(u);
      });
      users.sort((a, b) => (a['name'] ?? a['email'] ?? '').toString()
          .compareTo((b['name'] ?? b['email'] ?? '').toString()));
      if (mounted) {
        setState(() { _allUsers = users; _filteredUsers = users; _usersLoading = false; });
      }
    } catch (_) {
      if (mounted) setState(() => _usersLoading = false);
    }
  }

  void _filterUsers() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filteredUsers = q.isEmpty
          ? _allUsers
          : _allUsers.where((u) {
              final name = (u['name'] ?? u['displayName'] ?? '').toString().toLowerCase();
              final email = (u['email'] ?? '').toString().toLowerCase();
              return name.contains(q) || email.contains(q);
            }).toList();
    });
  }

  Future<void> _toggleBan(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final banned = user['banned'] as bool? ?? false;
    await _db.child('users').child(uid).update({'banned': !banned});
    _snack(banned ? 'User unbanned' : 'User banned', banned ? Colors.green : Colors.orange);
    _loadAllUsers();
  }

  Future<void> _promoteToAdmin(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final name = (user['name'] ?? user['email'] ?? 'User').toString();
    final selectedCity = await _askAdminCityAssignment(
      title: 'Assign City for $name',
      initialCity: (user['adminCity'] ?? '').toString(),
    );
    if (selectedCity == null) return;

    final normalizedCity = CityScopeService.normalizeCity(selectedCity);
    await _db.child('users').child(uid).update({
      'role': 'admin',
      'adminCity': normalizedCity,
      'adminCityAssignedAt': ServerValue.timestamp,
      'userCity': null,
      'userCityAssignedAt': null,
      'permissions': {
        'orders': true, 'shops': true, 'users': false, 'finance': false, 'notifications': true,
      },
    });
    _snack('"$name" promoted to ${_cityLabel(normalizedCity)} admin', Colors.green);
    _loadAllUsers();
    _loadAdmins();
  }

  Future<void> _changeAdminCity(Map<String, dynamic> admin) async {
    final uid = (admin['uid'] ?? '').toString();
    if (uid.isEmpty) return;
    final name = (admin['name'] ?? admin['displayName'] ?? admin['email'] ?? 'Admin').toString();
    final selectedCity = await _askAdminCityAssignment(
      title: 'Change City for $name',
      initialCity: (admin['adminCity'] ?? '').toString(),
    );
    if (selectedCity == null) return;

    final normalizedCity = CityScopeService.normalizeCity(selectedCity);
    await _authService.assignAdminCityScope(uid: uid, city: normalizedCity);
    if (uid == _currentUid) {
      await CityScopeService.setSelectedCity(normalizedCity);
    }
    _snack('Admin city changed to ${_cityLabel(normalizedCity)}', Colors.green);
    _loadAdmins();
    _loadAllUsers();
  }

  Future<void> _promoteToRider(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final name = (user['name'] ?? user['email'] ?? 'User').toString();
    await CityScopeService.ensureLoaded();
    final city = CityScopeService.currentCity;
    await _db.child('users').child(uid).update({
      'role': 'rider',
      'userCity': city,
      'userCityAssignedAt': ServerValue.timestamp,
      'adminCity': null,
      'adminCityAssignedAt': null,
    });
    _snack('"$name" is now a Rider', Colors.cyan);
    _loadAllUsers();
  }

  Future<void> _promoteToMerchant(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final name = (user['name'] ?? user['email'] ?? 'User').toString();
    final ownerName = (user['name'] ?? user['displayName'] ?? name).toString();
    final businessName = ownerName.isEmpty ? 'Merchant Business' : ownerName;
    final merchantPhone = (user['phoneNumber'] ?? '').toString();
    final tenantProfileRef = _db.child(_tenantPath('merchant_profiles/$uid'));
    final profileRef = _db.child('merchant_profiles/$uid');

    try {
      final profileSnap = await tenantProfileRef.get();
      final now = DateTime.now().toIso8601String();
      await CityScopeService.ensureLoaded();
      final city = CityScopeService.currentCity;

      await _db.child('users').child(uid).update({
        'role': 'merchant',
        'userCity': city,
        'userCityAssignedAt': ServerValue.timestamp,
        'adminCity': null,
        'adminCityAssignedAt': null,
        'isMerchantActive': true,
        'banned': false,
        'isBanned': false,
      });

      final profileUpdate = <String, dynamic>{
        'uid': uid,
        'ownerName': ownerName,
        'email': user['email'] ?? '',
        'phoneNumber': merchantPhone,
        'businessName': businessName,
        'businessAddress': '',
        'city': city,
        'isActive': true,
        'permissions': _authService.defaultMerchantPermissions(),
        'updatedAt': now,
      };

      if (!profileSnap.exists) {
        profileUpdate['createdAt'] = now;
        profileUpdate['assignedShopIds'] = <String, bool>{};
      }

      await tenantProfileRef.update(profileUpdate);
      await profileRef.update(profileUpdate);

      _snack('"$name" is now a Merchant', const Color(0xFF0E7A6C));
      _loadAllUsers();

      await _showMerchantShopSetupDialog(
        merchantUid: uid,
        merchantName: businessName,
        merchantPhone: merchantPhone,
      );
    } catch (e) {
      _snack('Failed to assign merchant role: $e', Colors.red);
    }
  }

  Future<void> _showMerchantShopSetupDialog({
    required String merchantUid,
    required String merchantName,
    required String merchantPhone,
  }) async {
    if (!mounted) return;

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Merchant Assigned'),
        content: Text(
          'Do you want to add a shop for $merchantName now so this merchant can manage it?',
          style: TextStyle(color: Colors.grey[700], height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('Later'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'assign'),
            icon: const Icon(Icons.store_mall_directory_rounded, size: 16),
            label: const Text('Assign Existing'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'create'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E7A6C),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.add_business_rounded, size: 16),
            label: const Text('Add Shop'),
          ),
        ],
      ),
    );

    if (action == 'create') {
      await _showCreateShopForMerchantDialog(
        merchantUid: merchantUid,
        merchantName: merchantName,
        merchantPhone: merchantPhone,
      );
    }

    if (action == 'assign') {
      await _showAssignShopsForMerchantDialog(
        merchantUid: merchantUid,
        merchantName: merchantName,
      );
    }
  }

  Future<void> _showCreateShopForMerchantDialog({
    required String merchantUid,
    required String merchantName,
    required String merchantPhone,
  }) async {
    final nameCtrl = TextEditingController();
    final categoryCtrl = TextEditingController(text: 'Food');
    final deliveryCtrl = TextEditingController(text: '30');
    final addressCtrl = TextEditingController();
    final openTimeCtrl = TextEditingController(text: '09:00');
    final closeTimeCtrl = TextEditingController(text: '23:00');
    bool isOpen = true;

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Add Shop for Merchant'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Shop Name *',
                      prefixIcon: Icon(Icons.store_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: categoryCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      prefixIcon: Icon(Icons.category_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: deliveryCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Delivery Time (mins)',
                      prefixIcon: Icon(Icons.timer_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Address (optional)',
                      prefixIcon: Icon(Icons.location_on_rounded),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: const Color(0xFF0E7A6C),
                    value: isOpen,
                    onChanged: (v) => setDialog(() => isOpen = v),
                    title: const Text('Shop is open'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0E7A6C),
                foregroundColor: Colors.white,
              ),
              child: const Text('Save Shop'),
            ),
          ],
        ),
      ),
    );

    if (save != true) return;

    if (nameCtrl.text.trim().isEmpty) {
      _snack('Shop name is required', Colors.red);
      return;
    }

    try {
      final shopRef = _db.child(_tenantPath('shops')).push();
      await shopRef.set({
        'name': nameCtrl.text.trim(),
        'description': '',
        'address': addressCtrl.text.trim(),
        'phone': merchantPhone,
        'imageUrl': '',
        'rating': 4.5,
        'deliveryTime': int.tryParse(deliveryCtrl.text.trim()) ?? 30,
        'openTime': openTimeCtrl.text.trim(),
        'closeTime': closeTimeCtrl.text.trim(),
        'isOpen': isOpen,
        'category': categoryCtrl.text.trim().isEmpty ? 'Food' : categoryCtrl.text.trim(),
        'merchantId': merchantUid,
        'merchantName': merchantName,
        'createdAt': ServerValue.timestamp,
      });

      await _db.child(_tenantPath('merchant_profiles/$merchantUid/assignedShopIds/${shopRef.key}')).set(true);
      await _db.child('merchant_profiles/$merchantUid/assignedShopIds/${shopRef.key}').set(true);

      _snack('Shop created and assigned successfully', Colors.green);
    } catch (e) {
      _snack('Failed to create shop: $e', Colors.red);
    }
  }

  Future<void> _showAssignShopsForMerchantDialog({
    required String merchantUid,
    required String merchantName,
  }) async {
    try {
      final shopsSnap = await _db.child(_tenantPath('shops')).get();
      final profileSnap = await _db.child(_tenantPath('merchant_profiles/$merchantUid/assignedShopIds')).get();

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
          if (value is! Map) return;
          final shop = Map<String, dynamic>.from(value);
          shop['id'] = key.toString();
          shops.add(shop);
        });
      }

      if (!mounted) return;

      if (shops.isEmpty) {
        _snack('No shops available. Add a new shop first.', Colors.orange);
        return;
      }

      final selected = Set<String>.from(assigned);

      final saved = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => StatefulBuilder(
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
                          'Assign Shops to Merchant',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    merchantName,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shops.length,
                      itemBuilder: (context, index) {
                        final shop = shops[index];
                        final id = shop['id'].toString();
                        final checked = selected.contains(id);
                        return CheckboxListTile(
                          value: checked,
                          activeColor: const Color(0xFF0E7A6C),
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
                        backgroundColor: const Color(0xFF0E7A6C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );

      if (saved != true) return;

      final updates = <String, dynamic>{};
      for (final id in selected) {
        updates[id] = true;
      }

      await _db.child(_tenantPath('merchant_profiles/$merchantUid/assignedShopIds')).set(updates);
      await _db.child('merchant_profiles/$merchantUid/assignedShopIds').set(updates);

      for (final shop in shops) {
        final shopId = shop['id'].toString();
        final isSelected = selected.contains(shopId);
        final existingMerchant = (shop['merchantId'] ?? '').toString();
        if (isSelected) {
          await _db.child(_tenantPath('shops/$shopId')).update({
            'merchantId': merchantUid,
            'merchantName': merchantName,
          });
        } else if (existingMerchant == merchantUid) {
          await _db.child(_tenantPath('shops/$shopId')).update({
            'merchantId': '',
            'merchantName': '',
          });
        }
      }

      _snack('Shop assignment updated', Colors.green);
    } catch (e) {
      _snack('Failed to assign shops: $e', Colors.red);
    }
  }

  Future<void> _demoteToCustomer(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final name = (user['name'] ?? user['email'] ?? 'User').toString();
    if (uid == _currentUid) {
      _snack('You cannot demote yourself', Colors.red);
      return;
    }
    await CityScopeService.ensureLoaded();
    final city = CityScopeService.currentCity;
    await _db.child('users').child(uid).update({
      'role': 'customer',
      'adminCity': null,
      'adminCityAssignedAt': null,
      'userCity': city,
      'userCityAssignedAt': ServerValue.timestamp,
    });
    await _db.child('users').child(uid).child('permissions').remove();
    _snack('"$name" demoted to customer', Colors.orange);
    _loadAllUsers();
    _loadAdmins();
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final name = (user['name'] ?? user['email'] ?? 'User').toString();
    await _db.child('users').child(uid).remove();
    _snack('"$name" deleted', Colors.red);
    _loadAllUsers();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        title: const Text('User Management',
            style: TextStyle(fontWeight: FontWeight.w800)),
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          unselectedLabelStyle:
              const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: [
            const Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.admin_panel_settings_rounded, size: 16),
                  SizedBox(width: 4),
                  Text('Admins'),
                ],
              ),
            ),
            const Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people_rounded, size: 16),
                  SizedBox(width: 4),
                  Text('All Users'),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _tabController.index == 0
          ? FloatingActionButton.extended(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Add Admin'),
              onPressed: _showAddAdminDialog,
            )
          : null,
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildAdminsTab(),
          _buildAllUsersTab(),
        ],
      ),
    );
  }

  // ─── Tab 1: Admins ───────────────────────────────────────────────────────────

  Widget _buildAdminsTab() {
    if (_adminsLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    if (_admins.isEmpty) {
      return _buildEmpty(Icons.admin_panel_settings_outlined, 'No admins found', 'Tap + to add an admin');
    }
    return RefreshIndicator(
      color: _primary,
      onRefresh: _loadAdmins,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
        children: [
          _infoBanner(
              '${_admins.length} admin${_admins.length != 1 ? 's' : ''} active. '
              'Each admin is city-bound (Vehari/Islamabad).',
              const Color(0xFFFF6B00)),
          const SizedBox(height: 14),
          ..._admins.map(_buildAdminCard),
        ],
      ),
    );
  }

  Widget _buildAdminCard(Map<String, dynamic> admin) {
    final uid = admin['uid'] ?? '';
    final isSelf = uid == _currentUid;
    final name = admin['name'] ?? admin['displayName'] ?? 'Unknown';
    final email = admin['email'] ?? 'No email';
    final adminCityRaw = (admin['adminCity'] ?? '').toString();
    final hasAdminCity = adminCityRaw.trim().isNotEmpty;
    final adminCity = hasAdminCity
      ? CityScopeService.normalizeCity(adminCityRaw)
      : CityScopeService.defaultCity;
    final permissions = admin['permissions'] is Map
        ? Map<String, dynamic>.from(admin['permissions'] as Map)
        : <String, dynamic>{};

    final perms = [
      {'key': 'orders', 'label': 'Orders', 'icon': Icons.receipt_long_rounded, 'color': const Color(0xFFFF6B00)},
      {'key': 'shops', 'label': 'Shops', 'icon': Icons.store_rounded, 'color': const Color(0xFFFF6B00)},
      {'key': 'users', 'label': 'Users', 'icon': Icons.people_rounded, 'color': Colors.purple},
      {'key': 'finance', 'label': 'Finance', 'icon': Icons.account_balance_wallet_rounded, 'color': const Color(0xFFFF6B00)},
      {'key': 'notifications', 'label': 'Notif.', 'icon': Icons.campaign_rounded, 'color': Colors.amber},
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isSelf
            ? Border.all(color: _primary.withValues(alpha: 0.4), width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor:
                      isSelf ? _primary.withValues(alpha: 0.15) : Colors.grey[100],
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: isSelf ? _primary : const Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (isSelf) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: _primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6)),
                            child: Text('You',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: _primary,
                                    fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text(email,
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0E7A6C).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'City: ${_cityLabel(adminCity)}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0E7A6C),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => _changeAdminCity(admin),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E7A6C).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF0E7A6C).withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_city_rounded, size: 14, color: Color(0xFF0E7A6C)),
                        SizedBox(width: 4),
                        Text('City', style: TextStyle(fontSize: 11, color: Color(0xFF0E7A6C), fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
                if (!isSelf)
                  GestureDetector(
                    onTap: () => _removeAdmin(uid, name),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red[200]!),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_remove_rounded,
                              size: 14, color: Colors.red[700]),
                          const SizedBox(width: 4),
                          Text('Remove',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.red[700],
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Permissions',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[400],
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: perms.map((p) {
                    final key = p['key'] as String;
                    final color = p['color'] as Color;
                    final icon = p['icon'] as IconData;
                    final enabled = permissions[key] as bool? ?? false;
                    return GestureDetector(
                      onTap: () => _togglePermission(uid, key, !enabled),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: enabled
                              ? color.withValues(alpha: 0.12)
                              : Colors.grey[100],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: enabled
                                ? color.withValues(alpha: 0.3)
                                : Colors.grey[200]!,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon,
                                size: 13,
                                color: enabled ? color : Colors.grey[400]),
                            const SizedBox(width: 4),
                            Text(p['label'] as String,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: enabled ? color : Colors.grey[400],
                                )),
                            const SizedBox(width: 4),
                            Icon(
                              enabled
                                  ? Icons.check_circle_rounded
                                  : Icons.cancel_rounded,
                              size: 12,
                              color: enabled ? color : Colors.grey[300],
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Tab 2: All Users ────────────────────────────────────────────────────────

  Widget _buildAllUsersTab() {
    if (_usersLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search by name or email…',
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.grey),
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.grey[200]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _primary),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                '${_filteredUsers.length} user${_filteredUsers.length != 1 ? 's' : ''}',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: _primary,
            onRefresh: _loadAllUsers,
            child: _filteredUsers.isEmpty
                ? Center(
                    child: Text('No users found',
                        style:
                            TextStyle(color: Colors.grey[400], fontSize: 15)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 80),
                    itemCount: _filteredUsers.length,
                    itemBuilder: (_, i) => _buildUserCard(_filteredUsers[i]),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final uid = user['uid'] as String;
    final isSelf = uid == _currentUid;
    final name = (user['name'] ?? user['displayName'] ?? 'Unknown').toString();
    final email = (user['email'] ?? 'No email').toString();
    final role = (user['role'] ?? 'customer').toString();
    final banned = user['banned'] as bool? ?? false;
    final isAdmin = role == 'admin';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: banned ? Colors.red[50] : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: banned
              ? Colors.red[200]!
              : (isSelf ? _primary.withValues(alpha: 0.3) : Colors.grey[200]!),
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: isAdmin
                ? _primary.withValues(alpha: 0.15)
                : (banned ? Colors.red[100] : Colors.grey[100]),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: isAdmin
                    ? _primary
                    : (banned ? Colors.red : Colors.grey[600]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14),
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 6),
                  _roleBadge(role, banned),
                ]),
                const SizedBox(height: 2),
                Text(email,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey[500]),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (!isSelf)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: Colors.grey[600]),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              onSelected: (val) {
                if (val == 'ban') _toggleBan(user);
                if (val == 'promote') _promoteToAdmin(user);
                if (val == 'rider') _promoteToRider(user);
                if (val == 'merchant') _promoteToMerchant(user);
                if (val == 'demote') _demoteToCustomer(user);
                if (val == 'delete') _deleteUser(user);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'ban',
                  child: Row(children: [
                    Icon(
                        banned
                            ? Icons.lock_open_rounded
                            : Icons.block_rounded,
                        size: 16,
                        color: banned ? Colors.green : Colors.orange),
                    const SizedBox(width: 8),
                    Text(banned ? 'Unban User' : 'Ban User'),
                  ]),
                ),
                if (!isAdmin && role != 'rider' && role != 'merchant')
                  const PopupMenuItem(
                    value: 'promote',
                    child: Row(children: [
                      Icon(Icons.admin_panel_settings_rounded,
                          size: 16, color: Color(0xFFFF6B00)),
                      SizedBox(width: 8),
                      Text('Make Admin'),
                    ]),
                  ),
                if (!isAdmin && role != 'rider' && role != 'merchant')
                  const PopupMenuItem(
                    value: 'rider',
                    child: Row(children: [
                      Icon(Icons.delivery_dining_rounded,
                          size: 16, color: Color(0xFF06B6D4)),
                      SizedBox(width: 8),
                      Text('Make Rider'),
                    ]),
                  ),
                if (!isAdmin && role != 'merchant')
                  const PopupMenuItem(
                    value: 'merchant',
                    child: Row(children: [
                      Icon(Icons.store_rounded,
                          size: 16, color: Color(0xFF0E7A6C)),
                      SizedBox(width: 8),
                      Text('Make Merchant'),
                    ]),
                  ),
                if (isAdmin || role == 'rider' || role == 'merchant')
                  const PopupMenuItem(
                    value: 'demote',
                    child: Row(children: [
                      Icon(Icons.person_rounded,
                          size: 16, color: Colors.grey),
                      SizedBox(width: 8),
                      Text('Demote to Customer'),
                    ]),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_forever_rounded,
                        size: 16, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Delete Account',
                        style: TextStyle(color: Colors.red)),
                  ]),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _roleBadge(String role, bool banned) {
    if (banned) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: Colors.red[100], borderRadius: BorderRadius.circular(6)),
        child: const Text('Banned',
            style: TextStyle(
                fontSize: 10,
                color: Colors.red,
                fontWeight: FontWeight.w800)),
      );
    }
    if (role == 'admin') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: _primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6)),
        child: Text('Admin',
            style: TextStyle(
                fontSize: 10,
                color: _primary,
                fontWeight: FontWeight.w800)),
      );
    }
    if (role == 'rider') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: const Color(0xFF06B6D4).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6)),
        child: const Text('Rider',
            style: TextStyle(
                fontSize: 10,
                color: Color(0xFF06B6D4),
                fontWeight: FontWeight.w800)),
      );
    }
    if (role == 'merchant') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: const Color(0xFF0E7A6C).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6)),
        child: const Text('Merchant',
            style: TextStyle(
                fontSize: 10,
                color: Color(0xFF0E7A6C),
                fontWeight: FontWeight.w800)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: Colors.grey[100], borderRadius: BorderRadius.circular(6)),
      child: const Text('Customer',
          style: TextStyle(
              fontSize: 10,
              color: Colors.grey,
              fontWeight: FontWeight.w700)),
    );
  }

  // ─── Shared Widgets ──────────────────────────────────────────────────────────

  Widget _buildEmpty(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
                color: Colors.orange[50], shape: BoxShape.circle),
            child: Icon(icon, size: 38, color: Colors.orange[200]),
          ),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _infoBanner(String text, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              color: color.withValues(alpha: 0.7), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: color.withValues(alpha: 0.8), fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
