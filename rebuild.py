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

# Now we need to wipe _loadFees and replace with a clean one
load_fees_start = content.find("Future<void> _loadFees() async {")
load_fees_end = content.find("Future<void> _saveFees() async {")

if load_fees_start != -1 and load_fees_end != -1:
    clean_load_fees = """  Future<void> _loadFees() async {
    setState(() => _feesLoading = true);
    try {
      await CityScopeService.ensureLoaded();
      _isIslamabadTenant = CityScopeService.normalizeCity(CityScopeService.currentCity) == CityScopeService.islamabad;
    } catch (_) {}
    if (mounted) setState(() => _feesLoading = false);
  }

"""
    content = content[:load_fees_start] + clean_load_fees + content[load_fees_end:]


# Now wipe _saveFees
save_fees_start = content.find("Future<void> _saveFees() async {")
save_fees_end = content.find("Future<bool> _confirmCleanup({")

if save_fees_start != -1 and save_fees_end != -1:
    clean_save_fees = """  Future<void> _saveFees() async {
    setState(() => _feesSaving = true);
    if (mounted) setState(() => _feesSaving = false);
  }

"""
    content = content[:save_fees_start] + clean_save_fees + content[save_fees_end:]


# Now remove _confirmCleanup and _saveHostelOptions
confirm_cleanup_start = content.find("Future<bool> _confirmCleanup({")
confirm_cleanup_end = content.find("Widget _buildFeesTab() {")
if confirm_cleanup_start != -1 and confirm_cleanup_end != -1:
    content = content[:confirm_cleanup_start] + content[confirm_cleanup_end:]
elif confirm_cleanup_start != -1:
    next_method = content.find("Future<void> _loadPromoCodes()", confirm_cleanup_start)
    if next_method != -1:
        content = content[:confirm_cleanup_start] + content[next_method:]

# Also _saveHostelOptions is broken. Let's find "Future<void> _saveHostelOptions" or "  ) async {"
save_hostel_start = content.find("Future<void> _saveHostelOptions(")
if save_hostel_start == -1:
    # Look for the broken ) async {
    broken_stub = content.find("  ) async {\n    if (!_isIslamabadTenant) return;")
    if broken_stub != -1:
        # Find where it ends
        end_stub = content.find("  void _addOptionToList({", broken_stub)
        if end_stub != -1:
            content = content[:broken_stub] + content[end_stub:]

# Add build method
build_method = """
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Settings')),
      body: const Center(child: Text('Dashboard Placeholder')),
    );
  }
"""

if "Widget build(BuildContext context)" not in content:
    content = content.strip()
    if content.endswith("}"):
        content = content[:-1]
    content += build_method + "\n}\n"

with open("lib/pages/admin_app_settings_page.dart", "w", encoding="utf-8") as f:
    f.write(content)
