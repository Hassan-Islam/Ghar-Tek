import os

file_path = "lib/pages/admin_app_settings_page.dart"
with open(file_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if "" in line:
        continue
    new_lines.append(line)

with open(file_path, "w", encoding="utf-8") as f:
    f.writelines(new_lines)
