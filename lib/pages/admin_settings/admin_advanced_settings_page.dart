import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/city_scope_service.dart';

class AdminAdvancedSettingsPage extends StatefulWidget {
  const AdminAdvancedSettingsPage({Key? key}) : super(key: key);

  @override
  State<AdminAdvancedSettingsPage> createState() => _AdminAdvancedSettingsPageState();
}

class _AdminAdvancedSettingsPageState extends State<AdminAdvancedSettingsPage> {
  static const Color _primary = Color(0xFF001B33);
  static const String _manualFcmKeyPref = 'manual_fcm_server_key';

  final _maxActiveOrdersCtrl = TextEditingController();
  final _fcmServerKeyCtrl = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _cleanupBusy = false;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _maxActiveOrdersCtrl.dispose();
    _fcmServerKeyCtrl.dispose();
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

  String? _firstNonEmpty(List<String?> values) {
    for (final v in values) {
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  bool _isServiceAccountJson(String value) {
    final v = value.trim();
    return v.startsWith('{') && v.endsWith('}') && v.contains('project_id');
  }

  void _validateFcmCredentialOrThrow(String value) {
    final val = value.trim();
    if (val.isEmpty) return; // allow clearing
    if (_isServiceAccountJson(val)) {
      if (!val.contains('client_email') || !val.contains('private_key')) {
        throw Exception('Invalid Service Account JSON. Missing required fields.');
      }
    } else {
      if (val.length < 30) {
        throw Exception('Server key looks too short to be valid.');
      }
    }
  }

  Future<String> _resolveStoredFcmCredential() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final snap = await _db.child(_tenantPath('settings/app-control')).get();
      final globalSnap = await _db.child('settings/app-control').get();
      final List<String?> candidates = [];

      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        candidates.addAll([
          data['fcmServiceAccountJson']?.toString(),
          data['fcmHttpV1ServiceAccount']?.toString(),
          data['fcmServiceAccountKey']?.toString(),
          data['fcmServerKey']?.toString(),
          data['fcmLegacyServerKey']?.toString(),
          data['fcmPushServerKey']?.toString(),
        ]);
      }
      if (globalSnap.exists) {
        final data = Map<String, dynamic>.from(globalSnap.value as Map);
        candidates.addAll([
          data['fcmServiceAccountJson']?.toString(),
          data['fcmHttpV1ServiceAccount']?.toString(),
          data['fcmServiceAccountKey']?.toString(),
          data['fcmServerKey']?.toString(),
          data['fcmLegacyServerKey']?.toString(),
          data['fcmPushServerKey']?.toString(),
        ]);
      }
      candidates.add(prefs.getString(_manualFcmKeyPref));
      return _firstNonEmpty(candidates) ?? '';
    } catch (_) {
      return prefs.getString(_manualFcmKeyPref) ?? '';
    }
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final snap = await _db.child(_tenantPath('settings/app-control')).get();
      final globalSnap = await _db.child('settings/app-control').get();
      
      Map<String, dynamic> appData = {};
      Map<String, dynamic> globalAppData = {};
      
      if (snap.exists) appData = Map<String, dynamic>.from(snap.value as Map);
      if (globalSnap.exists) globalAppData = Map<String, dynamic>.from(globalSnap.value as Map);
      
      _maxActiveOrdersCtrl.text = (appData['maxActiveOrdersPerRider'] ?? globalAppData['maxActiveOrdersPerRider'] ?? 3).toString();
      
      final fcmCredential = _firstNonEmpty(<String?>[
        appData['fcmServiceAccountJson']?.toString(),
        appData['fcmHttpV1ServiceAccount']?.toString(),
        appData['fcmServiceAccountKey']?.toString(),
        appData['fcmServerKey']?.toString(),
        appData['fcmLegacyServerKey']?.toString(),
        appData['fcmPushServerKey']?.toString(),
        globalAppData['fcmServiceAccountJson']?.toString(),
        globalAppData['fcmHttpV1ServiceAccount']?.toString(),
        globalAppData['fcmServiceAccountKey']?.toString(),
        globalAppData['fcmServerKey']?.toString(),
        globalAppData['fcmLegacyServerKey']?.toString(),
        globalAppData['fcmPushServerKey']?.toString(),
      ]) ?? '';
      
      _fcmServerKeyCtrl.text = fcmCredential;
      
      if (_fcmServerKeyCtrl.text.trim().isEmpty) {
        _fcmServerKeyCtrl.text = (prefs.getString(_manualFcmKeyPref) ?? '');
      }

    } catch (e) {
      _snack('Error loading advanced settings: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final enteredFcmCredential = _fcmServerKeyCtrl.text.trim();
      final fcmCredential = enteredFcmCredential.isNotEmpty
          ? enteredFcmCredential
          : await _resolveStoredFcmCredential();
      
      _validateFcmCredentialOrThrow(fcmCredential);
      final isServiceAccountCredential = _isServiceAccountJson(fcmCredential);

      if (fcmCredential.isNotEmpty) {
        await prefs.setString(_manualFcmKeyPref, fcmCredential);
      } else {
        await prefs.remove(_manualFcmKeyPref);
      }

      await _db.child(_tenantPath('settings/app-control')).update({
        'maxActiveOrdersPerRider': int.tryParse(_maxActiveOrdersCtrl.text) ?? 3,
        'fcmServiceAccountJson': isServiceAccountCredential ? fcmCredential : '',
        'fcmHttpV1ServiceAccount': isServiceAccountCredential ? fcmCredential : '',
        'fcmServiceAccountKey': isServiceAccountCredential ? fcmCredential : '',
        'fcmServerKey': isServiceAccountCredential ? '' : fcmCredential,
        'fcmLegacyServerKey': isServiceAccountCredential ? '' : fcmCredential,
        'fcmPushServerKey': isServiceAccountCredential ? '' : fcmCredential,
      });

      // Keep a global fallback copy
      if (fcmCredential.isNotEmpty) {
        await _db.child('settings/app-control').update({
          'fcmServiceAccountJson': isServiceAccountCredential ? fcmCredential : '',
          'fcmHttpV1ServiceAccount': isServiceAccountCredential ? fcmCredential : '',
          'fcmServiceAccountKey': isServiceAccountCredential ? fcmCredential : '',
          'fcmServerKey': isServiceAccountCredential ? '' : fcmCredential,
          'fcmLegacyServerKey': isServiceAccountCredential ? '' : fcmCredential,
          'fcmPushServerKey': isServiceAccountCredential ? '' : fcmCredential,
        });
      }

      _snack('Advanced settings saved successfully.', Colors.green);
    } catch (e) {
      _snack('Unable to save settings: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Data Cleanup ─────────────────────────────────────────────────────────────

  Future<bool> _confirmCleanup({
    required String title,
    required String message,
    bool requireDeleteWord = false,
  }) async {
    final confirmCtrl = TextEditingController();
    bool allowed = !requireDeleteWord;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(Icons.warning_rounded, color: Colors.red),
              SizedBox(width: 8),
              Expanded(child: Text('Confirm Cleanup')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(color: Colors.grey[700], fontSize: 13),
              ),
              if (requireDeleteWord) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: confirmCtrl,
                  onChanged: (v) => setDialog(() {
                    allowed = v.trim().toUpperCase() == 'DELETE';
                  }),
                  decoration: InputDecoration(
                    labelText: 'Type DELETE to continue',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: allowed ? () => Navigator.pop(ctx, true) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete Data'),
            ),
          ],
        ),
      ),
    );

    confirmCtrl.dispose();
    return result == true;
  }

  Future<int> _deleteOrdersByStatus(Set<String> statuses) async {
    int deleted = 0;
    final nodes = ['shop-orders', 'custom-orders'];

    for (final node in nodes) {
      final ref = _db.child(_tenantPath(node));
      final snap = await ref.get();
      if (!snap.exists || snap.value is! Map) continue;

      final raw = snap.value as Map<dynamic, dynamic>;
      final Map<String, dynamic> updates = {};

      raw.forEach((key, value) {
        if (value is! Map) return;
        final order = Map<String, dynamic>.from(value);
        final status = (order['status'] ?? '').toString().toLowerCase();
        if (statuses.contains(status)) {
          if (status == 'cancelled' || status == 'canceled') {
            final orderId = key.toString();
            final orderType = node == 'custom-orders' ? 'custom' : 'shop';
            final historyKey = '${orderType}_$orderId';
            final payload = Map<String, dynamic>.from(order)
              ..['id'] = orderId
              ..['orderId'] = orderId
              ..['orderType'] = orderType
              ..['archivedAt'] = ServerValue.timestamp;
            _db.child(_tenantPath('order-history')).child(historyKey).set(payload);
          }
          updates[key.toString()] = null;
          deleted++;
        }
      });

      if (updates.isNotEmpty) {
        await ref.update(updates);
      }
    }
    return deleted;
  }

  Future<int> _deleteAllOrdersData() async {
    int deleted = 0;
    final nodes = ['shop-orders', 'custom-orders'];
    for (final node in nodes) {
      final ref = _db.child(_tenantPath(node));
      final snap = await ref.get();
      if (snap.exists && snap.value is Map) {
        deleted += (snap.value as Map<dynamic, dynamic>).length;
      }
      await ref.remove();
    }
    return deleted;
  }

  int _countDeepRecords(dynamic value) {
    if (value is! Map) return value == null ? 0 : 1;
    int total = 0;
    for (final entry in value.entries) {
      final child = entry.value;
      if (child is Map) {
        total += _countDeepRecords(child);
      } else {
        total += 1;
      }
    }
    return total;
  }

  Future<int> _deleteKhataData() async {
    final khataRef = _db.child(_tenantPath('khata'));
    final snap = await khataRef.get();
    final deleted = snap.exists ? _countDeepRecords(snap.value) : 0;
    await khataRef.remove();
    return deleted;
  }

  Future<void> _cleanupDeliveredAndCancelledOrders() async {
    if (_cleanupBusy) return;
    final confirmed = await _confirmCleanup(
      title: 'Delete Delivered + Cancelled Orders',
      message: 'This will remove order history and reduce Firebase usage. Active/pending orders will stay.',
    );
    if (!confirmed) return;

    setState(() => _cleanupBusy = true);
    try {
      final deleted = await _deleteOrdersByStatus({
        'delivered',
        'cancelled',
        'canceled',
        'rejected',
        'failed',
      });
      _snack('$deleted history orders deleted.', Colors.green);
    } catch (e) {
      _snack('Cleanup failed: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _cleanupBusy = false);
    }
  }

  Future<void> _cleanupAllOrdersAndKhataBase() async {
    if (_cleanupBusy) return;
    final confirmed = await _confirmCleanup(
      title: 'Delete ALL Orders Data',
      message: 'This removes shop-orders and custom-orders completely. Khata/cash numbers will reset because they depend on orders.',
      requireDeleteWord: true,
    );
    if (!confirmed) return;

    setState(() => _cleanupBusy = true);
    try {
      final deleted = await _deleteAllOrdersData();
      _snack('All orders deleted ($deleted records).', Colors.red);
    } catch (e) {
      _snack('Cleanup failed: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _cleanupBusy = false);
    }
  }

  Future<void> _cleanupKhataDataOnly() async {
    if (_cleanupBusy) return;
    final confirmed = await _confirmCleanup(
      title: 'Delete KHATA Data (Full Clean)',
      message: 'This will permanently delete all khata records (shop payments, expenses, owner entries) for current city.',
      requireDeleteWord: true,
    );
    if (!confirmed) return;

    setState(() => _cleanupBusy = true);
    try {
      final deleted = await _deleteKhataData();
      if (deleted <= 0) {
        _snack('No khata data found for current city.', Colors.green);
      } else {
        _snack('Khata data deleted ($deleted records).', Colors.red);
      }
    } catch (e) {
      _snack('Cleanup failed: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _cleanupBusy = false);
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 16),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _primary),
      ),
    );
  }

  InputDecoration _inputDecor(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: _primary),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _primary, width: 2)),
    );
  }

  Widget _inputCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: child,
    );
  }

  Widget _headerCard(String title, IconData icon, Color color) {
    return Row(
      children: [
        Container(width: 4, height: 20, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 10),
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        title: const Text('Advanced Settings', style: TextStyle(fontWeight: FontWeight.w800)),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _headerCard('Rider Active Orders Limit', Icons.delivery_dining_rounded, Colors.orange),
                  _sectionLabel('Maximum Active Orders (Shop) per Rider'),
                  _inputCard(
                    child: TextField(
                      controller: _maxActiveOrdersCtrl,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecor('e.g. 3', Icons.format_list_numbered_rounded),
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  _headerCard('FCM Push Key', Icons.notifications_active_rounded, Colors.blue),
                  _sectionLabel('FCM HTTP v1 Service Account JSON'),
                  _inputCard(
                    child: TextField(
                      controller: _fcmServerKeyCtrl,
                      maxLines: 5,
                      decoration: _inputDecor('Paste service_account.json contents here', Icons.key_rounded),
                    ),
                  ),

                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveSettings,
                      icon: _isSaving
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.save_rounded),
                      label: Text(_isSaving ? 'Saving...' : 'Save Settings'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),

                  const SizedBox(height: 48),
                  _headerCard('Data Cleanup (Firebase)', Icons.cleaning_services_rounded, Colors.red),
                  const SizedBox(height: 12),
                  Text(
                    'Warning: These actions are irreversible and will permanently delete data from the database.',
                    style: TextStyle(color: Colors.grey[700], fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _cleanupBusy ? null : _cleanupDeliveredAndCancelledOrders,
                      icon: _cleanupBusy ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.history_rounded),
                      label: const Text('Clear Delivered/Cancelled Orders'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange,
                        side: const BorderSide(color: Colors.orange),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _cleanupBusy ? null : _cleanupAllOrdersAndKhataBase,
                      icon: _cleanupBusy ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.delete_forever_rounded),
                      label: const Text('Delete ALL Orders Data (Hard Cleanup)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _cleanupBusy ? null : _cleanupKhataDataOnly,
                      icon: _cleanupBusy ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.money_off_rounded),
                      label: const Text('Delete KHATA Data (Full Clean)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}
