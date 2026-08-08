import os

file_path = "lib/pages/admin_app_settings_page.dart"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

lines = content.splitlines()

brace_count = 0
for i, line in enumerate(lines):
    # simple counting ignoring comments/strings for a quick check
    if "//" in line:
        line = line[:line.find("//")]
    brace_count += line.count("{")
    brace_count -= line.count("}")
    if brace_count == 0 and i > 10:
        print(f"Class might be closed at line {i+1}: {line}")
        break
