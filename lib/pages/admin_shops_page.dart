import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:image_picker/image_picker.dart';
import '../services/auth_service.dart';
import '../services/category_timing_service.dart';
import '../services/city_scope_service.dart';
import '../services/image_helper.dart';
import '../services/image_upload_service.dart';
import 'admin_products_page.dart';

class AdminShopsPage extends StatefulWidget {
  const AdminShopsPage({super.key});

  @override
  State<AdminShopsPage> createState() => _AdminShopsPageState();
}

class _AdminShopsPageState extends State<AdminShopsPage> {
  final _database = FirebaseDatabase.instance.ref();
  final AuthService _authService = AuthService();
  final _searchController = TextEditingController();
  String _tenantPathForCity(String path, String city) =>
      CityScopeService.tenantPath(path, city: city);

  List<Map<String, dynamic>> _shops = [];
  List<Map<String, dynamic>> _filteredShops = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadShops();
    _searchController.addListener(_filterShops);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String> _resolveActiveAdminCity() async {
    await CityScopeService.ensureLoaded();
    final uid = _authService.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return CityScopeService.currentCity;
    }

    final syncedCity = await _authService.syncAdminCityScopeForCurrentUser(
      uid: uid,
    );
    if (syncedCity != null && syncedCity.isNotEmpty) {
      return CityScopeService.normalizeCity(syncedCity);
    }
    return CityScopeService.currentCity;
  }

  Future<void> _loadShops() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final activeCity = await _resolveActiveAdminCity();
      final snapshot = await _database
          .child(_tenantPathForCity('shops', activeCity))
          .get();
      List<Map<String, dynamic>> shopsList = [];

      if (snapshot.exists) {
        final shopsData = snapshot.value as Map<dynamic, dynamic>;
        shopsData.forEach((key, value) {
          Map<String, dynamic> shop = Map<String, dynamic>.from(value);
          final shopCity = CityScopeService.normalizeCity(
            (shop['city'] ?? activeCity).toString(),
          );
          if (shopCity != activeCity) {
            return;
          }
          shop['id'] = key;
          shop['city'] = shopCity;
          shopsList.add(shop);
        });
      }

      setState(() {
        _shops = shopsList;
        _filteredShops = shopsList;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading shops: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _filterShops() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredShops = _shops;
      } else {
        _filteredShops = _shops.where((shop) {
          final name = (shop['name'] ?? '').toLowerCase();
          final category = (shop['category'] ?? '').toLowerCase();
          return name.contains(query) || category.contains(query);
        }).toList();
      }
    });
  }

  Future<void> _deleteShop(
    String shopId,
    String shopName, {
    String? city,
  }) async {
    final normalizedShopId = shopId.trim();
    if (normalizedShopId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid shop id. Please refresh and try again.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Shop'),
        content: Text('Are you sure you want to delete "$shopName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!mounted) return;
      try {
        final activeCity = await _resolveActiveAdminCity();
        final targetCity = CityScopeService.normalizeCity(city ?? activeCity);

        if (targetCity != activeCity) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cross-city delete blocked. You can only delete ${CityScopeService.cityLabel(activeCity)} shops.',
              ),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }

        final shopRef = _database
            .child(_tenantPathForCity('shops', targetCity))
            .child(normalizedShopId);

        final beforeDelete = await shopRef.get();
        if (!beforeDelete.exists) {
          throw Exception(
            'Shop not found in ${CityScopeService.cityLabel(targetCity)} records.',
          );
        }

        await shopRef.remove();

        final afterDelete = await shopRef.get();
        if (afterDelete.exists) {
          throw Exception('Delete failed. Please try again.');
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$shopName deleted successfully'),
            backgroundColor: Colors.green,
          ),
        );
        _loadShops(); // Reload shops
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting shop: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _toggleShopVisibility(Map<String, dynamic> shop) async {
    final targetShopId = (shop['id'] ?? '').toString().trim();
    if (targetShopId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to update visibility. Please refresh.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final currentVisible = shop['isVisible'] != false;
    final nextVisible = !currentVisible;
    final targetCity = CityScopeService.normalizeCity(
      (shop['city'] ?? CityScopeService.currentCity).toString(),
    );

    try {
      await _database
          .child(_tenantPathForCity('shops', targetCity))
          .child(targetShopId)
          .update({
            'isVisible': nextVisible,
            'updatedAt': ServerValue.timestamp,
          });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextVisible
                ? 'Shop is now visible to users.'
                : 'Shop is now hidden from users.',
          ),
          backgroundColor: nextVisible ? Colors.green : Colors.orange,
        ),
      );
      _loadShops();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating visibility: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showAddShopDialog([Map<String, dynamic>? shopToEdit]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ShopFormPage(
          shopToEdit: shopToEdit,
          activeCity: CityScopeService.currentCity,
          onSaved: _loadShops,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      appBar: AppBar(
        title: const Text(
          'Manage Shops',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        backgroundColor: const Color(0xFFFF6B00),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadShops,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddShopDialog,
        backgroundColor: const Color(0xFFFF6B00),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'Add Shop',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Column(
        children: [
          // Search Bar
          Container(
            color: const Color(0xFFFF6B00),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search shops...',
                  hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Color(0xFFFF6B00),
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.close_rounded,
                            color: Colors.grey[400],
                            size: 18,
                          ),
                          onPressed: () => _searchController.clear(),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),
          ),

          // Count header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text(
                  '${_filteredShops.length} shops',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // Shops List
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFF6B00)),
                  )
                : _filteredShops.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.store_outlined,
                          size: 72,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No shops found',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[400],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                    itemCount: _filteredShops.length,
                    itemBuilder: (context, index) {
                      final shop = _filteredShops[index];
                      final shopImage = (shop['imageUrl'] ?? shop['logo'] ?? '')
                          .toString();
                      final isOpen = shop['isOpen'] == true;
                      final isVisible = shop['isVisible'] != false;
                      final rating = shop['rating']?.toString() ?? '';
                      final deliveryTime =
                          shop['deliveryTime']?.toString() ?? '';
                      final standardDeliveryFeeOverride = double.tryParse(
                        (shop['deliveryFeeStandard'] ?? '').toString(),
                      );
                      final fastDeliveryFeeOverride = double.tryParse(
                        (shop['deliveryFeeFast'] ?? '').toString(),
                      );
                      final hasDeliveryFeeOverride =
                          standardDeliveryFeeOverride != null ||
                          fastDeliveryFeeOverride != null;
                      final category = shop['category'] ?? '';
                      final cityLabel = CityScopeService.cityLabel(
                        (shop['city'] ?? CityScopeService.currentCity)
                            .toString(),
                      );
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Shop image
                            ClipRRect(
                              borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(18),
                              ),
                              child: SizedBox(
                                width: 90,
                                height: 100,
                                child: shopImage.isNotEmpty
                                    ? ImageHelper.networkImage(
                                        url: shopImage,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        color: const Color(
                                          0xFFFF6B00,
                                        ).withValues(alpha: 0.08),
                                        child: const Icon(
                                          Icons.storefront_rounded,
                                          size: 36,
                                          color: Color(0xFFFF6B00),
                                        ),
                                      ),
                              ),
                            ),
                            // Info
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  8,
                                  10,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            shop['name'] ?? 'Unknown Shop',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 14,
                                              color: Color(0xFF1A1A1A),
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if ((double.tryParse((shop['rating'] ?? '0').toString()) ?? 0) > 0)
                                          Flexible(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(Icons.star_rounded, color: Colors.orange, size: 14),
                                                const SizedBox(width: 2),
                                                Flexible(
                                                  child: Text(
                                                    (shop['rating'] ?? '0').toString(),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    if (category.isNotEmpty)
                                      Text(
                                        category,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFFFF6B00,
                                        ).withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        cityLabel,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFFFF6B00),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        // Open/Closed chip
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isOpen
                                                ? Colors.green.withValues(
                                                    alpha: 0.1,
                                                  )
                                                : Colors.red.withValues(
                                                    alpha: 0.1,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                width: 5,
                                                height: 5,
                                                decoration: BoxDecoration(
                                                  color: isOpen
                                                      ? Colors.green
                                                      : Colors.red,
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                isOpen ? 'Open' : 'Closed',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: isOpen
                                                      ? Colors.green[700]
                                                      : Colors.red[700],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isVisible
                                                ? Colors.blue.withValues(
                                                    alpha: 0.1,
                                                  )
                                                : Colors.grey.withValues(
                                                    alpha: 0.15,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                isVisible
                                                    ? Icons.visibility_rounded
                                                    : Icons
                                                          .visibility_off_rounded,
                                                size: 11,
                                                color: isVisible
                                                    ? Colors.blue[700]
                                                    : Colors.grey[700],
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                isVisible
                                                    ? 'Visible'
                                                    : 'Hidden',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: isVisible
                                                      ? Colors.blue[700]
                                                      : Colors.grey[700],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (rating.isNotEmpty)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.star_rounded,
                                                size: 13,
                                                color: Color(0xFFFFB300),
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                rating,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        if (deliveryTime.isNotEmpty)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.access_time_rounded,
                                                size: 13,
                                                color: Colors.grey[500],
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                '${deliveryTime}m',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey[600],
                                                ),
                                              ),
                                            ],
                                          ),
                                        if (hasDeliveryFeeOverride)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.local_shipping_rounded,
                                                size: 13,
                                                color: Colors.teal[600],
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                'N/F ${standardDeliveryFeeOverride?.toStringAsFixed(0) ?? '-'}/${fastDeliveryFeeOverride?.toStringAsFixed(0) ?? '-'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  color: Colors.teal[700],
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Actions menu
                            PopupMenuButton<String>(
                              icon: Icon(
                                Icons.more_vert_rounded,
                                color: Colors.grey[500],
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              onSelected: (value) {
                                if (value == 'products') {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          AdminProductsPage(shop: shop),
                                    ),
                                  ).then((_) => _loadShops());
                                } else if (value == 'visibility') {
                                  _toggleShopVisibility(shop);
                                } else if (value == 'edit') {
                                  _showAddShopDialog(shop);
                                } else if (value == 'delete') {
                                  final targetShopId = (shop['id'] ?? '')
                                      .toString()
                                      .trim();
                                  if (targetShopId.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Unable to delete this shop. Please refresh.',
                                        ),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                    return;
                                  }
                                  _deleteShop(
                                    targetShopId,
                                    shop['name'] ?? 'Shop',
                                    city:
                                        (shop['city'] ??
                                                CityScopeService.currentCity)
                                            .toString(),
                                  );
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'products',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.fastfood_rounded,
                                        color: Color(0xFFFF6B00),
                                        size: 20,
                                      ),
                                      SizedBox(width: 10),
                                      Text(
                                        'Manage Products',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'visibility',
                                  child: Row(
                                    children: [
                                      Icon(
                                        isVisible
                                            ? Icons.visibility_off_rounded
                                            : Icons.visibility_rounded,
                                        color: const Color(0xFFFF6B00),
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        isVisible
                                            ? 'Hide from Users'
                                            : 'Show to Users',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.edit_rounded,
                                        color: Color(0xFFFF6B00),
                                        size: 20,
                                      ),
                                      SizedBox(width: 10),
                                      Text(
                                        'Edit Shop',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.delete_rounded,
                                        color: Colors.red[400],
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        'Delete',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Colors.red[400],
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
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHOP FORM PAGE — full screen with live card preview + image upload
// ─────────────────────────────────────────────────────────────────────────────

class _ShopFormPage extends StatefulWidget {
  final Map<String, dynamic>? shopToEdit;
  final String activeCity;
  final VoidCallback onSaved;
  const _ShopFormPage({
    this.shopToEdit,
    required this.activeCity,
    required this.onSaved,
  });

  @override
  State<_ShopFormPage> createState() => _ShopFormPageState();
}

class _ShopFormPageState extends State<_ShopFormPage> {
  static const Color _primary = Color(0xFFFF6B00);
  final ImagePicker _imagePicker = ImagePicker();
  final AuthService _authService = AuthService();

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _imageUrlCtrl = TextEditingController();
  final _ratingCtrl = TextEditingController();
  final _deliveryCtrl = TextEditingController();
  final _deliveryFeeStandardCtrl = TextEditingController();
  final _deliveryFeeFastCtrl = TextEditingController();
  final _openTimeCtrl = TextEditingController();
  final _closeTimeCtrl = TextEditingController();
  final List<_ShopTimingSlotDraft> _timingSlots = <_ShopTimingSlotDraft>[];
  final _merchantOwnerCtrl = TextEditingController();
  final _merchantEmailCtrl = TextEditingController();
  final _merchantPasswordCtrl = TextEditingController();
  final _merchantNewPasswordCtrl = TextEditingController();
  String _extraChargeType = 'none'; // 'none', 'percent', 'fixed'
  final _extraChargeValueCtrl = TextEditingController();
  String _category = 'Food';
  bool _isOpen = true;
  bool _isVisible = true;
  bool _isPopular = false;
  List<String> _closedDays = [];
  bool _createAccount = true;
  bool _isUploadingImage = false;
  bool _isUploadingBanner = false;
  bool _isMerchantActionLoading = false;
  String _shopCity = CityScopeService.defaultCity;

  String _tenantPathForCity(String path, String city) =>
      CityScopeService.tenantPath(path, city: city);

  String _linkedMerchantId = '';
  String _linkedMerchantName = '';
  String _linkedMerchantEmail = '';
  String _linkedMerchantPhone = '';

  bool get _hasLinkedMerchant => _linkedMerchantId.isNotEmpty;

  String get _editingCity => CityScopeService.normalizeCity(
    (widget.shopToEdit?['city'] ?? widget.activeCity).toString(),
  );

  // Image state
  String _previewUrl = ''; // URL shown in the live preview
  BoxFit _imageFit = BoxFit.cover;

  // Banner state
  final _bannerUrlCtrl = TextEditingController();
  String _bannerPreviewUrl = '';

  @override
  void initState() {
    super.initState();
    final s = widget.shopToEdit;
    if (s != null) {
      final creds = s['merchantCredentials'] is Map
          ? Map<String, dynamic>.from(s['merchantCredentials'] as Map)
          : <String, dynamic>{};

      _nameCtrl.text = s['name'] ?? '';
      _descCtrl.text = s['description'] ?? '';
      _addressCtrl.text = s['address'] ?? '';
      _phoneCtrl.text = s['phone'] ?? '';
      _imageUrlCtrl.text = s['imageUrl'] ?? '';
      _previewUrl = (s['imageUrl'] ?? '').toString().trim();
      _ratingCtrl.text = (s['rating'] ?? 4.0).toString();
      _deliveryCtrl.text = (s['deliveryTime'] ?? 30).toString();
      _deliveryFeeStandardCtrl.text = (s['deliveryFeeStandard'] ?? '')
          .toString();
      _deliveryFeeFastCtrl.text = (s['deliveryFeeFast'] ?? '').toString();
      _openTimeCtrl.text = s['openTime'] ?? '10:00 AM';
      _closeTimeCtrl.text = s['closeTime'] ?? '11:00 PM';

      _extraChargeType = s['extraChargeType'] ?? 'none';
      _extraChargeValueCtrl.text = (s['extraChargeValue'] ?? '').toString();

      _linkedMerchantId = (s['merchantId'] ?? '').toString();
      _linkedMerchantName = (s['merchantName'] ?? creds['ownerName'] ?? '')
          .toString();
      _linkedMerchantEmail = (s['merchantEmail'] ?? creds['email'] ?? '')
          .toString();
      _linkedMerchantPhone = (s['merchantPhone'] ?? '').toString();

      _merchantOwnerCtrl.text = _linkedMerchantName;
      _merchantEmailCtrl.text = _linkedMerchantEmail;
      _merchantPasswordCtrl.text = (creds['password'] ?? '').toString();

      _category = s['category'] ?? 'Food';
      _isOpen = s['isOpen'] ?? true;
      _isVisible = s['isVisible'] != false;
      _isPopular = s['isPopular'] ?? false;
      if (s['closedDays'] is List) {
        _closedDays = (s['closedDays'] as List).map((e) => e.toString()).toList();
      }
      _createAccount = _linkedMerchantId.isEmpty;
      _shopCity = CityScopeService.normalizeCity(
        (s['city'] ?? widget.activeCity).toString(),
      );
      _seedTimingSlots(_parseRawTimingSlots(s['timingSlots']));
      _bannerUrlCtrl.text = (s['bannerImage'] ?? '').toString();
      _bannerPreviewUrl = (s['bannerImage'] ?? '').toString().trim();
      final fit = (s['imageFit'] ?? 'cover').toString();
      _imageFit = fit == 'contain'
          ? BoxFit.contain
          : fit == 'fill'
          ? BoxFit.fill
          : BoxFit.cover;
    } else {
      _ratingCtrl.text = '4.0';
      _deliveryCtrl.text = '30';
      _deliveryFeeStandardCtrl.text = '';
      _deliveryFeeFastCtrl.text = '';
      _openTimeCtrl.text = '10:00 AM';
      _closeTimeCtrl.text = '11:00 PM';
      _extraChargeType = 'none';
      _extraChargeValueCtrl.text = '';
      _isVisible = true;
      _isPopular = false;
      _shopCity = CityScopeService.normalizeCity(widget.activeCity);
      _seedTimingSlots(const <Map<String, String>>[]);
    }
  }

  List<Map<String, String>> _parseRawTimingSlots(dynamic raw) {
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

  void _addTimingSlot({
    String openTime = '10:00 AM',
    String closeTime = '11:00 PM',
  }) {
    _timingSlots.add(
      _ShopTimingSlotDraft(openTime: openTime, closeTime: closeTime),
    );
  }

  void _seedTimingSlots(List<Map<String, String>> slots) {
    if (slots.isNotEmpty) {
      for (final slot in slots) {
        _addTimingSlot(
          openTime: slot['openTime'] ?? '10:00 AM',
          closeTime: slot['closeTime'] ?? '11:00 PM',
        );
      }
      _openTimeCtrl.text = slots.first['openTime'] ?? _openTimeCtrl.text;
      _closeTimeCtrl.text = slots.first['closeTime'] ?? _closeTimeCtrl.text;
      return;
    }

    final fallbackOpen = _openTimeCtrl.text.trim().isEmpty
        ? '10:00 AM'
        : _openTimeCtrl.text.trim();
    final fallbackClose = _closeTimeCtrl.text.trim().isEmpty
        ? '11:00 PM'
        : _closeTimeCtrl.text.trim();
    _addTimingSlot(openTime: fallbackOpen, closeTime: fallbackClose);
  }

  List<Map<String, String>>? _collectValidatedTimingSlots() {
    if (_timingSlots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add at least one opening slot.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return null;
    }

    final slots = <Map<String, String>>[];
    for (int i = 0; i < _timingSlots.length; i++) {
      final open = _timingSlots[i].openCtrl.text.trim();
      final close = _timingSlots[i].closeCtrl.text.trim();
      final slotNo = i + 1;

      if (open.isEmpty || close.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Slot #$slotNo requires both opening and closing time.',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return null;
      }

      final openMinutes = CategoryTimingService.parseTimeToMinutes(open);
      final closeMinutes = CategoryTimingService.parseTimeToMinutes(close);
      if (openMinutes == null || closeMinutes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Invalid time format in slot #$slotNo. Use format like 12:00 PM.',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return null;
      }

      slots.add({'openTime': open, 'closeTime': close});
    }

    return slots;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _imageUrlCtrl.dispose();
    _bannerUrlCtrl.dispose();
    _ratingCtrl.dispose();
    _deliveryCtrl.dispose();
    _deliveryFeeStandardCtrl.dispose();
    _deliveryFeeFastCtrl.dispose();
    _openTimeCtrl.dispose();
    _closeTimeCtrl.dispose();
    for (final slot in _timingSlots) {
      slot.dispose();
    }
    _merchantOwnerCtrl.dispose();
    _merchantEmailCtrl.dispose();
    _merchantPasswordCtrl.dispose();
    _merchantNewPasswordCtrl.dispose();
    _extraChargeValueCtrl.dispose();
    super.dispose();
  }

  bool _validateMerchantCreateInputs() {
    final owner = _merchantOwnerCtrl.text.trim();
    final email = _merchantEmailCtrl.text.trim();
    final password = _merchantPasswordCtrl.text.trim();
    if (owner.isEmpty || email.isEmpty || password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Merchant owner, email, and password (min 6 chars) are required.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }
    return true;
  }

  Future<void> _pickAndUploadShopImage() async {
    if (_isUploadingImage) return;

    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1920,
      );
      if (pickedFile == null) return;

      setState(() => _isUploadingImage = true);

      final result = await ImageUploadService.uploadImage(
        file: pickedFile,
        useCase: ImageUploadUseCase.shop,
      );

      if (!mounted) return;

      setState(() {
        _imageUrlCtrl.text = result.url;
        _previewUrl = result.url;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Shop image uploaded successfully.'),
          backgroundColor: _primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUploadingImage = false);
      }
    }
  }

  Future<void> _pickAndUploadBannerImage() async {
    if (_isUploadingBanner) return;

    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1920,
      );
      if (pickedFile == null) return;

      setState(() => _isUploadingBanner = true);

      final result = await ImageUploadService.uploadImage(
        file: pickedFile,
        useCase: ImageUploadUseCase.shop,
      );

      if (!mounted) return;

      setState(() {
        _bannerUrlCtrl.text = result.url;
        _bannerPreviewUrl = result.url;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Banner image uploaded successfully.'),
          backgroundColor: _primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUploadingBanner = false);
      }
    }
  }

  Future<void> _changeLinkedMerchantPassword(String shopId) async {
    final newPassword = _merchantNewPasswordCtrl.text.trim();
    if (newPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New password must be at least 6 characters.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isMerchantActionLoading = true);
    try {
      await _authService.changeShopMerchantPasswordByAdmin(
        shopId: shopId,
        newPassword: newPassword,
        city: _editingCity,
      );

      _merchantNewPasswordCtrl.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Merchant password updated successfully.'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isMerchantActionLoading = false);
    }
  }

  Future<void> _deleteLinkedMerchant(String shopId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Merchant Account'),
        content: const Text(
          'Merchant login, profile, and shop link will be removed permanently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isMerchantActionLoading = true);
    try {
      await _authService.deleteShopMerchantByAdmin(
        shopId: shopId,
        city: _editingCity,
      );

      if (!mounted) return;
      setState(() {
        _linkedMerchantId = '';
        _linkedMerchantName = '';
        _linkedMerchantEmail = '';
        _linkedMerchantPhone = '';
        _merchantOwnerCtrl.clear();
        _merchantEmailCtrl.clear();
        _merchantPasswordCtrl.clear();
        _merchantNewPasswordCtrl.clear();
        _createAccount = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Merchant account deleted and unlinked from shop.'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isMerchantActionLoading = false);
    }
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Shop name is required'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final normalizedImageUrl = ImageUploadService.normalizeImageUrl(
      _imageUrlCtrl.text,
    );
    if (normalizedImageUrl.isNotEmpty &&
        !ImageUploadService.isCloudinaryUrl(normalizedImageUrl)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please use Cloudinary image URL or upload via the Upload Shop Image button.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final shouldCreateMerchant = _createAccount && !_hasLinkedMerchant;
    if (shouldCreateMerchant && !_validateMerchantCreateInputs()) {
      return;
    }

    final isEditing = widget.shopToEdit != null;

    final standardFeeInput = _deliveryFeeStandardCtrl.text.trim();
    final fastFeeInput = _deliveryFeeFastCtrl.text.trim();
    final standardFeeOverride = standardFeeInput.isEmpty
        ? null
        : double.tryParse(standardFeeInput);
    final fastFeeOverride = fastFeeInput.isEmpty
        ? null
        : double.tryParse(fastFeeInput);

    if (standardFeeInput.isNotEmpty &&
        (standardFeeOverride == null || standardFeeOverride < 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Normal delivery fee override must be a valid non-negative number.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (fastFeeInput.isNotEmpty &&
        (fastFeeOverride == null || fastFeeOverride < 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Fast delivery fee override must be a valid non-negative number.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final validatedTimingSlots = _collectValidatedTimingSlots();
    if (validatedTimingSlots == null || validatedTimingSlots.isEmpty) {
      return;
    }

    _openTimeCtrl.text = validatedTimingSlots.first['openTime'] ?? '';
    _closeTimeCtrl.text = validatedTimingSlots.first['closeTime'] ?? '';

    final selectedShopCity = CityScopeService.normalizeCity(
      isEditing ? _editingCity : _shopCity,
    );

    final db = FirebaseDatabase.instance.ref();
    await CityScopeService.ensureLoaded();
    final fitStr = _imageFit == BoxFit.contain
        ? 'contain'
        : _imageFit == BoxFit.fill
        ? 'fill'
        : 'cover';
    final shopData = {
      'name': _nameCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'category': _category,
      'address': _addressCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'imageUrl': normalizedImageUrl,
      'imageFit': fitStr,
      'rating': double.tryParse(_ratingCtrl.text) ?? 4.0,
      'deliveryTime': int.tryParse(_deliveryCtrl.text) ?? 30,
      'deliveryFeeStandard': standardFeeOverride,
      'deliveryFeeFast': fastFeeOverride,
      'openTime': _openTimeCtrl.text.trim(),
      'closeTime': _closeTimeCtrl.text.trim(),
      'timingSlots': validatedTimingSlots,
      'closedDays': _closedDays,
      'isOpen': _isOpen,
      'isVisible': _isVisible,
      'isPopular': _isPopular,
      'bannerImage': ImageUploadService.normalizeImageUrl(_bannerUrlCtrl.text),
      'city': selectedShopCity,
      'extraChargeType': _extraChargeType,
      'extraChargeValue': double.tryParse(_extraChargeValueCtrl.text.trim()) ?? 0.0,
    };

    if (!isEditing) {
      if (standardFeeOverride == null) {
        shopData.remove('deliveryFeeStandard');
      }
      if (fastFeeOverride == null) {
        shopData.remove('deliveryFeeFast');
      }
    }

    DatabaseReference? createdShopRef;
    String shopId = '';

    try {
      if (isEditing) {
        shopId = widget.shopToEdit!['id'].toString();
        await db
            .child(_tenantPathForCity('shops', selectedShopCity))
            .child(shopId)
            .update(shopData);
      } else {
        shopData['createdAt'] = ServerValue.timestamp;
        createdShopRef = db
            .child(_tenantPathForCity('shops', selectedShopCity))
            .push();
        shopId = createdShopRef.key!;
        await createdShopRef.set(shopData);
      }

      if (shouldCreateMerchant) {
        await _authService.createShopLinkedMerchantByAdmin(
          shopId: shopId,
          ownerName: _merchantOwnerCtrl.text.trim(),
          email: _merchantEmailCtrl.text.trim(),
          phoneNumber: _phoneCtrl.text.trim(),
          password: _merchantPasswordCtrl.text.trim(),
          businessAddress: _addressCtrl.text.trim(),
          city: selectedShopCity,
        );
      }

      widget.onSaved();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              shouldCreateMerchant
                  ? (isEditing
                        ? 'Shop updated and merchant linked ✓'
                        : 'Shop and merchant account created ✓')
                  : (isEditing
                        ? 'Shop updated for ${CityScopeService.cityLabel(selectedShopCity)} ✓'
                        : 'Shop added for ${CityScopeService.cityLabel(selectedShopCity)} ✓'),
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (createdShopRef != null && shouldCreateMerchant) {
        try {
          await createdShopRef.remove();
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.shopToEdit != null;
    final editShopId = widget.shopToEdit?['id']?.toString() ?? '';
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F0),
      appBar: AppBar(
        title: Text(
          isEditing ? 'Edit Shop' : 'Add New Shop',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'SAVE',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── LIVE CARD PREVIEW ──────────────────────────────────────────
            _SectionHeader(
              icon: Icons.preview_rounded,
              label: 'Live Card Preview',
            ),
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 180,
                height: 220,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Expanded(
                      flex: 3,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(18),
                        ),
                        child: _buildPreviewImage(),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _nameCtrl.text.isEmpty
                                  ? 'Shop Name'
                                  : _nameCtrl.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: _isOpen ? Colors.green : Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _isOpen ? 'Open Now' : 'Closed',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _isOpen
                                        ? Colors.green[700]
                                        : Colors.red[700],
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
            ),

            const SizedBox(height: 20),

            // ── IMAGE SECTION ──────────────────────────────────────────────
            _SectionHeader(icon: Icons.image_rounded, label: 'Shop Image'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.orange[100]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Fit selector
                  Row(
                    children: [
                      const Text(
                        'Fit:',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ...[
                        ('Cover', BoxFit.cover),
                        ('Contain', BoxFit.contain),
                        ('Fill', BoxFit.fill),
                      ].map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              e.$1,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _imageFit == e.$2,
                            selectedColor: _primary,
                            labelStyle: TextStyle(
                              color: _imageFit == e.$2 ? Colors.white : null,
                              fontWeight: FontWeight.w600,
                            ),
                            onSelected: (_) => setState(() => _imageFit = e.$2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // URL input
                  TextField(
                    controller: _imageUrlCtrl,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) => setState(() {
                      _previewUrl = ImageUploadService.normalizeImageUrl(v);
                    }),
                    decoration: InputDecoration(
                      labelText: 'Cloudinary Image URL',
                      hintText: 'Paste Cloudinary URL or upload from gallery',
                      hintStyle: const TextStyle(fontSize: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(Icons.link_rounded, size: 18),
                      suffixIcon: _imageUrlCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () => setState(() {
                                _imageUrlCtrl.clear();
                                _previewUrl = '';
                              }),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isUploadingImage
                              ? null
                              : _pickAndUploadShopImage,
                          icon: _isUploadingImage
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload_rounded, size: 18),
                          label: Text(
                            _isUploadingImage
                                ? 'Uploading...'
                                : 'Upload Shop Image',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _primary,
                            side: const BorderSide(color: _primary),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _imageUrlCtrl.text.trim().isEmpty
                            ? null
                            : () => setState(() {
                                _imageUrlCtrl.clear();
                                _previewUrl = '';
                              }),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('Remove'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(color: Colors.red.shade200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── BANNER IMAGE SECTION ────────────────────────────────────────
            _SectionHeader(icon: Icons.panorama_rounded, label: 'Banner Image'),
            const SizedBox(height: 4),
            Text(
              'By default shop logo/image is used as banner. Upload a separate banner to customize.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.orange[100]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Banner preview
                  if (_bannerPreviewUrl.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        height: 120,
                        width: double.infinity,
                        child: ImageHelper.networkImage(
                          url: _bannerPreviewUrl,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: 120,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // URL input
                  TextField(
                    controller: _bannerUrlCtrl,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) => setState(() {
                      _bannerPreviewUrl = ImageUploadService.normalizeImageUrl(v);
                    }),
                    decoration: InputDecoration(
                      labelText: 'Banner Image URL (optional)',
                      hintText: 'Paste URL or upload from gallery',
                      hintStyle: const TextStyle(fontSize: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(Icons.link_rounded, size: 18),
                      suffixIcon: _bannerUrlCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () => setState(() {
                                _bannerUrlCtrl.clear();
                                _bannerPreviewUrl = '';
                              }),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isUploadingBanner
                              ? null
                              : _pickAndUploadBannerImage,
                          icon: _isUploadingBanner
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload_rounded, size: 18),
                          label: Text(
                            _isUploadingBanner
                                ? 'Uploading...'
                                : 'Upload Banner',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _primary,
                            side: const BorderSide(color: _primary),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _bannerUrlCtrl.text.trim().isEmpty
                            ? null
                            : () => setState(() {
                                _bannerUrlCtrl.clear();
                                _bannerPreviewUrl = '';
                              }),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('Remove'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(color: Colors.red.shade200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── MERCHANT ACCOUNT ───────────────────────────────────────────
            _SectionHeader(
              icon: Icons.person_add_rounded,
              label: 'Merchant Account',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.blue[100]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_hasLinkedMerchant) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.verified_user_rounded,
                            color: Colors.green,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Merchant account is linked to this shop',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.green,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Owner: ${_linkedMerchantName.isEmpty ? '-' : _linkedMerchantName}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Email: ${_linkedMerchantEmail.isEmpty ? '-' : _linkedMerchantEmail}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Phone: ${_linkedMerchantPhone.isEmpty ? '-' : _linkedMerchantPhone}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    if (isEditing) ...[
                      const SizedBox(height: 12),
                      _formField(
                        controller: _merchantNewPasswordCtrl,
                        label: 'New Password (min 6 chars)',
                        obscure: true,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed:
                                  _isMerchantActionLoading || editShopId.isEmpty
                                  ? null
                                  : () => _changeLinkedMerchantPassword(
                                      editShopId,
                                    ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                              ),
                              icon: _isMerchantActionLoading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.lock_reset_rounded),
                              label: const Text(
                                'Change Password',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _isMerchantActionLoading || editShopId.isEmpty
                                  ? null
                                  : () => _deleteLinkedMerchant(editShopId),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: BorderSide(color: Colors.red.shade300),
                              ),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: const Text('Delete Account'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ] else ...[
                    SwitchListTile(
                      value: _createAccount,
                      onChanged: (v) => setState(() => _createAccount = v),
                      title: const Text(
                        'Create Merchant Account',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      subtitle: const Text(
                        'Shop settings se merchant login setup hoga.',
                        style: TextStyle(fontSize: 11),
                      ),
                      activeThumbColor: Colors.blue,
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (_createAccount) ...[
                      const SizedBox(height: 10),
                      _formField(
                        controller: _merchantOwnerCtrl,
                        label: 'Owner Name',
                      ),
                      const SizedBox(height: 12),
                      _formField(
                        controller: _merchantEmailCtrl,
                        label: 'Email Address',
                        type: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      _formField(
                        controller: _merchantPasswordCtrl,
                        label: 'Login Password',
                        obscure: true,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isEditing
                            ? 'Save karne par is shop ke liye merchant account create ho jayega.'
                            : 'Shop add ke sath merchant account bhi create ho jayega.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── SHOP DETAILS ───────────────────────────────────────────────
            _SectionHeader(icon: Icons.store_rounded, label: 'Shop Details'),
            const SizedBox(height: 10),
            _formField(
              controller: _nameCtrl,
              label: 'Shop Name *',
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _formField(
              controller: _descCtrl,
              label: 'Description',
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: InputDecoration(
                labelText: 'Category *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
              items: const [
                DropdownMenuItem(value: 'Food', child: Text('Food')),
                DropdownMenuItem(value: 'Grocery', child: Text('Grocery')),
                DropdownMenuItem(value: 'Medicine', child: Text('Medicine')),
                DropdownMenuItem(value: 'Pharmacy', child: Text('Pharmacy')),
                DropdownMenuItem(
                  value: 'Restaurant',
                  child: Text('Restaurant'),
                ),
              ],
              onChanged: (v) => setState(() => _category = v ?? 'Food'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _shopCity,
              decoration: InputDecoration(
                labelText: 'City *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
              items: CityScopeService.supportedCities
                  .map(
                    (c) => DropdownMenuItem<String>(
                      value: c,
                      child: Text(CityScopeService.cityLabel(c)),
                    ),
                  )
                  .toList(),
              onChanged: isEditing
                  ? null
                  : (v) => setState(
                      () => _shopCity = CityScopeService.normalizeCity(v),
                    ),
            ),
            if (isEditing) ...[
              const SizedBox(height: 6),
              Text(
                'City change from edit is disabled. Create a new shop for another city.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 12),
            _formField(controller: _addressCtrl, label: 'Address', maxLines: 2),
            const SizedBox(height: 12),
            _formField(
              controller: _phoneCtrl,
              label: 'Phone Number',
              type: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _formField(
                    controller: _ratingCtrl,
                    label: 'Rating (1-5)',
                    type: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _formField(
                    controller: _deliveryCtrl,
                    label: 'Delivery Time (min)',
                    type: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _formField(
                    controller: _deliveryFeeStandardCtrl,
                    label: 'Normal Fee Override (Rs, optional)',
                    type: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _formField(
                    controller: _deliveryFeeFastCtrl,
                    label: 'Fast Fee Override (Rs, optional)',
                    type: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Leave blank to use global delivery fees from app settings.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _extraChargeType,
                    decoration: InputDecoration(
                      labelText: 'Extra Charge Type',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'none', child: Text('None')),
                      DropdownMenuItem(value: 'percent', child: Text('Percentage (%)')),
                      DropdownMenuItem(value: 'fixed', child: Text('Fixed Price (Rs)')),
                    ],
                    onChanged: (v) => setState(() => _extraChargeType = v ?? 'none'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: _formField(
                    controller: _extraChargeValueCtrl,
                    label: 'Extra Charge Value',
                    type: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Opening Time Slots',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Column(
                children: [
                  ...List.generate(_timingSlots.length, (index) {
                    final slot = _timingSlots[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == _timingSlots.length - 1 ? 0 : 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _formField(
                              controller: slot.openCtrl,
                              label: 'Open (e.g., 12:00 PM)',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _formField(
                              controller: slot.closeCtrl,
                              label: 'Close (e.g., 4:00 PM)',
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            tooltip: 'Remove Slot',
                            onPressed: _timingSlots.length <= 1
                                ? null
                                : () {
                                    setState(() {
                                      final removed = _timingSlots.removeAt(
                                        index,
                                      );
                                      removed.dispose();
                                    });
                                  },
                            icon: const Icon(Icons.delete_outline_rounded),
                            color: Colors.red,
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => _addTimingSlot());
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add Slot'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _primary,
                        side: const BorderSide(color: _primary),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Example: 12:00 AM - 4:00 PM, then 7:00 PM - 9:30 PM.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Closed Days (Weekends etc)',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                'Monday', 'Tuesday', 'Wednesday', 'Thursday', 
                'Friday', 'Saturday', 'Sunday'
              ].map((day) {
                final isSelected = _closedDays.contains(day);
                return FilterChip(
                  label: Text(day, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : Colors.black87)),
                  selected: isSelected,
                  selectedColor: _primary,
                  checkmarkColor: Colors.white,
                  onSelected: (bool selected) {
                    setState(() {
                      if (selected) {
                        _closedDays.add(day);
                      } else {
                        _closedDays.remove(day);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: SwitchListTile(
                title: const Text(
                  'Shop is Open',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                value: _isOpen,
                activeThumbColor: Colors.green,
                onChanged: (v) => setState(() => _isOpen = v),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: SwitchListTile(
                title: const Text(
                  'Show Shop to Users',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Off karne par user app me ye shop show nahi hogi.',
                  style: TextStyle(fontSize: 12),
                ),
                value: _isVisible,
                activeThumbColor: _primary,
                onChanged: (v) => setState(() => _isVisible = v),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: SwitchListTile(
                title: const Text(
                  'Popular Shop',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'On karne par ye shop Home Page ke Popular section me dikhegi.',
                  style: TextStyle(fontSize: 12),
                ),
                value: _isPopular,
                activeThumbColor: _primary,
                onChanged: (v) => setState(() => _isPopular = v),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  isEditing ? 'Update Shop' : 'Add Shop',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewImage() {
    if (_previewUrl.isNotEmpty) {
      return ImageHelper.networkImage(
        url: _previewUrl,
        fit: _imageFit,
        width: double.infinity,
        height: double.infinity,
        errorWidget: _placeholderImg(),
      );
    }
    return _placeholderImg();
  }

  Widget _placeholderImg() {
    return Container(
      color: Colors.orange[50],
      child: const Center(
        child: Icon(
          Icons.storefront_rounded,
          color: Color(0xFFFF6B00),
          size: 40,
        ),
      ),
    );
  }

  Widget _formField({
    required TextEditingController controller,
    required String label,
    int maxLines = 1,
    TextInputType type = TextInputType.text,
    void Function(String)? onChanged,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: type,
      maxLength: type == TextInputType.phone ? 11 : null,
      inputFormatters: type == TextInputType.phone ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)] : null,
      obscureText: obscure,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}

class _ShopTimingSlotDraft {
  _ShopTimingSlotDraft({
    String openTime = '10:00 AM',
    String closeTime = '11:00 PM',
  }) : openCtrl = TextEditingController(text: openTime),
       closeCtrl = TextEditingController(text: closeTime);

  final TextEditingController openCtrl;
  final TextEditingController closeCtrl;

  void dispose() {
    openCtrl.dispose();
    closeCtrl.dispose();
  }
}

// Small section header
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionHeader({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFFFF6B00)),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            color: Color(0xFFFF6B00),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}
