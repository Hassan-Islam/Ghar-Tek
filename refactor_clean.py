import re
import os

file_path = "lib/pages/admin_app_settings_page.dart"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# Remove the state variables that we moved to sub-pages
variables_to_remove = [
    "final _customNormalFeeCtrl = TextEditingController();",
    "final _customFastFeeCtrl = TextEditingController();",
    "final _customNormalTimeCtrl = TextEditingController();",
    "final _customFastTimeCtrl = TextEditingController();",
    "final _customOrderOpenTimeCtrl = TextEditingController();",
    "final _customOrderCloseTimeCtrl = TextEditingController();",
    "final _appCloseMessageCtrl = TextEditingController();",
    "final _startupPopupTitleCtrl = TextEditingController();",
    "final _startupPopupMessageCtrl = TextEditingController();",
    "final _checkoutInstructionCtrl = TextEditingController();",
    "final _maxActiveOrdersCtrl = TextEditingController();",
    "final _supportPhoneCtrl = TextEditingController();",
    "final _supportWhatsAppCtrl = TextEditingController();",
    "final _supportEmailCtrl = TextEditingController();",
    "final _fcmServerKeyCtrl = TextEditingController();",
    "bool _startupPopupEnabled = false;",
    "bool _checkoutInstructionEnabled = false;",
    "bool _customOrderTemporarilyClosed = false;",
    "bool _hostelOptionsLoading = true;",
    "bool _hostelOptionsSaving = false;",
    "bool _cleanupBusy = false;",
    "final _boysRoomStartCtrl = TextEditingController();",
    "final _girlsRoomStartCtrl = TextEditingController();",
    "List<String> _boysHostels = [];",
    "List<String> _girlsHostels = [];",
    "List<String> _boysRooms = [];",
    "List<String> _girlsRooms = [];",
    "List<String> _departments = [];",
]

for var in variables_to_remove:
    content = content.replace(var, "")

dispose_vars = [
    "_customNormalFeeCtrl.dispose();",
    "_customFastFeeCtrl.dispose();",
    "_customNormalTimeCtrl.dispose();",
    "_customFastTimeCtrl.dispose();",
    "_customOrderOpenTimeCtrl.dispose();",
    "_customOrderCloseTimeCtrl.dispose();",
    "_appCloseMessageCtrl.dispose();",
    "_startupPopupTitleCtrl.dispose();",
    "_startupPopupMessageCtrl.dispose();",
    "_checkoutInstructionCtrl.dispose();",
    "_supportPhoneCtrl.dispose();",
    "_supportWhatsAppCtrl.dispose();",
    "_supportEmailCtrl.dispose();",
    "_fcmServerKeyCtrl.dispose();",
    "_maxActiveOrdersCtrl.dispose();",
    "_boysRoomStartCtrl.dispose();",
    "_girlsRoomStartCtrl.dispose();",
]

for var in dispose_vars:
    content = content.replace(var, "")

# We need to remove _loadHostelOptions() and _saveHostelOptions()
# A simple way to do this without getting into trouble with unbalanced braces is regex,
# but it's dangerous. However we can just search for the start and end of these.
# They are near line 275 and 312.
def remove_function(method_name):
    global content
    idx = content.find(f"Future<void> {method_name}() async {{")
    if idx == -1:
        idx = content.find(f"Future<void> {method_name}({{bool showToast = true}}) async {{")
    if idx != -1:
        brace_count = 0
        end_idx = -1
        started = False
        for i in range(idx, len(content)):
            if content[i] == '{':
                brace_count += 1
                started = True
            elif content[i] == '}':
                brace_count -= 1
            if started and brace_count == 0:
                end_idx = i + 1
                break
        if end_idx != -1:
            content = content[:idx] + content[end_idx:]

remove_function("_loadHostelOptions")
remove_function("_saveHostelOptions")

# Remove confirmation and cleanup methods
remove_function("_confirmCleanup")
remove_function("_deleteOrdersByStatus")
remove_function("_deleteAllOrdersData")
remove_function("_deleteKhataData")
remove_function("_cleanupDeliveredAndCancelledOrders")
remove_function("_cleanupAllOrdersAndKhataBase")
remove_function("_cleanupKhataDataOnly")

# _countDeepRecords is not async
idx = content.find("int _countDeepRecords(dynamic value) {")
if idx != -1:
    brace_count = 0
    end_idx = -1
    started = False
    for i in range(idx, len(content)):
        if content[i] == '{':
            brace_count += 1
            started = True
        elif content[i] == '}':
            brace_count -= 1
        if started and brace_count == 0:
            end_idx = i + 1
            break
    if end_idx != -1:
        content = content[:idx] + content[end_idx:]

# Remove _validateFcmCredentialOrThrow and _resolveStoredFcmCredential
idx = content.find("void _validateFcmCredentialOrThrow(String value) {")
if idx != -1:
    brace_count = 0
    end_idx = -1
    started = False
    for i in range(idx, len(content)):
        if content[i] == '{':
            brace_count += 1
            started = True
        elif content[i] == '}':
            brace_count -= 1
        if started and brace_count == 0:
            end_idx = i + 1
            break
    if end_idx != -1:
        content = content[:idx] + content[end_idx:]

remove_function("_resolveStoredFcmCredential")

# We should also remove the calls to loadHostelOptions inside _loadData
content = content.replace("if (_hostelOptionsLoading) {\n        await _loadHostelOptions();\n      }", "")
content = content.replace("await _loadHostelOptions();", "")

# Let's remove _hostelListEditor widget method
idx = content.find("Widget _hostelListEditor({")
if idx != -1:
    brace_count = 0
    end_idx = -1
    started = False
    for i in range(idx, len(content)):
        if content[i] == '{':
            brace_count += 1
            started = True
        elif content[i] == '}':
            brace_count -= 1
        if started and brace_count == 0:
            end_idx = i + 1
            break
    if end_idx != -1:
        content = content[:idx] + content[end_idx:]

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Done cleaning up methods")
