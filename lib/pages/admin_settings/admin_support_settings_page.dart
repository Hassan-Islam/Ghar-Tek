import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../../services/city_scope_service.dart';

class AdminSupportSettingsPage extends StatefulWidget {
  const AdminSupportSettingsPage({Key? key}) : super(key: key);

  @override
  State<AdminSupportSettingsPage> createState() => _AdminSupportSettingsPageState();
}

class _AdminSupportSettingsPageState extends State<AdminSupportSettingsPage> {
  static const Color _primary = Color(0xFF001B33);
  static const String _defaultSupportPhone = '03212886737';
  static const String _defaultSupportEmail = 'support@ghartek.com';

  final _supportPhoneCtrl = TextEditingController();
  final _supportWhatsAppCtrl = TextEditingController();
  final _supportEmailCtrl = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _supportPhoneCtrl.dispose();
    _supportWhatsAppCtrl.dispose();
    _supportEmailCtrl.dispose();
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
      final snap = await _db.child(_tenantPath('settings/fees')).get();
      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final supportPhone = (data['supportPhone'] ?? '').toString();
        final supportWhatsApp = (data['supportWhatsApp'] ?? '').toString();
        final supportEmail = (data['supportEmail'] ?? '').toString();

        _supportPhoneCtrl.text = supportPhone.isEmpty ? _defaultSupportPhone : supportPhone;
        _supportWhatsAppCtrl.text = supportWhatsApp.isEmpty ? _supportPhoneCtrl.text : supportWhatsApp;
        _supportEmailCtrl.text = supportEmail.isEmpty ? _defaultSupportEmail : supportEmail;
      } else {
        _supportPhoneCtrl.text = _defaultSupportPhone;
        _supportWhatsAppCtrl.text = _defaultSupportPhone;
        _supportEmailCtrl.text = _defaultSupportEmail;
      }
    } catch (e) {
      _snack('Error loading support settings: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    try {
      final supportPhone = _supportPhoneCtrl.text.trim().isEmpty ? _defaultSupportPhone : _supportPhoneCtrl.text.trim();
      final supportWhatsApp = _supportWhatsAppCtrl.text.trim().isEmpty ? supportPhone : _supportWhatsAppCtrl.text.trim();
      final supportEmail = _supportEmailCtrl.text.trim().isEmpty ? _defaultSupportEmail : _supportEmailCtrl.text.trim();

      await _db.child(_tenantPath('settings/fees')).update({
        'supportPhone': supportPhone,
        'supportWhatsApp': supportWhatsApp,
        'supportEmail': supportEmail,
      });
      _snack('Support settings saved successfully.', Colors.green);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        title: const Text(
          'Support & Contacts',
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
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFFEDD5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, color: Colors.orange, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'These support details are saved for ${CityScopeService.cityLabel(CityScopeService.currentCity)} only. Switch city to edit the other city.',
                            style: const TextStyle(fontSize: 13, color: Colors.orange),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sectionLabel('Call Support Number'),
                  _inputCard(
                    child: TextField(
                      controller: _supportPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: _inputDecor('e.g. 03212886737', Icons.phone),
                    ),
                  ),
                  _sectionLabel('WhatsApp Support Number'),
                  _inputCard(
                    child: TextField(
                      controller: _supportWhatsAppCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: _inputDecor('e.g. +923212886737', Icons.chat_bubble_outline),
                    ),
                  ),
                  _sectionLabel('Help Center Email'),
                  _inputCard(
                    child: TextField(
                      controller: _supportEmailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: _inputDecor('e.g. support@ghartek.com', Icons.email_outlined),
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
