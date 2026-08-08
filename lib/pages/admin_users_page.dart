import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/city_scope_service.dart';

class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});

  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  static const Color _primary = Color(0xFFFF6B00);

  final _database = FirebaseDatabase.instance.ref();
  final _auth = FirebaseAuth.instance;
  final _searchController = TextEditingController();
  String? _adminCity;

  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  Map<String, int> _userOrderCounts = {};
  String _selectedFilter = 'all'; // 'all', 'ordered', 'customers', 'banned'
  bool _isLoading = true;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _init();
    _searchController.addListener(_filter);
  }

  Future<void> _init() async {
    await _loadAdminCity();
    await _loadUsers();
    await _loadOrderCounts();
  }

  Future<void> _loadAdminCity() async {
    try {
      final current = _auth.currentUser;
      if (current == null) return;
      final snap = await _database.child('users/${current.uid}/adminCity').get();
      if (snap.exists) {
        _adminCity = CityScopeService.normalizeCity(snap.value?.toString());
      }
      if (_adminCity == null || _adminCity!.isEmpty) {
        await CityScopeService.ensureLoaded();
        _adminCity = CityScopeService.normalizeCity(CityScopeService.currentCity);
      }
    } catch (e) {
      // ignore
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final adminCity = CityScopeService.normalizeCity(_adminCity);
      final snap = await _database.child('users').get();
      List<Map<String, dynamic>> users = [];
      if (snap.exists) {
        final data = snap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          final user = Map<String, dynamic>.from(val);
          user['uid'] = key;
          final userCityRaw = (user['userCity'] ?? '').toString().trim();
          final userCity = userCityRaw.isEmpty
              ? ''
              : CityScopeService.normalizeCity(userCityRaw);
          if (adminCity.isNotEmpty && userCity != adminCity) {
            return;
          }
          users.add(user);
        });
      }
      users.sort((a, b) =>
          (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
      setState(() {
        _allUsers = users;
        _isLoading = false;
      });
      _filter();
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _loadOrderCounts() async {
    final Map<String, int> counts = {};
    try {
      final historySnap = await _database.child(_tenantPath('order-history')).get();
      if (historySnap.exists && historySnap.value is Map) {
        final data = Map<dynamic, dynamic>.from(historySnap.value as Map);
        data.forEach((_, orderVal) {
          if (orderVal is Map) {
            final uid = (orderVal['userId'] ?? '').toString();
            if (uid.isNotEmpty) {
              counts[uid] = (counts[uid] ?? 0) + 1;
            }
          }
        });
      }
    } catch (_) {}

    try {
      final shopOrdersSnap = await _database.child(_tenantPath('shop-orders')).get();
      if (shopOrdersSnap.exists && shopOrdersSnap.value is Map) {
        final data = Map<dynamic, dynamic>.from(shopOrdersSnap.value as Map);
        data.forEach((_, orderVal) {
          if (orderVal is Map) {
            final uid = (orderVal['userId'] ?? '').toString();
            if (uid.isNotEmpty) {
              counts[uid] = (counts[uid] ?? 0) + 1;
            }
          }
        });
      }
    } catch (_) {}

    try {
      final customOrdersSnap = await _database.child(_tenantPath('custom-orders')).get();
      if (customOrdersSnap.exists && customOrdersSnap.value is Map) {
        final data = Map<dynamic, dynamic>.from(customOrdersSnap.value as Map);
        data.forEach((_, orderVal) {
          if (orderVal is Map) {
            final uid = (orderVal['userId'] ?? '').toString();
            if (uid.isNotEmpty) {
              counts[uid] = (counts[uid] ?? 0) + 1;
            }
          }
        });
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _userOrderCounts = counts;
      });
      _filter();
    }
  }

  void _filter() {
    final q = _searchController.text.toLowerCase();
    setState(() {
      _filteredUsers = _allUsers.where((u) {
        final matchesQuery = q.isEmpty ||
            (u['name'] ?? '').toLowerCase().contains(q) ||
            (u['email'] ?? '').toLowerCase().contains(q) ||
            (u['phoneNumber'] ?? '').toLowerCase().contains(q);

        if (!matchesQuery) return false;

        final uid = u['uid'] ?? '';
        final orderCount = _userOrderCounts[uid] ?? 0;
        final isBanned = u['banned'] == true;
        final isCustomer = u['role'] != 'admin';

        if (_selectedFilter == 'ordered') {
          return orderCount > 0;
        } else if (_selectedFilter == 'customers') {
          return isCustomer;
        } else if (_selectedFilter == 'banned') {
          return isBanned;
        }
        return true;
      }).toList();
    });
  }

  void _showUserDetails(Map<String, dynamic> user) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UserDetailsSheet(
        user: user,
        orderCount: _userOrderCounts[user['uid']] ?? 0,
        onBan: () {
          _toggleBanUser(user);
          Navigator.pop(context);
        },
        onDelete: () {
          Navigator.pop(context);
          _deleteUser(user);
        },
      ),
    );
  }

  Future<void> _toggleBanUser(Map<String, dynamic> user) async {
    final uid = user['uid'];
    final isBanned = user['banned'] == true;
    try {
      await _database.child('users/$uid/banned').set(!isBanned);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(isBanned ? 'User unbanned successfully' : 'User banned'),
        backgroundColor: isBanned ? Colors.green : Colors.orange,
      ));
      _loadUsers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    final name = user['name'] ?? 'this user';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('Confirm Delete'),
          ],
        ),
        content: Text(
          'Delete "$name" permanently? This will delete their account and ALL related orders, order history, chats, and notifications. This action CANNOT be undone!',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    // Show loading overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: _primary),
                  SizedBox(height: 16),
                  Text(
                    'Deleting user & all data...',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      // 1. Delete user profile
      await _database.child('users/$uid').remove();

      // 2. Delete user chats
      await _database.child(_tenantPath('chats/$uid')).remove();

      // 3. Delete user notifications queue
      await _database.child(_tenantPath('notifications/user/$uid')).remove();

      // 4. Delete merchant profiles (if any)
      await _database.child(_tenantPath('merchant_profiles/$uid')).remove();
      await _database.child('merchant_profiles/$uid').remove();

      // 5. Delete from shop-orders
      final shopOrdersRef = _database.child(_tenantPath('shop-orders'));
      final shopOrdersSnap = await shopOrdersRef.get();
      if (shopOrdersSnap.exists && shopOrdersSnap.value is Map) {
        final orders = Map<dynamic, dynamic>.from(shopOrdersSnap.value as Map);
        for (final entry in orders.entries) {
          final orderId = entry.key.toString();
          final orderData = entry.value;
          if (orderData is Map && orderData['userId']?.toString() == uid) {
            await shopOrdersRef.child(orderId).remove();
          }
        }
      }

      // 6. Delete from custom-orders
      final customOrdersRef = _database.child(_tenantPath('custom-orders'));
      final customOrdersSnap = await customOrdersRef.get();
      if (customOrdersSnap.exists && customOrdersSnap.value is Map) {
        final orders = Map<dynamic, dynamic>.from(customOrdersSnap.value as Map);
        for (final entry in orders.entries) {
          final orderId = entry.key.toString();
          final orderData = entry.value;
          if (orderData is Map && orderData['userId']?.toString() == uid) {
            await customOrdersRef.child(orderId).remove();
          }
        }
      }

      // 7. Delete from order-history
      final historyRef = _database.child(_tenantPath('order-history'));
      final historySnap = await historyRef.get();
      if (historySnap.exists && historySnap.value is Map) {
        final history = Map<dynamic, dynamic>.from(historySnap.value as Map);
        for (final entry in history.entries) {
          final historyId = entry.key.toString();
          final historyData = entry.value;
          if (historyData is Map && historyData['userId']?.toString() == uid) {
            await historyRef.child(historyId).remove();
          }
        }
      }

      // Hide loading overlay
      if (mounted) Navigator.pop(context);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$name" and all related data deleted successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }

      // Reload
      await _loadUsers();
      await _loadOrderCounts();
    } catch (e) {
      // Hide loading overlay
      if (mounted) Navigator.pop(context);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _makeRider(Map<String, dynamic> user) async {
    final uid = user['uid'];
    final name = user['name'] ?? 'this user';
    final userCity = (user['userCity'] ?? '').toString().toLowerCase();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Make Rider'),
        content: Text('Promote $name to Rider for city ${userCity.isNotEmpty ? userCity : 'unknown'}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _database.child('users/$uid').update({
        'role': 'rider',
        'riderAssignedAt': ServerValue.timestamp,
        'userCity': userCity,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('User promoted to rider'),
          backgroundColor: Colors.green,
        ));
      }
      _loadUsers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _deleteAllUsers() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red, size: 24),
          SizedBox(width: 8),
          Text('Delete All Users'),
        ]),
        content: Text(
          'This will permanently delete ALL ${_allUsers.length} users from the database. Admin accounts will be preserved.\n\nThis action cannot be undone!',
          style: TextStyle(color: Colors.grey[600], height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        // Delete non-admin users only
        int deleted = 0;
        for (final user in _allUsers) {
          if (user['role'] != 'admin') {
            await _database.child('users/${user['uid']}').remove();
            deleted++;
          }
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$deleted users deleted successfully'),
            backgroundColor: Colors.green,
          ));
        }
        _loadUsers();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _searchController.text.toLowerCase();
    final searchMatchUsers = _allUsers.where((u) {
      return q.isEmpty ||
          (u['name'] ?? '').toLowerCase().contains(q) ||
          (u['email'] ?? '').toLowerCase().contains(q) ||
          (u['phoneNumber'] ?? '').toLowerCase().contains(q);
    }).toList();

    final totalCount = searchMatchUsers.length;
    final orderedCount = searchMatchUsers.where((u) => (_userOrderCounts[u['uid']] ?? 0) > 0).length;
    final customersCount = searchMatchUsers.where((u) => u['role'] != 'admin').length;
    final bannedCount = searchMatchUsers.where((u) => u['banned'] == true).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('User Management',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadUsers),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (val) {
              if (val == 'delete_all') _deleteAllUsers();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'delete_all',
                child: Row(children: [
                  Icon(Icons.delete_sweep, size: 18, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Delete All Users', style: TextStyle(color: Colors.red)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Stats
          Container(
            color: Colors.white,
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  _statChip('Total', '$totalCount', 'all', Colors.blueGrey),
                  const SizedBox(width: 8),
                  _statChip('Ordered', '$orderedCount', 'ordered', const Color(0xFF4CAF50)),
                  const SizedBox(width: 8),
                  _statChip('Customers', '$customersCount', 'customers', const Color(0xFFFF6B00)),
                  const SizedBox(width: 8),
                  _statChip('Banned', '$bannedCount', 'banned', Colors.red),
                ],
              ),
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search users...',
                prefixIcon: const Icon(Icons.search, color: _primary),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          // List
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: _primary))
                : _filteredUsers.isEmpty
                    ? const Center(
                        child: Text('No users found',
                            style: TextStyle(color: Colors.grey)))
                    : RefreshIndicator(
                        color: _primary,
                        onRefresh: _loadUsers,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: _filteredUsers.length,
                          itemBuilder: (ctx, i) {
                            final user = _filteredUsers[i];
                            return _buildUserTile(user);
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, String filterValue, Color color) {
    final isSelected = _selectedFilter == filterValue;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedFilter = filterValue;
        });
        _filter();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color : color.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : color.withValues(alpha: 0.2),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label: ',
              style: TextStyle(
                color: isSelected ? Colors.white : color.withValues(alpha: 0.8),
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                fontSize: 12,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: isSelected ? Colors.white : color,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserTile(Map<String, dynamic> user) {
    final name = user['name'] ?? 'Unknown';
    final email = user['email'] ?? '';
    final phone = user['phoneNumber'] ?? '';
    final role = user['role'] ?? 'customer';
    final isBanned = user['banned'] == true;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';
    final uid = user['uid'] ?? '';
    final orderCount = _userOrderCounts[uid] ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      child: InkWell(
        onTap: () => _showUserDetails(user),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: isBanned
                      ? Colors.red[50]
                      : _primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(initial,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: isBanned ? Colors.red : _primary,
                      )),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(width: 6),
                        if (role == 'admin')
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('ADMIN',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: _primary,
                                    fontWeight: FontWeight.w800)),
                          ),
                        if (isBanned)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red[50],
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('BANNED',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.red,
                                    fontWeight: FontWeight.w800)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            email.isNotEmpty ? email : phone,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[500]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: orderCount > 0
                                ? const Color(0xFF4CAF50).withValues(alpha: 0.1)
                                : Colors.grey.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Orders: $orderCount',
                            style: TextStyle(
                              fontSize: 10,
                              color: orderCount > 0
                                  ? const Color(0xFF4CAF50)
                                  : Colors.grey[600],
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
                onSelected: (val) {
                  if (val == 'make_rider') _makeRider(user);
                },
                itemBuilder: (_) {
                  // Only allow making rider if adminCity matches user's city and user is not already rider/admin
                  final userCity = (user['userCity'] ?? '').toString().toLowerCase();
                  final userRole = (user['role'] ?? 'customer').toString().toLowerCase();
                  final canMakeRider = _adminCity != null && _adminCity == userCity && userRole != 'rider' && userRole != 'admin';
                  if (!canMakeRider) {
                    return <PopupMenuEntry<String>>[];
                  }
                  return [
                    const PopupMenuItem(
                        value: 'make_rider',
                        child: Row(children: [Icon(Icons.pedal_bike, size: 16), SizedBox(width: 8), Text('Make Rider')])),
                  ];
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserDetailsSheet extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback onBan;
  final VoidCallback onDelete;
  final int orderCount;

  const _UserDetailsSheet({
    required this.user,
    required this.onBan,
    required this.onDelete,
    required this.orderCount,
  });

  @override
  Widget build(BuildContext context) {
    final name = user['name'] ?? 'Unknown';
    final email = user['email'] ?? 'N/A';
    final phone = user['phoneNumber'] ?? 'N/A';
    final role = user['role'] ?? 'customer';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';
    final isBanned = user['banned'] == true;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B00).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(initial,
                  style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFFFF6B00))),
            ),
          ),
          const SizedBox(height: 12),
          Text(name,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800)),
          Text(role.toUpperCase(),
              style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          const SizedBox(height: 20),
          _row(Icons.email_outlined, 'Email', email),
          _row(Icons.phone_outlined, 'Phone', phone),
          _row(Icons.shopping_bag_outlined, 'Total Orders', '$orderCount'),
          _row(Icons.key_outlined, 'UID', user['uid'] ?? 'N/A'),
          if (isBanned)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(children: [
                Icon(Icons.warning, color: Colors.red, size: 16),
                SizedBox(width: 8),
                Text('This account is banned',
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))
              ]),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onBan,
              style: ElevatedButton.styleFrom(
                backgroundColor: isBanned ? Colors.green : Colors.orange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(isBanned ? 'Unban User' : 'Ban User',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onDelete,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.delete_forever_rounded, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Delete Account & Data',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 10),
          Text('$label: ',
              style: const TextStyle(
                  color: Colors.grey, fontWeight: FontWeight.w500, fontSize: 13)),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
