import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../services/city_scope_service.dart';
import 'login_page.dart';
import 'edit_profile_page.dart';
import 'my_orders_page.dart';
import 'legal/terms_conditions_page.dart';
import 'legal/privacy_policy_page.dart';
import 'legal/about_us_page.dart';
import 'legal/refund_policy_page.dart';
import 'splash_screen.dart';
import 'user_chat_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const String _defaultSupportPhone = '+92 313 1426498';
  static const String _defaultSupportEmail = 'ghartekinfo@gmail.com';

  final AuthService _authService = AuthService();
  final _db = FirebaseDatabase.instance.ref();

  User? _currentUser;
  Map<String, dynamic>? _userData;
  bool _isLoading = true;
  bool _notificationsEnabled = true;
  int _totalOrders = 0;
  bool _isCityUpdating = false;
  String _selectedCity = CityScopeService.defaultCity;
  String _supportPhone = _defaultSupportPhone;
  String _supportWhatsAppPhone = _defaultSupportPhone;
  String _supportEmail = _defaultSupportEmail;

  String _tenantPath(String path, {String? city}) =>
      CityScopeService.tenantPath(path, city: city);

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    if (mounted) setState(() => _isLoading = true);
    _currentUser = _authService.currentUser;

    if (_currentUser == null) {
      _userData = null;
      _totalOrders = 0;
      _notificationsEnabled = true;
      _supportPhone = _defaultSupportPhone;
      _supportWhatsAppPhone = _defaultSupportPhone;
      _supportEmail = _defaultSupportEmail;
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      await CityScopeService.ensureLoaded();
      _selectedCity = CityScopeService.currentCity;

      final uid = _currentUser!.uid;

      try {
        _userData = await _authService
            .getUserData(uid)
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        _userData = null;
      }

      final role = (_userData?['role'] ?? 'customer').toString().toLowerCase();
      final rawCity = role == 'admin'
          ? (_userData?['adminCity'] ?? '').toString()
          : (_userData?['userCity'] ?? '').toString();
      if (rawCity.trim().isNotEmpty) {
        _selectedCity = CityScopeService.normalizeCity(rawCity);
      }

      await _loadSupportContacts(city: _selectedCity);

      int cnt = 0;

      try {
        final shopS = await _db
            .child(_tenantPath('shop-orders'))
            .orderByChild('userId')
            .equalTo(uid)
            .get()
            .timeout(const Duration(seconds: 12));
        if (shopS.exists && shopS.value is Map) {
          cnt += (shopS.value as Map).length;
        }
      } catch (_) {}

      _totalOrders = cnt;

      try {
        final notifS = await _db
            .child('users/$uid/notificationsEnabled')
            .get()
            .timeout(const Duration(seconds: 12));
        _notificationsEnabled = notifS.exists ? notifS.value == true : true;
      } catch (_) {
        _notificationsEnabled = true;
      }
    } catch (_) {
      _totalOrders = 0;
      _notificationsEnabled = true;
      _supportPhone = _defaultSupportPhone;
      _supportWhatsAppPhone = _defaultSupportPhone;
      _supportEmail = _defaultSupportEmail;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadSupportContacts({required String city}) async {
    try {
      final appControlSnap = await _db
          .child(_tenantPath('settings/app-control', city: city))
          .get()
          .timeout(const Duration(seconds: 12));

      final appControl = appControlSnap.exists && appControlSnap.value is Map
          ? Map<String, dynamic>.from(appControlSnap.value as Map)
          : <String, dynamic>{};

      final supportPhone = _firstNonEmpty(<String?>[
        appControl['supportPhone']?.toString(),
        appControl['adminPhone']?.toString(),
        appControl['contactPhone']?.toString(),
      ]);

      final supportWhatsApp = _firstNonEmpty(<String?>[
        appControl['whatsappSupportPhone']?.toString(),
        appControl['supportWhatsAppPhone']?.toString(),
        appControl['supportWhatsappPhone']?.toString(),
        supportPhone,
      ]);

      final supportEmail = _firstNonEmpty(<String?>[
        appControl['supportEmail']?.toString(),
        appControl['adminEmail']?.toString(),
        appControl['contactEmail']?.toString(),
      ]);

      _supportPhone = supportPhone.isEmpty ? _defaultSupportPhone : supportPhone;
      _supportWhatsAppPhone =
          supportWhatsApp.isEmpty ? _supportPhone : supportWhatsApp;
      _supportEmail = supportEmail.isEmpty ? _defaultSupportEmail : supportEmail;
    } catch (_) {
      _supportPhone = _defaultSupportPhone;
      _supportWhatsAppPhone = _defaultSupportPhone;
      _supportEmail = _defaultSupportEmail;
    }
  }

  String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final text = (value ?? '').trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  Future<void> _pickAndChangeCity() async {
    if (_isCityUpdating || _currentUser == null) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose Your City',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Shops and orders will load for this city only.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 12),
              ...CityScopeService.supportedCities.map((city) {
                final normalized = CityScopeService.normalizeCity(city);
                final selectedNow = normalized == _selectedCity;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    selectedNow
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selectedNow ? _primary : Colors.grey,
                  ),
                  title: Text(
                    CityScopeService.cityLabel(normalized),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  onTap: () => Navigator.pop(context, normalized),
                );
              }),
            ],
          ),
        ),
      ),
    );

    if (selected == null) return;
    await _changeCity(selected);
  }

  Future<void> _changeCity(String city) async {
    final normalized = CityScopeService.normalizeCity(city);
    if (normalized == _selectedCity) return;
    if (_currentUser == null) return;

    final ok = await _confirmDialog(
      title: 'Change City',
      message:
          'Your shops and orders will switch to ${CityScopeService.cityLabel(normalized)}. Continue?',
      confirmLabel: 'Change',
      confirmColor: _primary,
    );
    if (ok != true) return;

    setState(() => _isCityUpdating = true);
    try {
      final uid = _currentUser!.uid;
      final role = (_userData?['role'] ?? 'customer').toString().toLowerCase();

      if (role == 'admin') {
        await _authService.assignAdminCityScope(uid: uid, city: normalized);
      } else {
        await _authService.assignUserCityScope(uid: uid, city: normalized);
      }

      await CityScopeService.setSelectedCity(normalized);

      if (!mounted) return;
      setState(() => _selectedCity = normalized);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'City updated to ${CityScopeService.cityLabel(normalized)}. Refreshing data...',
          ),
          backgroundColor: _primary,
        ),
      );

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isCityUpdating = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACTIONS
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _handleLogout() async {
    final ok = await _confirmDialog(
      title: 'Logout', message: 'Are you sure you want to log out?',
      confirmLabel: 'Logout', confirmColor: Colors.red,
    );
    if (ok == true) {
      await _authService.signOut();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
      }
    }
  }

  Future<bool?> _confirmDialog({
    required String title, required String message,
    required String confirmLabel, Color? confirmColor,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(message, style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: confirmColor ?? _primary, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  String _whatsAppNumberForUrl(String rawPhone) {
    final digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    if (digits.startsWith('00') && digits.length > 2) {
      return digits.substring(2);
    }
    if (digits.startsWith('0') && digits.length > 1) {
      return '92${digits.substring(1)}';
    }
    return digits;
  }

  Future<void> _launchWhatsApp() async {
    final waNumber = _whatsAppNumberForUrl(_supportWhatsAppPhone);
    if (waNumber.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp support number is not available.')),
      );
      return;
    }

    final message = Uri.encodeComponent('Hello GharTek Support');
    final uri = Uri.parse('https://wa.me/$waNumber?text=$message');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callSupport() async {
    final callNumber = _supportPhone.trim();
    if (callNumber.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Call support number is not available.')),
      );
      return;
    }

    final uri = Uri(scheme: 'tel', path: callNumber);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _launchPlayStoreRating() async {
    final uri = Uri.parse('https://play.google.com/store/apps/details?id=com.ghartek&pcampaignid=web_share');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open Play Store link right now.')),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _loadAll,
              child: CustomScrollView(
                slivers: [
                  _buildSliverHeader(),
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        _buildAccountOverview(),
                        const SizedBox(height: 12),
                        _buildSection(title: 'ACCOUNT', items: _accountItems()),
                        const SizedBox(height: 12),
                        _buildSection(title: 'LEGAL', items: _legalItems()),
                        const SizedBox(height: 12),
                        _buildSection(title: 'SUPPORT', items: _supportItems()),
                        const SizedBox(height: 18),
                        _buildLogoutButton(),
                        const SizedBox(height: 16),
                        _buildFooter(),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // WIDGETS
  // ─────────────────────────────────────────────────────────────────────────────

  void _showLoginDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Login Required'),
        content: const Text('Please login to continue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
            },
            child: const Text('Login'),
          ),
        ],
      ),
    );
  }

  Widget _buildSliverHeader() {
    return SliverAppBar(
      toolbarHeight: 62,
      pinned: true,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: const Color(0xFFF7F8FC),
      foregroundColor: const Color(0xFF1A1A1A),
      centerTitle: false,
      automaticallyImplyLeading: false,
      titleSpacing: 10,
      title: const Text(
        'Profile',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, thickness: 1, color: Colors.grey[200]),
      ),
    );
  }

  Widget _buildAccountOverview() {
    final name = _userData?['name'] ?? _currentUser?.displayName ?? 'User';
    final email = _currentUser?.email ?? '';
    final phone = (_userData?['phoneNumber'] ?? '').toString();
    final uid = _currentUser?.uid ?? '';
    final shortUid = uid.length >= 8 ? uid.substring(0, 8).toUpperCase() : uid.toUpperCase();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F2F6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    if (email.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        email,
                        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (phone.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.phone_android_rounded, size: 14, color: Colors.grey[500]),
                        const SizedBox(width: 5),
                        Text(phone, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                      ]),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection({required String title, required List<_SettingsItem> items}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F2F6)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.035), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text(title, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w800, color: Colors.grey[500], letterSpacing: 0.9,
            )),
          ),
          ...items.asMap().entries.map((e) {
            final i = e.key;
            return Column(children: [
              _buildTile(e.value),
              if (i < items.length - 1) Divider(height: 1, indent: 72, endIndent: 18, color: Colors.grey[100]),
            ]);
          }),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildTile(_SettingsItem item) {
    return InkWell(
      onTap: item.onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: item.iconBg ?? item.iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: item.iconColor, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A))),
              if (item.subtitle != null) ...[
                const SizedBox(height: 3),
                Text(item.subtitle!,
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF9B9B9B))),
              ],
            ],
          )),
          if (item.trailing != null) item.trailing!
          else Icon(Icons.chevron_right_rounded, color: Colors.grey[300], size: 20),
        ]),
      ),
    );
  }

  List<_SettingsItem> _accountItems() => [
    _SettingsItem(
      icon: Icons.manage_accounts_rounded,
      title: 'Edit Profile',
      subtitle: 'Update name, phone, gender',
      iconColor: const Color(0xFFFF6B00),
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(
            builder: (_) => EditProfilePage(userData: _userData)));
        _loadAll();
      },
    ),
    _SettingsItem(
      icon: Icons.location_city_rounded,
      title: 'Your City',
      subtitle: _isCityUpdating
          ? 'Updating city...'
          : 'Current: ${CityScopeService.cityLabel(_selectedCity)} · Tap to change',
      iconColor: const Color(0xFF2563EB),
      onTap: _pickAndChangeCity,
      trailing: _isCityUpdating
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    ),
    _SettingsItem(
      icon: Icons.notifications_outlined,
      title: 'Notifications',
      subtitle: 'Order updates & alerts',
      iconColor: Colors.purple,
      onTap: () {},
      trailing: Transform.scale(
        scale: 0.85,
        child: Switch.adaptive(
          value: _notificationsEnabled,
          onChanged: (v) async {
            setState(() => _notificationsEnabled = v);
            final user = FirebaseAuth.instance.currentUser;
            if (user != null) {
              await _db.child('users/${user.uid}/notificationsEnabled').set(v);
            }
          },
          activeThumbColor: _primary,
        ),
      ),
    ),
  ];

  List<_SettingsItem> _legalItems() => [
    _SettingsItem(
      icon: Icons.privacy_tip_outlined,
      title: 'Privacy Policy',
      subtitle: 'How we use your data',
      iconColor: const Color(0xFFFF6B00),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyPolicyPage())),
    ),
    _SettingsItem(
      icon: Icons.gavel_rounded,
      title: 'Terms & Conditions',
      subtitle: 'Our service agreement',
      iconColor: const Color(0xFFFF6B00),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermsConditionsPage())),
    ),
    _SettingsItem(
      icon: Icons.assignment_return_outlined,
      title: 'Refund Policy',
      subtitle: 'Cancellations & returns',
      iconColor: const Color(0xFFFF6B00),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RefundPolicyPage())),
    ),
    _SettingsItem(
      icon: Icons.info_outline_rounded,
      title: 'About GharTek',
      subtitle: 'App info & version 4.0.0',
      iconColor: Colors.grey,
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutUsPage())),
    ),
  ];

  List<_SettingsItem> _supportItems() => [
    _SettingsItem(
      icon: Icons.headset_mic_outlined,
      title: 'Help Center',
      subtitle: 'FAQs & getting help • ${CityScopeService.cityLabel(_selectedCity)}',
      iconColor: const Color(0xFFFF6B00),
      onTap: _showHelpDialog,
    ),
    _SettingsItem(
      icon: Icons.support_agent_rounded,
      title: 'Chat with GharTek Support',
      subtitle: 'In-app live chat support',
      iconColor: Colors.blue,
      iconBg: Colors.blue.shade50,
      onTap: () {
        if (_currentUser == null) {
          _showLoginDialog();
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const UserChatPage()),
        );
      },
    ),
    _SettingsItem(
      icon: Icons.chat_bubble_outline_rounded,
      title: 'WhatsApp Support',
      subtitle: 'Chat with us · ${_supportWhatsAppPhone.trim()}',
      iconColor: const Color(0xFF25D366),
      iconBg: const Color(0xFFE8F5E9),
      onTap: _launchWhatsApp,
    ),
    _SettingsItem(
      icon: Icons.phone_outlined,
      title: 'Call Support',
      subtitle: _supportPhone.trim(),
      iconColor: const Color(0xFFFF6B00),
      onTap: _callSupport,
    ),
    _SettingsItem(
      icon: Icons.star_border_rounded,
      title: 'Rate GharTek',
      subtitle: 'Rate us on Play Store',
      iconColor: Colors.amber,
      onTap: _launchPlayStoreRating,
    ),
  ];

  Widget _buildLogoutButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: GestureDetector(
        onTap: _handleLogout,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.red[200]!),
            boxShadow: [BoxShadow(color: Colors.red.withValues(alpha: 0.05), blurRadius: 9, offset: const Offset(0, 2))],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.logout_rounded, color: Colors.red[600], size: 20),
              const SizedBox(width: 10),
              Text('Logout', style: TextStyle(color: Colors.red[600], fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(children: [
      Text('GharTek  ·  v4.0.0',
          style: TextStyle(fontSize: 12, color: Colors.grey[500], fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Text('Thanks for using GharTek', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
    ]);
  }

  // ─── Dialogs & Sheets ────────────────────────────────────────────────────────

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Help & Support', style: TextStyle(fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _contactRow(Icons.phone_rounded, _supportPhone.trim(), const Color(0xFFFF6B00)),
          const SizedBox(height: 10),
          _contactRow(Icons.email_rounded, _supportEmail.trim(), Colors.red),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(10)),
            child: InkWell(
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UserChatPage()));
              },
              child: const Row(
                children: [
                  Icon(Icons.support_agent_rounded, color: Colors.blue),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Chat with GharTek Support',
                        style: TextStyle(fontSize: 13, color: Colors.blue, fontWeight: FontWeight.bold)),
                  ),
                  Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Colors.blue),
                ],
              ),
            ),
          ),
        ]),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _contactRow(IconData icon, String text, Color color) {
    return Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: color, size: 16),
      ),
      const SizedBox(width: 10),
      Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
    ]);
  }

  void _showAddressesSheet() {
    final user = _authService.currentUser;
    if (user == null) return;
    final db = _db.child('users/${user.uid}/addresses');
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, ss) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              left: 20, right: 20, top: 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: Colors.orange[50], borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.location_on_rounded, color: Colors.orange[700], size: 20),
              ),
              const SizedBox(width: 10),
              const Text('Saved Addresses', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 14),
            StreamBuilder(
              stream: db.onValue,
              builder: (ctx, snap) {
                if (!snap.hasData || snap.data?.snapshot.value == null) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(Icons.location_off_rounded, color: Colors.grey[300], size: 18),
                      const SizedBox(width: 8),
                      Text('No saved addresses yet', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                    ]),
                  );
                }
                final data = snap.data!.snapshot.value as Map<dynamic, dynamic>;
                return Column(children: data.entries.map((e) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey[50], borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[100]!),
                  ),
                  child: Row(children: [
                    const Icon(Icons.pin_drop_rounded, color: _primary, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e.value.toString(),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                    GestureDetector(
                      onTap: () => db.child(e.key.toString()).remove(),
                      child: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 18),
                    ),
                  ]),
                )).toList());
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  hintText: 'New address...',
                  hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                  filled: true, fillColor: Colors.grey[50],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _primary, width: 1.5)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              )),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  final v = ctrl.text.trim();
                  if (v.isNotEmpty) { db.push().set(v); ctrl.clear(); }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), elevation: 0,
                ),
                child: const Text('Add'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _SettingsItem {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color iconColor;
  final Color? iconBg;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SettingsItem({
    required this.icon, required this.title, this.subtitle,
    required this.iconColor, this.iconBg, required this.onTap, this.trailing,
  });
}
