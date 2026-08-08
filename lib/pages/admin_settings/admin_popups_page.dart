import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../../services/city_scope_service.dart';

class AdminPopupsPage extends StatefulWidget {
  const AdminPopupsPage({Key? key}) : super(key: key);

  @override
  State<AdminPopupsPage> createState() => _AdminPopupsPageState();
}

class _AdminPopupsPageState extends State<AdminPopupsPage> {
  static const Color _primary = Color(0xFF001B33);

  final _appCloseMessageCtrl = TextEditingController();
  final _startupPopupTitleCtrl = TextEditingController();
  final _startupPopupMessageCtrl = TextEditingController();
  final _checkoutInstructionCtrl = TextEditingController();

  bool _startupPopupEnabled = false;
  bool _checkoutInstructionEnabled = false;

  bool _isLoading = true;
  bool _isSaving = false;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  bool _toBool(dynamic val, {bool defaultVal = false}) {
    if (val == null) return defaultVal;
    if (val is bool) return val;
    final str = val.toString().toLowerCase();
    if (str == 'true' || str == '1') return true;
    if (str == 'false' || str == '0') return false;
    return defaultVal;
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _appCloseMessageCtrl.dispose();
    _startupPopupTitleCtrl.dispose();
    _startupPopupMessageCtrl.dispose();
    _checkoutInstructionCtrl.dispose();
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

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    try {
      final snap = await _db.child(_tenantPath('settings/app-control')).get();
      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        _appCloseMessageCtrl.text = (data['closePopupMessage'] ??
            'We are currently closed. Please check back later.').toString();
        
        _startupPopupEnabled = _toBool(data['startupPopupEnabled']);
        _startupPopupTitleCtrl.text = (data['startupPopupTitle'] ?? 'Koi bhi instructions').toString();
        _startupPopupMessageCtrl.text = (data['startupPopupMessage'] ?? '').toString();
        
        _checkoutInstructionEnabled = _toBool(data['checkoutInstructionEnabled']);
        _checkoutInstructionCtrl.text = (data['checkoutInstructionMessage'] ?? '').toString();
      } else {
        _appCloseMessageCtrl.text = 'We are currently closed. Please check back later.';
        _startupPopupEnabled = false;
        _startupPopupTitleCtrl.text = 'Koi bhi instructions';
        _startupPopupMessageCtrl.text = '';
        _checkoutInstructionEnabled = false;
        _checkoutInstructionCtrl.text = '';
      }
    } catch (e) {
      _snack('Error loading popup settings: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    try {
      await _db.child(_tenantPath('settings/app-control')).update({
        'closePopupMessage': _appCloseMessageCtrl.text.trim().isEmpty
            ? 'We are currently closed. Please check back later.'
            : _appCloseMessageCtrl.text.trim(),
        'startupPopupEnabled': _startupPopupEnabled,
        'startupPopupTitle': _startupPopupTitleCtrl.text.trim().isEmpty
            ? 'Koi bhi instructions'
            : _startupPopupTitleCtrl.text.trim(),
        'startupPopupMessage': _startupPopupMessageCtrl.text.trim(),
        'checkoutInstructionEnabled': _checkoutInstructionEnabled,
        'checkoutInstructionMessage': _checkoutInstructionCtrl.text.trim(),
      });
      _snack('Popup settings saved successfully.', Colors.green);
    } catch (e) {
      _snack('Unable to save settings: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 16),
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
      prefixIcon: Icon(icon, color: _primary),
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
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: child,
    );
  }

  Widget _headerCard(String title, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
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
        title: const Text(
          'Popups & Messages',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _headerCard('App Close Popup', Icons.remove_circle_outline_rounded, Colors.redAccent),
                  _sectionLabel('Close Popup Message (shown to users)'),
                  _inputCard(
                    child: TextField(
                      controller: _appCloseMessageCtrl,
                      maxLines: 3,
                      decoration: _inputDecor('e.g. We are closed right now.', Icons.message_outlined),
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  _headerCard('Customer App-Open Popup', Icons.open_in_browser_rounded, Colors.blue),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F7FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFD7E6FF)),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Show popup to customer immediately on app open',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                        Switch(
                          value: _startupPopupEnabled,
                          activeThumbColor: _primary,
                          onChanged: (v) => setState(() => _startupPopupEnabled = v),
                        ),
                      ],
                    ),
                  ),
                  _sectionLabel('Popup Title'),
                  _inputCard(
                    child: TextField(
                      controller: _startupPopupTitleCtrl,
                      decoration: _inputDecor('e.g. Eid Mubarak!', Icons.title),
                    ),
                  ),
                  _sectionLabel('Popup Message'),
                  _inputCard(
                    child: TextField(
                      controller: _startupPopupMessageCtrl,
                      maxLines: 4,
                      decoration: _inputDecor('e.g. 50% off on all orders today.', Icons.message),
                    ),
                  ),

                  const SizedBox(height: 32),
                  _headerCard('Checkout Instructions', Icons.shopping_cart_checkout_rounded, Colors.orange),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFFEDD5)),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Show admin instructions on checkout page',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                        Switch(
                          value: _checkoutInstructionEnabled,
                          activeThumbColor: Colors.orange,
                          onChanged: (v) => setState(() => _checkoutInstructionEnabled = v),
                        ),
                      ],
                    ),
                  ),
                  _sectionLabel('Checkout Message'),
                  _inputCard(
                    child: TextField(
                      controller: _checkoutInstructionCtrl,
                      maxLines: 4,
                      decoration: _inputDecor('e.g. Please enter exact location.', Icons.info_outline_rounded),
                    ),
                  ),

                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveSettings,
                      icon: _isSaving
                          ? const SizedBox(
                              height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.save_rounded),
                      label: Text(_isSaving ? 'Saving...' : 'Save Settings'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
    );
  }
}
