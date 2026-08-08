import os

file_path = "lib/pages/admin_app_settings_page_fixed.dart"
with open(file_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    # 1. Remove corrupted emoji lines
    if "Payment Methods" in line and "?" in line:
        continue
    if "Ads" in line and "?" in line:
        continue
    if "Promo" in line and "?" in line:
        continue
        
    # 2. Remove the "// " prefix added by fix.py
    if line.startswith("// "):
        # Check if it was added by fix.py
        # fix.py added exactly "// "
        line = line.replace("// ", "", 1)
        
    new_lines.append(line)

content = "".join(new_lines)

# Remove the previously appended _normalizeAdRecord if it exists
idx_norm = content.find("Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {")
if idx_norm != -1:
    content = content[:idx_norm]

content = content.strip()
if content.endswith("}"):
    content = content[:-1]

# Now we need to make sure _snack is there.
# Let's see if _snack is defined in the file.
snack_defined = "void _snack(String msg, Color bg)" in content
if not snack_defined:
    content += '''
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
'''

content += '''

  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {
    return ad;
  }
}
'''

with open("lib/pages/admin_app_settings_page.dart", "w", encoding="utf-8") as f:
    f.write(content)
