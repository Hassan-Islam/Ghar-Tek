import os

file_path = "lib/pages/admin_app_settings_page.dart"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

lines = content.splitlines()

brace_count = 0
class_started = False
for i, line in enumerate(lines):
    if "class _AdminAppSettingsPageState" in line:
        class_started = True
    
    if class_started:
        clean_line = line
        if "//" in clean_line:
            clean_line = clean_line[:clean_line.find("//")]
        
        brace_count += clean_line.count("{")
        brace_count -= clean_line.count("}")
        
        if brace_count == 0 and "class _AdminAppSettingsPageState" not in line:
            print(f"Class closed at line {i+1}: {line}")
            break
