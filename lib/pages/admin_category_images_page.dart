import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/city_scope_service.dart';
import '../services/image_helper.dart';
import '../services/image_upload_service.dart';

class AdminCategoryImagesPage extends StatefulWidget {
  const AdminCategoryImagesPage({super.key});

  @override
  State<AdminCategoryImagesPage> createState() =>
      _AdminCategoryImagesPageState();
}

class _HomeCategoryRow {
  _HomeCategoryRow({
    required this.key,
    required this.label,
    required this.labelController,
    required this.imageController,
    required this.orderController,
  });

  final String key;
  String label;
  final TextEditingController labelController;
  final TextEditingController imageController;
  final TextEditingController orderController;
}

class _AdminCategoryImagesPageState extends State<AdminCategoryImagesPage> {
  static const Color _primary = Color(0xFFFF6B00);

  static const List<Map<String, String>> _defaultCategories = [
    {'label': 'All'},
    {'label': 'Biryani', 'imagePath': 'assets/images/categories/biryani.jpg'},
    {'label': 'Burger', 'imagePath': 'assets/images/categories/burger.jpg'},
    {'label': 'FastFood', 'imagePath': 'assets/images/categories/fastfood.jpg'},
    {'label': 'Ice Cream', 'imagePath': 'assets/images/categories/ice_cream.jpg'},
    {'label': 'Pizza', 'imagePath': 'assets/images/categories/pizza.jpg'},
    {'label': 'Groceries', 'imagePath': 'assets/images/categories/groceries.jpg'},
    {'label': 'Cold Drink', 'imagePath': 'assets/images/categories/cold_drink.jpg'},
    {'label': 'Juices', 'imagePath': 'assets/images/categories/juices.jpg'},
    {'label': 'Tea & Coffe', 'imagePath': 'assets/images/categories/tea_coffee.jpg'},
    {'label': 'Cakes', 'imagePath': 'assets/images/categories/cakes.jpg'},
  ];

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final ImagePicker _picker = ImagePicker();
  final List<_HomeCategoryRow> _entries = [];
  final Set<String> _uploading = {};
  bool _loading = true;
  bool _isIslamabadTenant = false;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  String _categoryKey(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('&', 'and')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  String? _assetPathForLabel(String label) {
    for (final cat in _defaultCategories) {
      if ((cat['label'] ?? '').toLowerCase() == label.toLowerCase()) {
        return cat['imagePath'];
      }
    }
    return null;
  }

  Widget _buildCategoryPreview({
    required String imageUrl,
    required String label,
  }) {
    if (imageUrl.isNotEmpty) {
      return ImageHelper.networkImage(
        url: imageUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorWidget: _buildCategoryPreviewFallback(label),
      );
    }

    final assetPath = _assetPathForLabel(label);
    if (assetPath != null) {
      return Image.asset(
        assetPath,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _buildCategoryPreviewFallback(label),
      );
    }

    return _buildCategoryPreviewFallback(label);
  }

  Widget _buildCategoryPreviewFallback(String label) {
    return Container(
      color: const Color(0xFFFFF3EB),
      alignment: Alignment.center,
      child: Icon(
        label.toLowerCase() == 'all' ? Icons.apps_rounded : Icons.image_rounded,
        color: _primary,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.labelController.dispose();
      entry.imageController.dispose();
      entry.orderController.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await CityScopeService.ensureLoaded();
      _isIslamabadTenant =
          CityScopeService.normalizeCity(CityScopeService.currentCity) ==
          CityScopeService.islamabad;

      if (!_isIslamabadTenant) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      for (final entry in _entries) {
        entry.labelController.dispose();
        entry.imageController.dispose();
        entry.orderController.dispose();
      }
      _entries.clear();

      final snap = await _db.child(_tenantPath('settings/home-categories')).get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        final parsed = <_HomeCategoryRow>[];
        data.forEach((key, raw) {
          if (raw is! Map) return;
          final record = Map<String, dynamic>.from(raw);
          final label = (record['label'] ?? key).toString().trim();
          if (label.isEmpty) return;
          parsed.add(
            _HomeCategoryRow(
              key: key.toString(),
              label: label,
              labelController: TextEditingController(text: label),
              imageController: TextEditingController(
                text: (record['imageUrl'] ?? record['image'] ?? '').toString(),
              ),
              orderController: TextEditingController(
                text: (record['order'] ?? parsed.length).toString(),
              ),
            ),
          );
        });
        parsed.sort((a, b) {
          final ao = int.tryParse(a.orderController.text) ?? 0;
          final bo = int.tryParse(b.orderController.text) ?? 0;
          return ao.compareTo(bo);
        });
        _entries.addAll(parsed);
      }

      if (_entries.isEmpty) {
        for (var i = 0; i < _defaultCategories.length; i++) {
          final label = _defaultCategories[i]['label']!;
          _entries.add(
            _HomeCategoryRow(
              key: _categoryKey(label),
              label: label,
              labelController: TextEditingController(text: label),
              imageController: TextEditingController(),
              orderController: TextEditingController(text: '$i'),
            ),
          );
        }
      }
    } catch (e) {
      _snack(e.toString(), Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _publishAllCategories() async {
    if (_entries.isEmpty) return;
    setState(() => _loading = true);
    try {
      for (final entry in _entries) {
        await _save(entry, showSnack: false);
      }
      _snack('All home categories published', Colors.green);
    } catch (e) {
      _snack(e.toString(), Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(_HomeCategoryRow entry, {bool showSnack = true}) async {
    final label = entry.labelController.text.trim();
    if (label.isEmpty) {
      _snack('Category name is required', Colors.red);
      return;
    }

    final key = entry.key.isNotEmpty ? entry.key : _categoryKey(label);
    final imageUrl = ImageUploadService.normalizeImageUrl(
      entry.imageController.text,
    );
    final order =
        int.tryParse(entry.orderController.text.trim()) ?? _entries.length;

    try {
      await _db.child(_tenantPath('settings/home-categories/$key')).set({
        'label': label,
        'imageUrl': imageUrl,
        'order': order,
        'updatedAt': ServerValue.timestamp,
      });
      entry.label = label;
      if (showSnack) _snack('$label saved', Colors.green);
      if (mounted) setState(() {});
    } catch (e) {
      _snack(e.toString(), Colors.red);
    }
  }

  Future<void> _pickAndUpload(_HomeCategoryRow entry) async {
    if (_uploading.contains(entry.key)) return;

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1200,
      );
      if (picked == null) return;

      setState(() => _uploading.add(entry.key));
      final result = await ImageUploadService.uploadImage(
        file: picked,
        useCase: ImageUploadUseCase.ad,
      );
      entry.imageController.text = result.url;
      await _save(entry);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), Colors.red);
    } finally {
      if (mounted) setState(() => _uploading.remove(entry.key));
    }
  }

  Future<void> _deleteCategory(_HomeCategoryRow entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete category?'),
        content: Text('Remove "${entry.label}" from home screen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _db.child(_tenantPath('settings/home-categories/${entry.key}')).remove();
      setState(() {
        entry.labelController.dispose();
        entry.imageController.dispose();
        entry.orderController.dispose();
        _entries.remove(entry);
      });
      _snack('Category deleted', Colors.green);
    } catch (e) {
      _snack(e.toString(), Colors.red);
    }
  }

  Future<void> _showAddCategoryDialog() async {
    final nameCtrl = TextEditingController();
    final orderCtrl = TextEditingController(
      text: '${_entries.length}',
    );

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Home Category'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Category name',
                hintText: 'e.g. Shawarma, Breakfast',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: orderCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Display order',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (added != true || !mounted) {
      nameCtrl.dispose();
      orderCtrl.dispose();
      return;
    }

    final label = nameCtrl.text.trim();
    final orderText = orderCtrl.text.trim();
    nameCtrl.dispose();
    orderCtrl.dispose();

    if (label.isEmpty) {
      _snack('Category name is required', Colors.red);
      return;
    }

    final key = _categoryKey(label);
    if (_entries.any((e) => e.key == key)) {
      _snack('This category already exists', Colors.orange);
      return;
    }

    final entry = _HomeCategoryRow(
      key: key,
      label: label,
      labelController: TextEditingController(text: label),
      imageController: TextEditingController(),
      orderController: TextEditingController(
        text: orderText.isEmpty ? '${_entries.length}' : orderText,
      ),
    );

    setState(() => _entries.add(entry));
    await _save(entry);
  }

  void _snack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'Home Categories',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        actions: [
          if (_isIslamabadTenant && !_loading)
            TextButton(
              onPressed: _publishAllCategories,
              child: const Text(
                'Save All',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: _isIslamabadTenant && !_loading
          ? FloatingActionButton.extended(
              onPressed: _showAddCategoryDialog,
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Category'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : !_isIslamabadTenant
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Home categories can only be managed for Islamabad (QAU). Switch city to Islamabad in admin settings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, color: Colors.black54),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                  itemCount: _entries.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFFED7AA)),
                        ),
                        child: const Text(
                          'Default categories always stay on the Islamabad home screen. '
                          'Upload images, change order, add new categories, then tap Save All.',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Color(0xFF9A3412),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }

                    final entry = _entries[index - 1];
                    final imageUrl = ImageHelper.getDirectImageUrl(
                      entry.imageController.text,
                    );
                    final uploading = _uploading.contains(entry.key);
                    final isAll = entry.label.toLowerCase() == 'all';

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: _buildCategoryPreview(
                                imageUrl: imageUrl,
                                label: entry.labelController.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: entry.labelController,
                                        decoration: const InputDecoration(
                                          labelText: 'Category name',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    if (!isAll)
                                      IconButton(
                                        tooltip: 'Delete',
                                        onPressed: uploading
                                            ? null
                                            : () => _deleteCategory(entry),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          color: Colors.red,
                                          size: 20,
                                        ),
                                      ),
                                  ],
                                ),
                                if (isAll)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      'Hidden on home screen (used for search only)',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ),
                                TextField(
                                  controller: entry.imageController,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    hintText: 'Image URL',
                                    isDense: true,
                                    prefixIcon: const Icon(
                                      Icons.link_rounded,
                                      size: 18,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: entry.orderController,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    hintText: 'Order',
                                    isDense: true,
                                    prefixIcon: const Icon(
                                      Icons.sort_rounded,
                                      size: 18,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: uploading
                                            ? null
                                            : () => _pickAndUpload(entry),
                                        icon: uploading
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              )
                                            : const Icon(Icons.upload_rounded),
                                        label: Text(
                                          uploading ? 'Uploading' : 'Upload',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: uploading
                                            ? null
                                            : () => _save(entry),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _primary,
                                          foregroundColor: Colors.white,
                                        ),
                                        icon: const Icon(Icons.save_rounded),
                                        label: const Text('Save'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
