import os

file_path = "lib/pages/admin_app_settings_page_fixed.dart"
with open(file_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    # Safely remove any line that looks like the corrupted comment
    if "Payment Methods" in line and "?" in line:
        continue
    if "Ads" in line and "?" in line:
        continue
    # And there was another one before Promos
    if "Promo" in line and "?" in line:
        continue
    new_lines.append(line)

with open("lib/pages/admin_app_settings_page.dart", "w", encoding="utf-8") as f:
    f.writelines(new_lines)
