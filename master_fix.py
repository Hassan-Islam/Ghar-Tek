import os

file_path = "lib/pages/admin_app_settings_page_fixed.dart"
with open(file_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    # 1. Remove corrupted lines (Emojis converted to "?")
    if "Payment Methods" in line and "?" in line:
        continue
    if "Ads" in line and "?" in line:
        continue
    if "Promo" in line and "?" in line:
        continue
        
    # 2. Fix improperly commented out methods
    if line.startswith("//   Future<void> _deletePromoCode"):
        line = line.replace("// ", "")
    elif line.startswith("//   Future<void> _togglePayment"):
        line = line.replace("// ", "")
    elif line.startswith("//   Future<void> _updatePaymentLabel"):
        line = line.replace("// ", "")
    elif line.startswith("//   Future<void> _saveAd"):
        line = line.replace("// ", "")
    elif line.startswith("//   Widget _dialogField"):
        line = line.replace("// ", "")
    elif line.startswith("//   void _showAddPromoDialog"):
        line = line.replace("// ", "")
        
    new_lines.append(line)

content = "".join(new_lines)

# Remove the previously appended _normalizeAdRecord if it exists
idx_norm = content.find("Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {")
if idx_norm != -1:
    content = content[:idx_norm]

content = content.strip()
if content.endswith("}"):
    content = content[:-1]

content += '''

  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {
    return ad;
  }
}
'''

with open("lib/pages/admin_app_settings_page.dart", "w", encoding="utf-8") as f:
    f.write(content)
