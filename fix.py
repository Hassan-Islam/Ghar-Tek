import re

file_path = "lib/pages/admin_app_settings_page.dart"
with open(file_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

new_lines = []
skip = False

for i, line in enumerate(lines):
    # If the line contains any of the bad variables or methods, and we are not in a multiline block that we need to keep
    # Let's just remove the specific statements.
    
    bad_vars = [
        "_supportPhoneCtrl", "_supportWhatsAppCtrl", "_supportEmailCtrl", "_fcmServerKeyCtrl",
        "_resolveStoredFcmCredential", "_validateFcmCredentialOrThrow",
        "_customNormalFeeCtrl", "_customFastFeeCtrl", "_customNormalTimeCtrl", "_customFastTimeCtrl",
        "_customOrderTemporarilyClosed", "_appCloseMessageCtrl", "_customOrderOpenTimeCtrl",
        "_customOrderCloseTimeCtrl", "_startupPopupEnabled", "_startupPopupTitleCtrl",
        "_startupPopupMessageCtrl", "_checkoutInstructionEnabled", "_checkoutInstructionCtrl",
        "_maxActiveOrdersCtrl", "_saveHostelOptions", "_confirmCleanup", "_deleteOrdersByStatus",
        "_deleteAllOrdersData", "_deleteKhataData", "_countDeepRecords", "_showAddPromoDialog",
        "_dialogField", "_deletePromoCode", "_togglePayment", "_updatePaymentLabel", "_saveAd",
        "globalAppData['fcm", "appData['fcm"
    ]
    
    # We will just comment them out if they are inside _loadFees or _saveFees or anywhere else
    # Wait, some lines might span multiple lines, e.g. _customOrderOpenTimeCtrl.text = ...
    # We can be safe and just comment out any line containing these variables.
    
    has_bad = any(b in line for b in bad_vars)
    if has_bad:
        # Comment it out so it doesn't cause compilation error
        # But wait, what if it's part of a map literal? e.g. 'customDeliveryNormal': double.tryParse(_customNormalFeeCtrl.text) ?? 150,
        # Commenting out the line in a map literal might leave a trailing comma or break the map.
        # It's actually fine if we comment out the whole key-value pair.
        new_lines.append("// " + line)
    else:
        new_lines.append(line)

with open("lib/pages/admin_app_settings_page_fixed.dart", "w", encoding="utf-8") as f:
    f.writelines(new_lines)
