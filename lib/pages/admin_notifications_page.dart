import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import '../services/notification_service.dart';

class AdminNotificationsPage extends StatefulWidget {
  const AdminNotificationsPage({super.key});

  @override
  State<AdminNotificationsPage> createState() =>
      _AdminNotificationsPageState();
}

class _AdminNotificationsPageState extends State<AdminNotificationsPage> {
  static const Color _primary = Color(0xFFFF6B00);

  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _sending = false;
  bool _loadingHistory = true;
  List<Map<String, dynamic>> _history = [];
  bool _sendToSpecificUser = false;
  bool _loadingUsers = false;
  List<Map<String, dynamic>> _users = [];
  String? _selectedUserId;

  String _tenantPath(String path, {String? city}) =>
      CityScopeService.tenantPath(path, city: city);

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadUsers();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  String _userDisplayLabel(Map<String, dynamic> user) {
    final name = (user['name'] ?? '').toString().trim();
    final email = (user['email'] ?? '').toString().trim();
    final uid = (user['uid'] ?? '').toString();
    if (name.isNotEmpty) return name;
    if (email.isNotEmpty) return email;
    return uid;
  }

  Map<String, dynamic>? _findUserById(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    for (final user in _users) {
      if ((user['uid'] ?? '').toString() == uid) return user;
    }
    return null;
  }

  Future<void> _loadUsers() async {
    if (_loadingUsers) return;
    setState(() => _loadingUsers = true);
    try {
      await CityScopeService.ensureLoaded();
      final currentCity = CityScopeService.currentCity;
      final snap = await FirebaseDatabase.instance.ref('users').get();
      final users = <Map<String, dynamic>>[];
      if (snap.exists && snap.value is Map) {
        final data = snap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          if (val is! Map) return;
          final row = Map<String, dynamic>.from(val);
          final role = (row['role'] ?? 'customer').toString();
          final city = role.toLowerCase() == 'admin'
              ? (row['adminCity'] ?? '').toString()
              : (row['userCity'] ?? '').toString();
          final normalizedCity = CityScopeService.normalizeCity(city);
          if (normalizedCity != currentCity) return;
          users.add({
            'uid': key.toString(),
            'name': (row['name'] ?? row['displayName'] ?? '').toString(),
            'email': (row['email'] ?? '').toString(),
            'role': role,
            'city': normalizedCity,
          });
        });
        users.sort((a, b) => _userDisplayLabel(a)
            .toLowerCase()
            .compareTo(_userDisplayLabel(b).toLowerCase()));
      }

      if (!mounted) return;
      setState(() {
        _users = users;
        if (_selectedUserId != null &&
            !_users.any((u) => (u['uid'] ?? '').toString() == _selectedUserId)) {
          _selectedUserId = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) {
        setState(() => _loadingUsers = false);
      }
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      await CityScopeService.ensureLoaded();
      final snap =
          await FirebaseDatabase.instance.ref(_tenantPath('notifications/history')).get();
      final list = <Map<String, dynamic>>[];
      if (snap.exists) {
        final data = snap.value as Map<dynamic, dynamic>;
        data.forEach((key, val) {
          final item = Map<String, dynamic>.from(val);
          item['key'] = key;
          list.add(item);
        });
        list.sort((a, b) =>
            (b['timestamp'] as int).compareTo(a['timestamp'] as int));
      }
      setState(() {
        _history = list;
        _loadingHistory = false;
      });
    } catch (_) {
      setState(() => _loadingHistory = false);
    }
  }

  Future<void> _sendNotification() async {
    if (!_formKey.currentState!.validate()) return;

    final selectedUserId = _selectedUserId;
    if (_sendToSpecificUser && (selectedUserId == null || selectedUserId.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a user'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_sendToSpecificUser) {
      await CityScopeService.ensureLoaded();
      final currentCity = CityScopeService.currentCity;
      final selectedUser = _findUserById(selectedUserId);
      final targetCity = CityScopeService.normalizeCity(selectedUser?['city']);
      if (selectedUser != null && targetCity != currentCity) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Selected user is not in ${CityScopeService.cityLabel(currentCity)}.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    setState(() => _sending = true);
    try {
      final title = _titleController.text.trim();
      final body = _bodyController.text.trim();

      String targetCity;
      String successMessage;
      final historyEntry = <String, dynamic>{
        'title': title,
        'body': body,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      if (_sendToSpecificUser) {
        final selectedUser = _findUserById(selectedUserId);
        final result = await NotificationService.sendToSpecificUser(
          target: selectedUserId!,
          title: title,
          body: body,
        );
        targetCity = result['city'] ?? CityScopeService.currentCity;
        final targetUserId = result['userId'] ?? selectedUserId;
        final targetUserLabel =
            result['userLabel'] ??
            (selectedUser != null ? _userDisplayLabel(selectedUser) : targetUserId);
        historyEntry['city'] = targetCity;
        historyEntry['targetType'] = 'specific';
        historyEntry['targetUserId'] = targetUserId;
        historyEntry['targetUserLabel'] = targetUserLabel;
        historyEntry['delivery'] = 'fcm_manual';
        historyEntry['fcmSentCount'] = int.tryParse(result['fcmSent'] ?? '0') ?? 0;
        historyEntry['fcmFailedCount'] = int.tryParse(result['fcmFailed'] ?? '0') ?? 0;
        successMessage =
            'Notification sent to $targetUserLabel (FCM sent: ${result['fcmSent'] ?? '0'})';
      } else {
        final result = await NotificationService.sendBroadcastToAll(
          title: title,
          body: body,
        );
        targetCity = result['city'] ?? CityScopeService.currentCity;
        historyEntry['city'] = targetCity;
        historyEntry['targetType'] = 'broadcast';
        historyEntry['delivery'] = 'fcm_manual';
        historyEntry['fcmSentCount'] = int.tryParse(result['fcmSent'] ?? '0') ?? 0;
        historyEntry['fcmFailedCount'] = int.tryParse(result['fcmFailed'] ?? '0') ?? 0;
        successMessage =
            'Notification sent to ${CityScopeService.cityLabel(targetCity)} users (FCM sent: ${result['fcmSent'] ?? '0'})';
      }

      // Save to history
      await FirebaseDatabase.instance
          .ref(_tenantPath('notifications/history', city: targetCity))
          .push()
          .set(historyEntry);

      _titleController.clear();
      _bodyController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(successMessage),
            backgroundColor: Colors.green,
          ),
        );
      }
      await _loadHistory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteNotification(String key) async {
    await CityScopeService.ensureLoaded();
    await FirebaseDatabase.instance
        .ref(_tenantPath('notifications/history/$key'))
        .remove();
    _loadHistory();
  }

  String _timeAgo(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F0),
      appBar: AppBar(
        title: const Text('Push Notifications',
            style:
                TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: _loadHistory),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Compose card
            _buildComposeCard(),
            const SizedBox(height: 24),

            // History
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Sent Notifications',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                if (_loadingHistory)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: _primary, strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 12),
            if (!_loadingHistory && _history.isEmpty)
              Center(
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    Icon(Icons.notifications_none,
                        size: 48, color: Colors.grey[300]),
                    const SizedBox(height: 8),
                    Text('No notifications sent yet',
                        style: TextStyle(color: Colors.grey[400])),
                  ],
                ),
              ),
            ..._history.map((n) => _buildHistoryCard(n)),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _buildComposeCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.campaign, color: _primary),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _sendToSpecificUser ? 'Send to Specific User' : 'Send Broadcast',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      _sendToSpecificUser
                          ? 'Select user from list and notify'
                          : 'Notify all users at once',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: const Text('All Users'),
                    selected: !_sendToSpecificUser,
                    onSelected: (_) => setState(() => _sendToSpecificUser = false),
                    selectedColor: _primary.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: !_sendToSpecificUser ? _primary : Colors.grey[700],
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: const Text('Specific User'),
                    selected: _sendToSpecificUser,
                    onSelected: (_) => setState(() => _sendToSpecificUser = true),
                    selectedColor: _primary.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: _sendToSpecificUser ? _primary : Colors.grey[700],
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (_sendToSpecificUser) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Select Target User',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (_loadingUsers)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(color: _primary, strokeWidth: 2),
                    ),
                  IconButton(
                    onPressed: _loadingUsers ? null : _loadUsers,
                    icon: const Icon(Icons.refresh_rounded, size: 18, color: _primary),
                    tooltip: 'Refresh users',
                  ),
                ],
              ),
              if (!_loadingUsers && _users.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF5F5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFE0E0)),
                  ),
                  child: const Text(
                    'No users available right now',
                    style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey<String?>(_users.any((u) => (u['uid'] ?? '').toString() == _selectedUserId)
                    ? _selectedUserId
                    : null),
                  initialValue: _users.any((u) => (u['uid'] ?? '').toString() == _selectedUserId)
                      ? _selectedUserId
                      : null,
                  isExpanded: true,
                  validator: (v) {
                    if (!_sendToSpecificUser) return null;
                    return v == null || v.isEmpty ? 'Please select a user' : null;
                  },
                  decoration: _inputDecoration('Select user', Icons.people_alt_rounded),
                  items: _users.map((u) {
                    final uid = (u['uid'] ?? '').toString();
                    final role = (u['role'] ?? 'customer').toString().toUpperCase();
                    final name = _userDisplayLabel(u);
                    final email = (u['email'] ?? '').toString().trim();
                    final secondary = email.isNotEmpty ? email : uid;
                    return DropdownMenuItem<String>(
                      value: uid,
                      child: Text(
                        '$name • $secondary ($role)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (v) => setState(() => _selectedUserId = v),
                ),
              if (_users.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${_users.length} users available',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _titleController,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Title required' : null,
              decoration: _inputDecoration('Notification Title',
                  Icons.title_rounded),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _bodyController,
              maxLines: 3,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Message required' : null,
              decoration:
                  _inputDecoration('Notification Message', Icons.message),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _sending ? null : _sendNotification,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: Text(
                  _sending
                      ? 'Sending...'
                      : _sendToSpecificUser
                          ? 'Send to Specific User'
                          : 'Send to All Users',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
      prefixIcon: Icon(icon, color: _primary, size: 20),
      filled: true,
      fillColor: const Color(0xFFF9F9F9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.red, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.red, width: 1.5),
      ),
    );
  }

  Widget _buildHistoryCard(Map<String, dynamic> n) {
    final targetType = (n['targetType'] ?? 'broadcast').toString();
    final targetUser = (n['targetUserLabel'] ?? n['targetUserId'] ?? '').toString();
    final city = (n['city'] ?? '').toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey[100]!),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.notifications, color: _primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n['title'] ?? '',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 3),
                Text(n['body'] ?? '',
                    style:
                        TextStyle(color: Colors.grey[600], fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  targetType == 'specific'
                      ? 'Target: $targetUser'
                      : 'Target: All Users${city.isNotEmpty ? ' • ${CityScopeService.cityLabel(city)}' : ''}',
                  style: TextStyle(
                    color: targetType == 'specific' ? _primary : Colors.grey[500],
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _timeAgo(n['timestamp'] ?? 0),
                  style: TextStyle(
                      color: Colors.grey[400], fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: Colors.red, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _deleteNotification(n['key']),
          ),
        ],
      ),
    );
  }
}
