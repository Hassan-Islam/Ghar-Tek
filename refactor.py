import re
import os

file_path = "lib/pages/admin_app_settings_page.dart"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Add imports
import_str = '''import 'admin_settings/admin_custom_orders_page.dart';
import 'admin_settings/admin_popups_page.dart';
import 'admin_settings/admin_locations_page.dart';
import 'admin_settings/admin_support_settings_page.dart';
import 'admin_settings/admin_advanced_settings_page.dart';
'''
# insert after import '../services/image_upload_service.dart';
content = content.replace("import '../services/image_upload_service.dart';", "import '../services/image_upload_service.dart';\n" + import_str)

# 2. Replace _buildFeesTab() UI
# We need to find the start and end of _buildFeesTab
start_idx = content.find("Widget _buildFeesTab() {")

# Instead of regex for the whole block which is massive and error prone,
# let's just write a completely new _buildFeesTab method and replace the old one.
# We will use regex to capture everything from "Widget _buildFeesTab() {" up to "Widget _buildPromosTab() {"
end_idx = content.find("Widget _buildPromosTab() {")

if start_idx != -1 and end_idx != -1:
    new_fees_tab = '''Widget _buildFeesTab() {
    if (_feesLoading)
      return const Center(child: CircularProgressIndicator(color: _primary));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('Standard Delivery Fee (Rs.)'),
          const SizedBox(height: 8),
          _inputCard(
            child: TextField(
              controller: _normalFeeCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 80', Icons.moped_rounded),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel('Fast Delivery Fee (Rs.)'),
          const SizedBox(height: 8),
          _inputCard(
            child: TextField(
              controller: _fastFeeCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 150', Icons.flash_on_rounded),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel('Delivery Tax Rate (%)'),
          const SizedBox(height: 8),
          _inputCard(
            child: TextField(
              controller: _taxRateCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 5 for 5%', Icons.receipt_long_rounded),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel('Fast Delivery Min Cart Limit (Rs.)'),
          const SizedBox(height: 8),
          _inputCard(
            child: TextField(
              controller: _fastDeliveryMinLimitCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 300', Icons.shopping_cart_checkout_rounded),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(color: Colors.pinkAccent, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 10),
              const Text('Free Delivery Rules', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.pinkAccent)),
            ],
          ),
          const SizedBox(height: 12),
          _sectionLabel('Free Delivery Threshold (Rs.)'),
          const SizedBox(height: 8),
          _inputCard(
            child: TextField(
              controller: _freeDeliveryThresholdCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 2500', Icons.card_giftcard_rounded),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel('Free Delivery Minimum Cart Amount (Rs.)'),
          const SizedBox(height: 8),
          _inputCard(
            child: TextField(
              controller: _freeDeliveryMinCartCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _inputDecor('e.g. 1000', Icons.shopping_basket_rounded),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _feesSaving ? null : _saveFees,
              icon: _feesSaving ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.save_rounded),
              label: Text(_feesSaving ? 'Saving...' : 'Save App Settings'),
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(height: 40),
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 10),
              const Text('More Settings', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.blue)),
            ],
          ),
          const SizedBox(height: 16),
          _buildSettingsTile(
            title: 'Custom Orders',
            subtitle: 'Fees, times and opening/closing',
            icon: Icons.shopping_bag_outlined,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminCustomOrdersPage())),
          ),
          _buildSettingsTile(
            title: 'Popups & Messages',
            subtitle: 'App close message, start popup, checkout instructions',
            icon: Icons.message_outlined,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPopupsPage())),
          ),
          _buildSettingsTile(
            title: 'Locations Database',
            subtitle: 'Hostels, Rooms, Departments',
            icon: Icons.location_on_outlined,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminLocationsPage())),
          ),
          _buildSettingsTile(
            title: 'Support & Contacts',
            subtitle: 'Phone numbers and emails for support',
            icon: Icons.headset_mic_outlined,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminSupportSettingsPage())),
          ),
          _buildSettingsTile(
            title: 'Advanced Settings',
            subtitle: 'Database cleanup, FCM Key, Rider limits',
            icon: Icons.settings_applications_outlined,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminAdvancedSettingsPage())),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSettingsTile({required String title, required String subtitle, required IconData icon, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.05),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFF2F7FF), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: _primary, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: _primary)),
                      const SizedBox(height: 4),
                      Text(subtitle, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey[400]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  '''
    content = content[:start_idx] + new_fees_tab + content[end_idx:]

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Done replacing UI")
