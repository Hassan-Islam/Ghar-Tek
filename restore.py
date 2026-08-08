import os
import json
import shutil

history_dir = r"C:\Users\pc\AppData\Roaming\Code\User\History"
target_file = r"c:\Users\pc\Desktop\ladlaaa s\ghartek_flutter_apps\lib\pages\admin_app_settings_page.dart"

found = False
for root, dirs, files in os.walk(history_dir):
    if "entries.json" in files:
        entries_path = os.path.join(root, "entries.json")
        try:
            with open(entries_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                # Check if it matches admin_app_settings_page.dart
                # It might have a resource URI
                resource = data.get("resource", "")
                if "admin_app_settings_page.dart" in resource:
                    print(f"Found entries.json at {entries_path}")
                    # Look for the oldest entry or the entry before my modification
                    entries = data.get("entries", [])
                    if entries:
                        # Assuming the largest size or the one before the last few edits is the original.
                        # Let's just find the first entry that is > 100KB (the original was ~150KB)
                        for entry in reversed(entries):
                            entry_file = os.path.join(root, entry["id"])
                            if os.path.exists(entry_file):
                                size = os.path.getsize(entry_file)
                                if size > 130000: # larger than 130KB
                                    print(f"Found original version: {entry_file} (Size: {size})")
                                    # Copy it back
                                    shutil.copy2(entry_file, target_file)
                                    print(f"Restored to {target_file}")
                                    found = True
                                    break
        except Exception as e:
            pass
    if found:
        break

if not found:
    print("Could not find a valid history entry for admin_app_settings_page.dart")
