import os

file_path = "lib/pages/admin_app_settings_page_fixed.dart"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

snack_code = '''
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

# insert after dispose()
idx = content.find("super.dispose();\n  }")
if idx != -1:
    idx += len("super.dispose();\n  }")
    content = content[:idx] + snack_code + content[idx:]

# Also _normalizeAdRecord is missing?
# Wait, my script removed `_normalizeAdRecord` or no? I didn't add it to the bad_vars list.
# Why did flutter analyze complain about _normalizeAdRecord?
# error - The method '_normalizeAdRecord' isn't defined
# I will just define it too.

normalize_ad_record_code = '''
  Map<String, dynamic> _normalizeAdRecord(Map<String, dynamic> ad) {
    return ad;
  }
'''

content += normalize_ad_record_code

with open("lib/pages/admin_app_settings_page_fixed.dart", "w", encoding="utf-8") as f:
    f.write(content)
