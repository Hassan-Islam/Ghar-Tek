import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../../services/city_scope_service.dart';

class AdminCustomOrdersPage extends StatefulWidget {
  const AdminCustomOrdersPage({Key? key}) : super(key: key);

  @override
  State<AdminCustomOrdersPage> createState() => _AdminCustomOrdersPageState();
}

class _AdminCustomOrdersPageState extends State<AdminCustomOrdersPage> {
  static const Color _primary = Color(0xFF001B33);

  final _customNormalFeeCtrl = TextEditingController();
  final _customFastFeeCtrl = TextEditingController();
  final _customNormalTimeCtrl = TextEditingController();
  final _customFastTimeCtrl = TextEditingController();
  final _customOrderOpenTimeCtrl = TextEditingController();
  final _customOrderCloseTimeCtrl = TextEditingController();

  bool _customOrderTemporarilyClosed = false;
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
    _customNormalFeeCtrl.dispose();
    _customFastFeeCtrl.dispose();
    _customNormalTimeCtrl.dispose();
    _customFastTimeCtrl.dispose();
    _customOrderOpenTimeCtrl.dispose();
    _customOrderCloseTimeCtrl.dispose();
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
        _customOrderTemporarilyClosed =
            data['customOrderTemporarilyClosed'] == true ||
                data['customOrderTemporarilyClosed']?.toString() == 'true';
        _customNormalFeeCtrl.text =
            (data['customDeliveryNormal'] ?? 150).toString();
        _customFastFeeCtrl.text =
            (data['customDeliveryFast'] ?? 200).toString();
        _customNormalTimeCtrl.text =
            (data['customNormalTime'] ?? '40-60').toString();
        _customFastTimeCtrl.text =
            (data['customFastTime'] ?? '20-30').toString();
        _customOrderOpenTimeCtrl.text =
            (data['customOrderOpenTime'] ?? '10:00 AM').toString();
        _customOrderCloseTimeCtrl.text =
            (data['customOrderCloseTime'] ?? '11:00 PM').toString();
      } else {
        _customNormalFeeCtrl.text = '150';
        _customFastFeeCtrl.text = '200';
        _customNormalTimeCtrl.text = '40-60';
        _customFastTimeCtrl.text = '20-30';
        _customOrderOpenTimeCtrl.text = '10:00 AM';
        _customOrderCloseTimeCtrl.text = '11:00 PM';
      }
    } catch (e) {
      _snack('Error loading custom order settings: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    try {
      await _db.child(_tenantPath('settings/app-control')).update({
        'customOrderTemporarilyClosed': _customOrderTemporarilyClosed,
        'customDeliveryNormal':
            double.tryParse(_customNormalFeeCtrl.text) ?? 150,
        'customDeliveryFast': double.tryParse(_customFastFeeCtrl.text) ?? 200,
        'customNormalTime': _customNormalTimeCtrl.text.trim().isEmpty
            ? '40-60'
            : _customNormalTimeCtrl.text.trim(),
        'customFastTime': _customFastTimeCtrl.text.trim().isEmpty
            ? '20-30'
            : _customFastTimeCtrl.text.trim(),
        'customOrderOpenTime': _customOrderOpenTimeCtrl.text.trim().isEmpty
            ? '10:00 AM'
            : _customOrderOpenTimeCtrl.text.trim(),
        'customOrderCloseTime': _customOrderCloseTimeCtrl.text.trim().isEmpty
            ? '11:00 PM'
            : _customOrderCloseTimeCtrl.text.trim(),
      });
      _snack('Custom order settings saved successfully.', Colors.green);
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
          'Custom Orders Settings',
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
                            'Temporarily close custom orders',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                        Switch(
                          value: _customOrderTemporarilyClosed,
                          activeThumbColor: _primary,
                          onChanged: (v) =>
                              setState(() => _customOrderTemporarilyClosed = v),
                        ),
                      ],
                    ),
                  ),
                  _sectionLabel('Custom Order Normal Fee (Rs.)'),
                  _inputCard(
                    child: TextField(
                      controller: _customNormalFeeCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _inputDecor('e.g. 150', Icons.shopping_bag_outlined),
                    ),
                  ),
                  _sectionLabel('Custom Order Fast Fee (Rs.)'),
                  _inputCard(
                    child: TextField(
                      controller: _customFastFeeCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _inputDecor('e.g. 200', Icons.flash_on_rounded),
                    ),
                  ),
                  _sectionLabel('Custom Normal Delivery Time (e.g. 40-60)'),
                  _inputCard(
                    child: TextField(
                      controller: _customNormalTimeCtrl,
                      decoration: _inputDecor('e.g. 40-60', Icons.timer_outlined),
                    ),
                  ),
                  _sectionLabel('Custom Fast Delivery Time (e.g. 20-30)'),
                  _inputCard(
                    child: TextField(
                      controller: _customFastTimeCtrl,
                      decoration: _inputDecor('e.g. 20-30', Icons.timer_rounded),
                    ),
                  ),
                  _sectionLabel('Custom Order Opening Time'),
                  _inputCard(
                    child: TextField(
                      controller: _customOrderOpenTimeCtrl,
                      decoration: _inputDecor('e.g. 10:00 AM', Icons.schedule_rounded),
                    ),
                  ),
                  _sectionLabel('Custom Order Closing Time'),
                  _inputCard(
                    child: TextField(
                      controller: _customOrderCloseTimeCtrl,
                      decoration: _inputDecor('e.g. 11:00 PM', Icons.schedule_send_rounded),
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
