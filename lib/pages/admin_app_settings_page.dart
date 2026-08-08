import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/city_scope_service.dart';
import '../services/app_version_service.dart';
import '../services/image_helper.dart';
import '../services/image_upload_service.dart';
import 'admin_settings/admin_popups_page.dart';
import 'admin_category_images_page.dart';
import 'admin_settings/admin_locations_page.dart';
import 'admin_settings/admin_support_settings_page.dart';
import 'admin_settings/admin_advanced_settings_page.dart';


class AdminAppSettingsPage extends StatefulWidget {
  const AdminAppSettingsPage({super.key});

  @override
  State<AdminAppSettingsPage> createState() => _AdminAppSettingsPageState();
}

class _AdminAppSettingsPageState extends State<AdminAppSettingsPage>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFFFF6B00);
  static const String _adPlacementBanner = 'banner';
  static const String _adPlacementTrendingFirst = 'trending_first_card';
  static const String _defaultSupportPhone = '+92 313 1426498';
  static const String _defaultSupportEmail = 'ghartekinfo@gmail.com';
  static const String _manualFcmKeyPref = 'manual_fcm_server_key';
  final ImagePicker _imagePicker = ImagePicker();

  final _db = FirebaseDatabase.instance.ref();
  late TabController _tabController;

  // ── Fees State ────────────────────────────────────────────────────────────────
  final _deliveryFeeCtrl = TextEditingController();
  final _instantDeliveryFeeCtrl = TextEditingController();
  final _fastDeliveryFeeCtrl = TextEditingController();
  final _taxPercentCtrl = TextEditingController();
  final _freeDeliveryAboveCtrl = TextEditingController();
  final _standardTimeCtrl = TextEditingController();
  final _fastTimeCtrl = TextEditingController();
  final _highQueueThresholdCtrl = TextEditingController();
  final _queuePositionTextCtrl = TextEditingController();
  final _queueUpdatingTextCtrl = TextEditingController();
  final _queueActiveOrdersTextCtrl = TextEditingController();
  final _queueHighLoadTextCtrl = TextEditingController();
  bool _freeDeliveryEnabled = false;

  bool _appTemporarilyClosed = false;

  bool _loyaltyPointsEnabled = true;
  bool _instantDeliveryEnabled = true;
  bool _showOrderQueueInfo = true;
  bool _randomShopsEnabled = true;
  bool _isIslamabadTenant = false;

  final _boysHostelCtrl = TextEditingController();
  final _girlsHostelCtrl = TextEditingController();
  final _boysRoomCtrl = TextEditingController();
  final _girlsRoomCtrl = TextEditingController();
  final _departmentCtrl = TextEditingController();

  final _boysRoomEndCtrl = TextEditingController();

  final _girlsRoomEndCtrl = TextEditingController();

  bool _feesLoading = true;
  bool _feesSaving = false;

  bool _versionPublishing = false;
  bool _isSuperAdmin = false;

  // ── Promo Codes State ─────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _promoCodes = [];
  bool _promoLoading = true;

  // ── Payment Methods State ─────────────────────────────────────────────────────
  List<Map<String, dynamic>> _paymentMethods = [];
  bool _paymentLoading = true;

  // ── Ads State ─────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _ads = [];
  bool _adsLoading = true;
  final Set<int> _uploadingAdIndexes = <int>{};
  final Map<int, Map<String, TextEditingController>> _adControllers = {};

  void _syncAdControllers() {
    for (final ctrls in _adControllers.values) {
      for (final c in ctrls.values) {
        c.dispose();
      }
    }
    _adControllers.clear();
    for (var i = 0; i < _ads.length; i++) {
      final ad = _ads[i];
      _adControllers[i] = {
        'image': TextEditingController(text: ad['imageUrl']?.toString() ?? ''),
        'title': TextEditingController(text: ad['title']?.toString() ?? ''),
        'subtitle':
            TextEditingController(text: ad['subtitle']?.toString() ?? ''),
        'link': TextEditingController(text: ad['linkUrl']?.toString() ?? ''),
      };
    }
  }

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    Future(() async {
      await CityScopeService.ensureLoaded();
      if (!mounted) return;
      setState(() {
        _isIslamabadTenant =
            CityScopeService.normalizeCity(CityScopeService.currentCity) ==
            CityScopeService.islamabad;
      });
    });
    _resolveSuperAdmin();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        switch (_tabController.index) {
          case 0:
            _loadFees();
            break;
          case 1:
            _loadPromoCodes();
            break;
          case 2:
            _loadPaymentMethods();
            break;
          case 3:
            _loadAds();
            break;
        }
      }
    });
    _loadFees();
    _loadPromoCodes();
    _loadPaymentMethods();
    _loadAds();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _deliveryFeeCtrl.dispose();
    _instantDeliveryFeeCtrl.dispose();
    _fastDeliveryFeeCtrl.dispose();
    _taxPercentCtrl.dispose();
    _freeDeliveryAboveCtrl.dispose();
    _standardTimeCtrl.dispose();
    _fastTimeCtrl.dispose();
    _highQueueThresholdCtrl.dispose();
    _queuePositionTextCtrl.dispose();
    _queueUpdatingTextCtrl.dispose();
    _queueActiveOrdersTextCtrl.dispose();
    _queueHighLoadTextCtrl.dispose();
    _boysHostelCtrl.dispose();
    _girlsHostelCtrl.dispose();
    _boysRoomCtrl.dispose();
    _girlsRoomCtrl.dispose();
    _departmentCtrl.dispose();
    _boysRoomEndCtrl.dispose();
    _girlsRoomEndCtrl.dispose();
    for (final ctrls in _adControllers.values) {
      for (final c in ctrls.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _snack(String msg, Color bg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: bg,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _resolveSuperAdmin() {
    final email = FirebaseAuth.instance.currentUser?.email?.toLowerCase();
    _isSuperAdmin = email == 'arshadahsan77900@gmail.com';
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

  void _addOptionToList({
    required TextEditingController controller,
    required List<String> list,
  }) {
    final value = controller.text.trim();
    if (value.isEmpty) return;
    final exists = list.any((item) => item.toLowerCase() == value.toLowerCase());
    if (!exists) {
      setState(() => list.add(value));
    }
    controller.clear();
  }

  List<String> _buildSequentialRoomNumbers(String startText, String endText) {
    final start = int.tryParse(startText.trim());
    final end = int.tryParse(endText.trim());
    if (start == null || end == null) return const <String>[];
    if (start <= 0 || end <= 0 || end < start) return const <String>[];
    return List<String>.generate(end - start + 1, (index) => '${start + index}');
  }

  Future<void> _publishCurrentAppVersion() async {
    if (_versionPublishing) return;
    setState(() => _versionPublishing = true);
    try {
      final currentVersion = await AppVersionService().getCurrentVersion();
      await AppVersionService().setVersionConfig(
        latest: currentVersion,
        minimum: currentVersion,
        message: 'Please update the app from the Play Store.',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Published version $currentVersion to Firebase.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to publish version: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _versionPublishing = false);
    }
  }

  void _removeOptionFromList({
    required String value,
    required List<String> list,
  }) {
    setState(() {
      list.removeWhere((item) => item.toLowerCase() == value.toLowerCase());
    });
  }

  // ── Fees ──────────────────────────────────────────────────────────────────────

  Future<void> _loadFees() async {
    setState(() => _feesLoading = true);
    try {
      await CityScopeService.ensureLoaded();
      _isIslamabadTenant =
          CityScopeService.normalizeCity(CityScopeService.currentCity) ==
          CityScopeService.islamabad;

      final snap = await _db.child(_tenantPath('settings/fees')).get();
      final appControlSnap =
          await _db.child(_tenantPath('settings/app-control')).get();

      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        _deliveryFeeCtrl.text = (data['deliveryFee'] ?? 50).toString();
        _instantDeliveryFeeCtrl.text =
            (data['instantDeliveryFee'] ?? 70).toString();
        _fastDeliveryFeeCtrl.text = (data['fastDeliveryFee'] ?? 100).toString();
        _taxPercentCtrl.text = (data['taxPercent'] ?? 3).toString();
        _freeDeliveryEnabled = _toBool(
          data['freeDeliveryEnabled'],
          fallback: false,
        );
        _freeDeliveryAboveCtrl.text = (data['freeDeliveryAbove'] ?? 0)
            .toString();
        _standardTimeCtrl.text = (data['standardTime'] ?? '30-45').toString();
        _fastTimeCtrl.text = (data['fastTime'] ?? '15-20').toString();
      } else {
        _deliveryFeeCtrl.text = '50';
        _instantDeliveryFeeCtrl.text = '70';
        _fastDeliveryFeeCtrl.text = '100';
        _taxPercentCtrl.text = '3';
        _freeDeliveryEnabled = false;
        _freeDeliveryAboveCtrl.text = '0';
        _standardTimeCtrl.text = '30-45';
        _fastTimeCtrl.text = '15-20';
      }

      if (appControlSnap.exists && appControlSnap.value is Map) {
        final appData = Map<String, dynamic>.from(appControlSnap.value as Map);
        _appTemporarilyClosed = appData['temporarilyClosed'] == true;
        _loyaltyPointsEnabled = _toBool(
          appData['loyaltyPointsEnabled'],
          fallback: true,
        );
        _instantDeliveryEnabled = _toBool(
          appData['instantDeliveryEnabled'],
          fallback: true,
        );
        _showOrderQueueInfo = _toBool(
          appData['showOrderQueueInfo'],
          fallback: true,
        );
        final thresholdRaw = appData['highQueueThreshold'];
        final threshold = thresholdRaw is int
            ? thresholdRaw
            : int.tryParse(thresholdRaw?.toString() ?? '') ?? 7;
        _highQueueThresholdCtrl.text = threshold.clamp(3, 50).toString();
        _queuePositionTextCtrl.text = (appData['queuePositionText'] ??
                'Your order is #{position} in the queue')
            .toString();
        _queueUpdatingTextCtrl.text = (appData['queueUpdatingText'] ??
                'Updating your queue position...')
            .toString();
        _queueActiveOrdersTextCtrl.text = (appData['queueActiveOrdersText'] ??
                'Active orders: {count}')
            .toString();
        _queueHighLoadTextCtrl.text = (appData['queueHighLoadText'] ??
                'Due to high demand, delivery may take 40–50 minutes.')
            .toString();
        _randomShopsEnabled = _toBool(
          appData['randomShopsEnabled'],
          fallback: true,
        );
      } else {
        _appTemporarilyClosed = false;
        _loyaltyPointsEnabled = true;
        _instantDeliveryEnabled = true;
        _showOrderQueueInfo = true;
        _highQueueThresholdCtrl.text = '7';
        _queuePositionTextCtrl.text = 'Your order is #{position} in the queue';
        _queueUpdatingTextCtrl.text = 'Updating your queue position...';
        _queueActiveOrdersTextCtrl.text = 'Active orders: {count}';
        _queueHighLoadTextCtrl.text =
            'Due to high demand, delivery may take 40–50 minutes.';
        _randomShopsEnabled = true;
      }
    } catch (_) {}
    if (mounted) setState(() => _feesLoading = false);
  }

  Future<void> _saveFees() async {
    setState(() => _feesSaving = true);
    try {
      await _db.child(_tenantPath('settings/fees')).set({
        'deliveryFee': double.tryParse(_deliveryFeeCtrl.text) ?? 50,
        'instantDeliveryFee':
            double.tryParse(_instantDeliveryFeeCtrl.text) ?? 70,
        'fastDeliveryFee': double.tryParse(_fastDeliveryFeeCtrl.text) ?? 100,
        'taxPercent': double.tryParse(_taxPercentCtrl.text) ?? 3,
        'freeDeliveryEnabled': _freeDeliveryEnabled,
        'freeDeliveryAbove': double.tryParse(_freeDeliveryAboveCtrl.text) ?? 0,
        'standardTime': _standardTimeCtrl.text.trim().isEmpty
            ? '30-45'
            : _standardTimeCtrl.text.trim(),
        'fastTime': _fastTimeCtrl.text.trim().isEmpty
            ? '15-20'
            : _fastTimeCtrl.text.trim(),
        'updatedAt': ServerValue.timestamp,
      });

      await _db.child(_tenantPath('settings/app-control')).update({
        'temporarilyClosed': _appTemporarilyClosed,
        'loyaltyPointsEnabled': _loyaltyPointsEnabled,
        'instantDeliveryEnabled': _instantDeliveryEnabled,
        'showOrderQueueInfo': _showOrderQueueInfo,
        'highQueueThreshold':
            int.tryParse(_highQueueThresholdCtrl.text.trim())?.clamp(3, 50) ??
            7,
        'queuePositionText': _queuePositionTextCtrl.text.trim().isEmpty
            ? 'Your order is #{position} in the queue'
            : _queuePositionTextCtrl.text.trim(),
        'queueUpdatingText': _queueUpdatingTextCtrl.text.trim().isEmpty
            ? 'Updating your queue position...'
            : _queueUpdatingTextCtrl.text.trim(),
        'queueActiveOrdersText': _queueActiveOrdersTextCtrl.text.trim().isEmpty
            ? 'Active orders: {count}'
            : _queueActiveOrdersTextCtrl.text.trim(),
        'queueHighLoadText': _queueHighLoadTextCtrl.text.trim().isEmpty
            ? 'Due to high demand, delivery may take 40–50 minutes.'
            : _queueHighLoadTextCtrl.text.trim(),
        'randomShopsEnabled': _randomShopsEnabled,
        'updatedAt': ServerValue.timestamp,
      });

      _snack('App settings saved successfully!', Colors.green);
    } catch (e) {
      _snack('Error saving settings: $e', Colors.red);
    }
    if (mounted) setState(() => _feesSaving = false);
  }

  Future<void> _loadPromoCodes() async {
    setState(() => _promoLoading = true);
    try {
      final snap = await _db.child(_tenantPath('settings/promo-codes')).get();
      final List<Map<String, dynamic>> codes = [];
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        data.forEach((key, val) {
          if (val is Map) {
            final m = Map<String, dynamic>.from(val);
            m['code'] = key.toString();
            codes.add(m);
          }
        });
      }
      if (mounted) {
        setState(() {
          _promoCodes = codes;
          _promoLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _promoLoading = false);
    }
  }

  void _showAddPromoDialog([Map<String, dynamic>? existing]) {
    final codeCtrl = TextEditingController(text: existing?['code'] ?? '');
    final valueCtrl = TextEditingController(
      text: existing?['value']?.toString() ?? '',
    );
    final maxPerUserCtrl = TextEditingController(
      text: existing?['maxPerUser']?.toString() ?? '1',
    );
    final minOrderCtrl = TextEditingController(
      text: existing?['minOrder']?.toString() ?? '0',
    );
    final maxDiscountCtrl = TextEditingController(
      text: existing?['maxDiscount']?.toString() ?? '',
    );
    String type = existing?['type'] ?? 'percent';
    bool enabled = existing?['enabled'] != false;
    DateTime? expiryDate = existing?['expiresAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(existing!['expiresAt'] as int)
        : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            existing == null ? 'Add Promo Code' : 'Edit Promo Code',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dialogField(
                  codeCtrl,
                  'Code (e.g. SAVE20)',
                  Icons.local_offer,
                  enabled: existing == null,
                  toUpper: true,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _dialogField(
                        valueCtrl,
                        'Discount Value',
                        Icons.percent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: type,
                      onChanged: (v) => setS(() => type = v!),
                      items: const [
                        DropdownMenuItem(value: 'percent', child: Text('%')),
                        DropdownMenuItem(value: 'flat', child: Text('Rs.')),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _dialogField(
                  minOrderCtrl,
                  'Min Order (Rs.)',
                  Icons.shopping_cart,
                ),
                const SizedBox(height: 12),
                _dialogField(maxPerUserCtrl, 'Max Uses per User', Icons.person),
                if (type == 'percent') ...[
                  const SizedBox(height: 12),
                  _dialogField(
                    maxDiscountCtrl,
                    'Max Discount Rs. (optional)',
                    Icons.money_off,
                  ),
                ],
                const SizedBox(height: 12),
                // Expiry date
                GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate:
                          expiryDate ??
                          DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setS(() => expiryDate = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          color: Colors.grey[500],
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          expiryDate != null
                              ? 'Expires: ${expiryDate!.day}/${expiryDate!.month}/${expiryDate!.year}'
                              : 'Set expiry date (optional)',
                          style: TextStyle(
                            color: expiryDate != null
                                ? Colors.black87
                                : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Enabled',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  value: enabled,
                  activeThumbColor: _primary,
                  onChanged: (v) => setS(() => enabled = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                final code = codeCtrl.text.trim().toUpperCase();
                if (code.isEmpty) return;
                await _db
                    .child(_tenantPath('settings/promo-codes'))
                    .child(code)
                    .set({
                      'value': double.tryParse(valueCtrl.text) ?? 0,
                      'type': type,
                      'minOrder': double.tryParse(minOrderCtrl.text) ?? 0,
                      'maxPerUser': int.tryParse(maxPerUserCtrl.text) ?? 1,
                      if (maxDiscountCtrl.text.isNotEmpty)
                        'maxDiscount':
                            double.tryParse(maxDiscountCtrl.text) ?? 9999,
                      if (expiryDate != null)
                        'expiresAt': expiryDate!.millisecondsSinceEpoch,
                      'enabled': enabled,
                      'createdAt': ServerValue.timestamp,
                    });
                _snack('Promo code saved!', Colors.green);
                _loadPromoCodes();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dialogField(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool enabled = true,
    bool toUpper = false,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      textCapitalization:
          toUpper ? TextCapitalization.characters : TextCapitalization.none,
      keyboardType: TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _deletePromoCode(String code) async {
    await _db.child(_tenantPath('settings/promo-codes')).child(code).remove();
    _snack('Promo code deleted', Colors.red);
    _loadPromoCodes();
  }

  // ── Payment Methods ──────────────────────────────────────────────────────────

  Future<void> _loadPaymentMethods() async {
    setState(() => _paymentLoading = true);
    try {
      final snap = await _db
          .child(_tenantPath('settings/payment-methods'))
          .get();
      final defaults = [
        {'key': 'cod', 'label': 'Cash on Delivery', 'enabled': true},
        {'key': 'jazzcash', 'label': 'JazzCash', 'enabled': false},
        {'key': 'easypaisa', 'label': 'Easypaisa', 'enabled': false},
        {'key': 'bank', 'label': 'Bank Transfer', 'enabled': false},
      ];
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final List<Map<String, dynamic>> methods = [];
        // merge defaults with saved
        for (final d in defaults) {
          final key = d['key'] as String;
          if (data.containsKey(key) && data[key] is Map) {
            final m = Map<String, dynamic>.from(data[key] as Map);
            m['key'] = key;
            m['label'] ??= d['label'];
            methods.add(m);
          } else {
            methods.add(Map<String, dynamic>.from(d));
          }
        }
        // add any custom ones from Firebase
        data.forEach((key, val) {
          if (!defaults.any((d) => d['key'] == key) && val is Map) {
            final m = Map<String, dynamic>.from(val);
            m['key'] = key.toString();
            methods.add(m);
          }
        });
        if (mounted) {
          setState(() {
            _paymentMethods = methods;
            _paymentLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _paymentMethods = List<Map<String, dynamic>>.from(defaults);
            _paymentLoading = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _paymentLoading = false);
    }
  }

  Future<void> _togglePayment(String key, bool value) async {
    await _db.child(_tenantPath('settings/payment-methods')).child(key).update({
      'enabled': value,
    });
    _loadPaymentMethods();
  }

  Future<void> _updatePaymentLabel(String key, String label) async {
    await _db.child(_tenantPath('settings/payment-methods')).child(key).update({
      'label': label,
      'enabled': true,
    });
    _snack('Payment method updated', Colors.green);
    _loadPaymentMethods();
  }

  // ── Ads ───────────────────────────────────────────────────────────────────────

  Future<void> _loadAds() async {
    setState(() => _adsLoading = true);
    try {
      final snap = await _db.child(_tenantPath('settings/ads')).get();
      final List<Map<String, dynamic>> ads = [];
      final data = snap.exists && snap.value is Map
          ? Map<String, dynamic>.from(snap.value as Map)
          : <String, dynamic>{};

      Map<String, dynamic>? legacyTrending;
      data.forEach((_, value) {
        if (value is! Map) return;
        final normalized = _normalizeAdRecord(Map<String, dynamic>.from(value));
        final placement = (normalized['placement'] ?? _adPlacementBanner)
            .toString();
        if (placement == _adPlacementTrendingFirst && legacyTrending == null) {
          legacyTrending = normalized;
        }
      });

      for (int i = 0; i < 4; i++) {
        final key = 'ad$i';
        Map<String, dynamic> slot;

        if (data[key] is Map) {
          slot = _normalizeAdRecord(
            Map<String, dynamic>.from(data[key] as Map),
          );
        } else if (i == 3 && legacyTrending != null) {
          slot = Map<String, dynamic>.from(legacyTrending!);
        } else {
          slot = {
            'imageUrl': '',
            'title': '',
            'subtitle': '',
            'fit': 'cover',
            'alignment': 'center',
            'linkUrl': '',
            'enabled': true,
          };
        }

        slot['_key'] = key;
        slot['placement'] = i == 3
            ? _adPlacementTrendingFirst
            : _adPlacementBanner;
        slot['enabled'] = _toBool(slot['enabled'], fallback: true);
        ads.add(slot);
      }

      if (mounted) {
        setState(() {
          _ads = ads;
          _adsLoading = false;
        });
        _syncAdControllers();
      }
    } catch (_) {
      if (mounted) setState(() => _adsLoading = false);
    }
  }

  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> raw) {
    return {
      'imageUrl': (raw['imageUrl'] ?? '').toString(),
      'title': (raw['title'] ?? '').toString(),
      'subtitle': (raw['subtitle'] ?? '').toString(),
      'fit': (raw['fit'] ?? 'cover').toString(),
      'alignment': (raw['alignment'] ?? 'center').toString(),
      'linkUrl': (raw['linkUrl'] ?? '').toString(),
      'placement': (raw['placement'] ?? _adPlacementBanner).toString(),
      'enabled': _toBool(raw['enabled'], fallback: true),
    };
  }

  Future<void> _saveAd(
    int index,
    String imageUrl,
    String title,
    String subtitle,
    String fit,
    String alignment,
    String linkUrl,
    bool enabled,
  ) async {
    final normalizedImageUrl = ImageUploadService.normalizeImageUrl(imageUrl);
    if (normalizedImageUrl.isNotEmpty &&
        !ImageUploadService.isCloudinaryUrl(normalizedImageUrl)) {
      _snack(
        'Use Cloudinary URL for ad image or upload using Upload Ad Image.',
        Colors.red,
      );
      return;
    }

    final cleanedLink = linkUrl.trim();
    final placement = index == 3
        ? _adPlacementTrendingFirst
        : _adPlacementBanner;

    final key = _ads[index]['_key'] ?? 'ad$index';
    await _db.child(_tenantPath('settings/ads')).child(key.toString()).set({
      'imageUrl': normalizedImageUrl,
      'title': title,
      'subtitle': subtitle,
      'fit': fit,
      'alignment': alignment,
      'placement': placement,
      'linkUrl': cleanedLink,
      'enabled': enabled,
      'updatedAt': ServerValue.timestamp,
    });
    _snack('Ad ${index + 1} saved!', Colors.green);
    _loadAds();
  }

  bool _toBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final text = (value ?? '').trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  bool _isServiceAccountJson(String value) {
    final raw = value.trim();
    if (raw.isEmpty || !raw.startsWith('{')) return false;
    return raw.contains('"private_key"') &&
        raw.contains('"client_email"') &&
        raw.contains('"project_id"');
  }

  Future<void> _uploadAdImage(int index, TextEditingController imageCtrl) async {
    if (_uploadingAdIndexes.contains(index)) return;
    setState(() => _uploadingAdIndexes.add(index));
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null) return;
      final result = await ImageUploadService.uploadImage(
        file: picked,
        useCase: ImageUploadUseCase.ad,
      );
      imageCtrl.text = result.url;
      if (mounted) setState(() {});
      _snack('Ad image uploaded!', Colors.green);
    } catch (e) {
      _snack('Upload failed: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _uploadingAdIndexes.remove(index));
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: _primary,
        ),
      ),
    );
  }

  InputDecoration _inputDecor(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: _primary, size: 20),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _primary, width: 2),
      ),
    );
  }

  Widget _inputCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildSettingsTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.05),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: _primary, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: Colors.grey[400]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeesTab() {
    if (_feesLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('Delivery Fee (Rs.)'),
          _inputCard(
            child: TextField(
              controller: _deliveryFeeCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 50', Icons.delivery_dining),
            ),
          ),
          const SizedBox(height: 14),
          _sectionLabel('Fast Delivery Fee (Rs.)'),
          _inputCard(
            child: TextField(
              controller: _fastDeliveryFeeCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 100', Icons.flash_on_rounded),
            ),
          ),
          const SizedBox(height: 14),
          _sectionLabel('Tax Percent (%)'),
          _inputCard(
            child: TextField(
              controller: _taxPercentCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 3', Icons.receipt_long_rounded),
            ),
          ),
          const SizedBox(height: 14),
          _sectionLabel('Standard Delivery Time'),
          _inputCard(
            child: TextField(
              controller: _standardTimeCtrl,
              decoration: _inputDecor('e.g. 30-45 min', Icons.schedule),
            ),
          ),
          const SizedBox(height: 14),
          _sectionLabel('Fast Delivery Time'),
          _inputCard(
            child: TextField(
              controller: _fastTimeCtrl,
              decoration: _inputDecor('e.g. 15-20 min', Icons.timer),
            ),
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Free Delivery Enabled'),
            value: _freeDeliveryEnabled,
            activeThumbColor: _primary,
            onChanged: (v) => setState(() => _freeDeliveryEnabled = v),
          ),
          if (_freeDeliveryEnabled) ...[
            const SizedBox(height: 8),
            _sectionLabel('Free Delivery Above (Rs.)'),
            _inputCard(
              child: TextField(
                controller: _freeDeliveryAboveCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    _inputDecor('e.g. 500', Icons.card_giftcard_rounded),
              ),
            ),
          ],
          const Divider(height: 32),
          _sectionLabel('App Controls'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Temporarily Close App'),
            subtitle: const Text('Users cannot place orders'),
            value: _appTemporarilyClosed,
            activeThumbColor: Colors.red,
            onChanged: (v) => setState(() => _appTemporarilyClosed = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Loyalty Points'),
            value: _loyaltyPointsEnabled,
            activeThumbColor: _primary,
            onChanged: (v) => setState(() => _loyaltyPointsEnabled = v),
          ),
          if (_isIslamabadTenant) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Instant Delivery'),
              subtitle: const Text(
                'Show 20-minute instant delivery to Islamabad users',
              ),
              value: _instantDeliveryEnabled,
              activeThumbColor: _primary,
              onChanged: (v) => setState(() => _instantDeliveryEnabled = v),
            ),
            if (_instantDeliveryEnabled) ...[
              const SizedBox(height: 8),
              _sectionLabel('Instant Delivery Fee (Rs.)'),
              _inputCard(
                child: TextField(
                  controller: _instantDeliveryFeeCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _inputDecor('e.g. 70', Icons.bolt_rounded),
                ),
              ),
            ],
            const Divider(height: 24),
            _sectionLabel('Islamabad Order Queue'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show Order Queue to Customers'),
              subtitle: const Text('Only for Islamabad customers'),
              value: _showOrderQueueInfo,
              activeThumbColor: _primary,
              onChanged: (v) => setState(() => _showOrderQueueInfo = v),
            ),
            const SizedBox(height: 8),
            _sectionLabel('High Queue Threshold'),
            _inputCard(
              child: TextField(
                controller: _highQueueThresholdCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDecor(
                  'e.g. 7 or 8 active orders',
                  Icons.queue_rounded,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'When active orders exceed the threshold, customers see the high-load message below.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
            const SizedBox(height: 12),
            _sectionLabel('Queue Position Message'),
            _inputCard(
              child: TextField(
                controller: _queuePositionTextCtrl,
                decoration: _inputDecor(
                  'Your order is #{position} in the queue',
                  Icons.format_list_numbered_rounded,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _sectionLabel('Queue Updating Message'),
            _inputCard(
              child: TextField(
                controller: _queueUpdatingTextCtrl,
                decoration: _inputDecor(
                  'Updating your queue position...',
                  Icons.hourglass_top_rounded,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _sectionLabel('Active Orders Label'),
            _inputCard(
              child: TextField(
                controller: _queueActiveOrdersTextCtrl,
                decoration: _inputDecor(
                  'Active orders: {count}',
                  Icons.numbers_rounded,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _sectionLabel('High Load Message'),
            _inputCard(
              child: TextField(
                controller: _queueHighLoadTextCtrl,
                maxLines: 2,
                decoration: _inputDecor(
                  'Delivery may take 40–50 minutes...',
                  Icons.schedule_rounded,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Use {position} or #{position} for queue number, and {count} for active orders.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Random Shops on Home'),
            value: _randomShopsEnabled,
            activeThumbColor: _primary,
            onChanged: (v) => setState(() => _randomShopsEnabled = v),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _feesSaving ? null : _saveFees,
              icon: _feesSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.save_rounded),
              label: Text(_feesSaving ? 'Saving...' : 'Save App Settings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (_isSuperAdmin) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _versionPublishing ? null : _publishCurrentAppVersion,
                icon: const Icon(Icons.system_update_alt),
                label: Text(
                  _versionPublishing
                      ? 'Publishing...'
                      : 'Publish Current App Version',
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          const Text(
            'More Settings',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _buildSettingsTile(
            title: 'Popups & Messages',
            subtitle: 'Close message, startup popup, checkout instructions',
            icon: Icons.message_outlined,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminPopupsPage()),
            ),
          ),
          if (_isIslamabadTenant)
            _buildSettingsTile(
              title: 'Home Categories',
              subtitle: 'Add dashboard categories with images',
              icon: Icons.category_outlined,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AdminCategoryImagesPage(),
                ),
              ),
            ),
          if (_isIslamabadTenant)
            _buildSettingsTile(
              title: 'Locations Database',
              subtitle: 'Hostels, rooms and departments',
              icon: Icons.location_on_outlined,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AdminLocationsPage(),
                ),
              ),
            ),
          _buildSettingsTile(
            title: 'Support & Contacts',
            subtitle: 'Phone numbers and emails for support',
            icon: Icons.headset_mic_outlined,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AdminSupportSettingsPage(),
              ),
            ),
          ),
          _buildSettingsTile(
            title: 'Advanced Settings',
            subtitle: 'FCM key, rider limits, data cleanup',
            icon: Icons.settings_applications_outlined,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AdminAdvancedSettingsPage(),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildPromosTab() {
    if (_promoLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showAddPromoDialog(),
              icon: const Icon(Icons.add),
              label: const Text('Add Promo Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: _promoCodes.isEmpty
              ? Center(
                  child: Text(
                    'No promo codes yet',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _promoCodes.length,
                  itemBuilder: (ctx, i) {
                    final p = _promoCodes[i];
                    final code = p['code']?.toString() ?? '';
                    final type = p['type']?.toString() ?? 'percent';
                    final value = p['value']?.toString() ?? '0';
                    final enabled = p['enabled'] != false;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        title: Text(
                          code,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          type == 'percent' ? '$value% off' : 'Rs. $value off',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              enabled ? Icons.check_circle : Icons.cancel,
                              color: enabled ? Colors.green : Colors.red,
                              size: 20,
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _showAddPromoDialog(p),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                              onPressed: () => _deletePromoCode(code),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPaymentTab() {
    if (_paymentLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Enable or disable payment methods for customers',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),
        ..._paymentMethods.map((m) {
          final key = m['key']?.toString() ?? '';
          final label = m['label']?.toString() ?? key;
          final enabled = m['enabled'] == true;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: SwitchListTile(
              title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              value: enabled,
              activeThumbColor: _primary,
              onChanged: (v) => _togglePayment(key, v),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildAdsTab() {
    if (_adsLoading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _ads.length,
      itemBuilder: (ctx, index) {
        final ad = _ads[index];
        final ctrls = _adControllers[index];
        if (ctrls == null) return const SizedBox.shrink();
        final enabled = ad['enabled'] == true;
        final placement =
            index == 3 ? 'Trending First Card' : 'Banner ${index + 1}';
        final uploading = _uploadingAdIndexes.contains(index);

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      placement,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: enabled,
                      activeThumbColor: _primary,
                      onChanged: (v) {
                        setState(() {
                          _ads[index] = {..._ads[index], 'enabled': v};
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrls['image'],
                  decoration:
                      _inputDecor('Image URL (Cloudinary)', Icons.image),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: uploading
                      ? null
                      : () => _uploadAdImage(index, ctrls['image']!),
                  icon: uploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload),
                  label: Text(uploading ? 'Uploading...' : 'Upload Ad Image'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrls['title'],
                  decoration: _inputDecor('Title', Icons.title),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrls['subtitle'],
                  decoration: _inputDecor('Subtitle', Icons.subtitles),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrls['link'],
                  decoration: _inputDecor('Link URL (optional)', Icons.link),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => _saveAd(
                      index,
                      ctrls['image']!.text,
                      ctrls['title']!.text,
                      ctrls['subtitle']!.text,
                      'cover',
                      'center',
                      ctrls['link']!.text,
                      _ads[index]['enabled'] == true,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Save Ad'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('App Settings'),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'Fees & Control'),
            Tab(text: 'Promo Codes'),
            Tab(text: 'Payments'),
            Tab(text: 'Ads'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFeesTab(),
          _buildPromosTab(),
          _buildPaymentTab(),
          _buildAdsTab(),
        ],
      ),
    );
  }
}