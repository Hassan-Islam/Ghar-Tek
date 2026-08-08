import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../../services/city_scope_service.dart';

class AdminLocationsPage extends StatefulWidget {
  const AdminLocationsPage({Key? key}) : super(key: key);

  @override
  State<AdminLocationsPage> createState() => _AdminLocationsPageState();
}

class _AdminLocationsPageState extends State<AdminLocationsPage> {
  static const Color _primary = Color(0xFF001B33);

  List<String> _boysHostels = [];
  List<String> _girlsHostels = [];
  List<String> _boysRooms = [];
  List<String> _girlsRooms = [];
  List<String> _departments = [];

  final _boysHostelCtrl = TextEditingController();
  final _girlsHostelCtrl = TextEditingController();
  final _boysRoomCtrl = TextEditingController();
  final _girlsRoomCtrl = TextEditingController();
  final _boysRoomStartCtrl = TextEditingController();
  final _girlsRoomStartCtrl = TextEditingController();
  final _departmentCtrl = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  String _tenantPath(String path) => CityScopeService.tenantPath(path);
  bool get _isIslamabadTenant => CityScopeService.currentCity == 'islamabad';

  @override
  void initState() {
    super.initState();
    _loadHostelOptions();
  }

  @override
  void dispose() {
    _boysHostelCtrl.dispose();
    _girlsHostelCtrl.dispose();
    _boysRoomCtrl.dispose();
    _girlsRoomCtrl.dispose();
    _boysRoomStartCtrl.dispose();
    _girlsRoomStartCtrl.dispose();
    _departmentCtrl.dispose();
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

  List<String> _normalizeStringList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) {
      return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }
    return [];
  }

  Future<void> _loadHostelOptions() async {
    if (!_isIslamabadTenant) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    setState(() => _isLoading = true);
    try {
      final snap = await _db.child(_tenantPath('settings/checkout-hostel-options')).get();
      if (snap.exists) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        if (data['boys'] != null) {
          final boysMap = Map<String, dynamic>.from(data['boys']);
          _boysHostels = _normalizeStringList(boysMap['hostels']);
          _boysRooms = _normalizeStringList(boysMap['rooms']);
        } else {
          _boysHostels = [];
          _boysRooms = [];
        }
        if (data['girls'] != null) {
          final girlsMap = Map<String, dynamic>.from(data['girls']);
          _girlsHostels = _normalizeStringList(girlsMap['hostels']);
          _girlsRooms = _normalizeStringList(girlsMap['rooms']);
        } else {
          _girlsHostels = [];
          _girlsRooms = [];
        }
        _departments = _normalizeStringList(data['departments']);
      } else {
        _boysHostels = [];
        _girlsHostels = [];
        _boysRooms = [];
        _girlsRooms = [];
        _departments = [];
      }
    } catch (e) {
      _snack('Error loading hostel options: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveHostelOptions({bool showToast = true}) async {
    if (!_isIslamabadTenant) return;
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _db.child(_tenantPath('settings/checkout-hostel-options')).set({
        'boys': {
          'hostels': _boysHostels,
          'rooms': _boysRooms,
        },
        'girls': {
          'hostels': _girlsHostels,
          'rooms': _girlsRooms,
        },
        'departments': _departments,
      });
      if (showToast) {
        _snack('Locations saved successfully.', Colors.green);
      }
    } catch (e) {
      if (showToast) {
        _snack('Unable to save locations: $e', Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _addOptionToList({required TextEditingController controller, required List<String> list}) {
    final val = controller.text.trim();
    if (val.isNotEmpty && !list.contains(val)) {
      setState(() {
        list.add(val);
        controller.clear();
      });
    }
  }

  void _removeOptionFromList({required String value, required List<String> list}) {
    setState(() {
      list.remove(value);
    });
  }

  void _generateRooms({required String startingPrefix, required List<String> targetList}) {
    final s = startingPrefix.trim();
    if (s.isEmpty) {
      _snack('Enter a starting prefix/number (e.g. 1 or A)', Colors.orange);
      return;
    }
    int? startNum = int.tryParse(s);
    if (startNum != null) {
      for (int i = startNum; i < startNum + 50; i++) {
        final r = i.toString();
        if (!targetList.contains(r)) {
          targetList.add(r);
        }
      }
      setState(() {});
    } else {
      _snack('For auto-generate, enter a number.', Colors.orange);
    }
  }

  Widget _hostelListEditor({
    required String title,
    required List<String> list,
    required TextEditingController controller,
    required String hint,
    TextEditingController? startController,
    VoidCallback? onAutoGenerate,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          const SizedBox(height: 10),
          if (list.isEmpty)
            Text(
              'No items added yet.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: list
                  .map(
                    (item) => Chip(
                      label: Text(item, style: const TextStyle(fontSize: 12)),
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      onDeleted: () => _removeOptionFromList(value: item, list: list),
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(color: Colors.grey[400], fontSize: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => _addOptionToList(controller: controller, list: list),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _addOptionToList(controller: controller, list: list),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: const Text('Add'),
              ),
            ],
          ),
          if (startController != null && onAutoGenerate != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: startController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: 'Start No. (e.g. 100)',
                      hintStyle: TextStyle(color: Colors.grey[400], fontSize: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onAutoGenerate,
                  child: const Text('+ Auto 50'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isIslamabadTenant) {
      return Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          title: const Text('Locations Database'),
          elevation: 0,
        ),
        body: const Center(
          child: Text('This feature is only for Islamabad.'),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        title: const Text(
          'Locations Database',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        elevation: 0,
        actions: [
          IconButton(
            icon: _isSaving 
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.save_rounded),
            onPressed: _isSaving ? null : _saveHostelOptions,
          ),
        ],
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
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline_rounded, color: Colors.orange, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Yeh section sirf Islamabad checkout ke liye hai. Customers ko hamesha "Other" option milega jahan wo apna hostel/room type kar sakte hain.',
                            style: TextStyle(fontSize: 13, color: Colors.orange),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _hostelListEditor(
                    title: 'Boys Hostels',
                    list: _boysHostels,
                    controller: _boysHostelCtrl,
                    hint: 'e.g. Boys Hostel 1',
                  ),
                  const SizedBox(height: 12),
                  _hostelListEditor(
                    title: 'Girls Hostels',
                    list: _girlsHostels,
                    controller: _girlsHostelCtrl,
                    hint: 'e.g. Girls Hostel A',
                  ),
                  const SizedBox(height: 12),
                  _hostelListEditor(
                    title: 'Boys Rooms',
                    list: _boysRooms,
                    controller: _boysRoomCtrl,
                    hint: 'e.g. 101',
                    startController: _boysRoomStartCtrl,
                    onAutoGenerate: () => _generateRooms(
                      startingPrefix: _boysRoomStartCtrl.text,
                      targetList: _boysRooms,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _hostelListEditor(
                    title: 'Girls Rooms',
                    list: _girlsRooms,
                    controller: _girlsRoomCtrl,
                    hint: 'e.g. G-101',
                    startController: _girlsRoomStartCtrl,
                    onAutoGenerate: () => _generateRooms(
                      startingPrefix: _girlsRoomStartCtrl.text,
                      targetList: _girlsRooms,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _hostelListEditor(
                    title: 'Departments',
                    list: _departments,
                    controller: _departmentCtrl,
                    hint: 'e.g. CS Dept',
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveHostelOptions,
                      icon: _isSaving
                          ? const SizedBox(
                              height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.save_rounded),
                      label: Text(_isSaving ? 'Saving...' : 'Save Locations'),
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
