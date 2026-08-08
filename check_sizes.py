import os
import json

history_dir = r"C:\Users\pc\AppData\Roaming\Code\User\History"

for root, dirs, files in os.walk(history_dir):
    if "entries.json" in files:
        entries_path = os.path.join(root, "entries.json")
        try:
            with open(entries_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                resource = data.get("resource", "")
                if "admin_app_settings_page.dart" in resource:
                    print(f"\n--- Found {resource} in {entries_path} ---")
                    entries = data.get("entries", [])
                    for entry in entries:
                        entry_file = os.path.join(root, entry["id"])
                        if os.path.exists(entry_file):
                            size = os.path.getsize(entry_file)
                            print(f"Entry {entry['id']} size: {size}")
        except Exception as e:
            pass
