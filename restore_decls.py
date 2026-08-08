import os

file_path = "lib/pages/admin_app_settings_page.dart"
with open(file_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if line.strip() == "final codeCtrl = TextEditingController(text: existing?['code'] ?? '');":
        new_lines.append("  void _showAddPromoDialog([Map<String, dynamic>? existing]) {\n")
    if line.strip() == "final labelCtrl = TextEditingController(text: label);":
        new_lines.append("  Future<void> _updatePaymentLabel(String key, String label) async {\n")
    if line.strip() == "final normalizedImageUrl = ImageUploadService.normalizeImageUrl(imageUrl);":
        new_lines.append("  Future<void> _saveAd(int index, String imageUrl, String title, String subtitle, String fit, String alignment, String linkUrl, bool enabled) async {\n")
        
    new_lines.append(line)

content = "".join(new_lines)

dialog_field_code = """
  Widget _dialogField(TextEditingController controller, String label, IconData icon, {bool enabled = true, bool toUpper = false}) {
    return TextField(
      controller: controller,
      enabled: enabled,
      textCapitalization: toUpper ? TextCapitalization.characters : TextCapitalization.none,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: _primary),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
"""

content = content.replace("  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {", dialog_field_code + "\n  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {")

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)
