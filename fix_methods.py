import os

file_path = "lib/pages/admin_app_settings_page.dart"
with open(file_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if line.startswith("//   Future<void> _deletePromoCode"):
        new_lines.append(line.replace("// ", ""))
    elif line.startswith("//   Future<void> _togglePayment"):
        new_lines.append(line.replace("// ", ""))
    elif line.startswith("//   Future<void> _updatePaymentLabel"):
        new_lines.append(line.replace("// ", ""))
    elif line.startswith("//   Future<void> _saveAd"):
        new_lines.append(line.replace("// ", ""))
    elif line.startswith("//   Widget _dialogField"):
        new_lines.append(line.replace("// ", ""))
    elif line.startswith("//   void _showAddPromoDialog"):
        new_lines.append(line.replace("// ", ""))
    else:
        new_lines.append(line)

# Make sure _normalizeAdRecord is inside the class!
# I will find the last '}' and put _normalizeAdRecord before it.

content = "".join(new_lines)

# Remove the previously appended _normalizeAdRecord
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

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)
