import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import 'user_chat_page.dart';

class UserChatsListPage extends StatefulWidget {
  const UserChatsListPage({super.key});

  @override
  State<UserChatsListPage> createState() => _UserChatsListPageState();
}

class _UserChatsListPageState extends State<UserChatsListPage> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  StreamSubscription<DatabaseEvent>? _chatsSub;
  List<Map<String, dynamic>> _threads = [];
  bool _loading = true;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    _listenChats();
  }

  @override
  void dispose() {
    _chatsSub?.cancel();
    super.dispose();
  }

  void _listenChats() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await CityScopeService.ensureLoaded();
    _chatsSub?.cancel();
    _chatsSub = _db.child(_tenantPath('chats/${user.uid}')).onValue.listen((event) {
      final list = <Map<String, dynamic>>[];
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        
        if (_looksLikeLegacyThread(data)) {
          final meta = _extractMeta(data);
          if (meta != null) {
            meta['orderId'] = (meta['orderId'] ?? meta['lastOrderId'] ?? 'general').toString();
            list.add(meta);
          }
        } else {
          data.forEach((orderKey, orderValue) {
            if (orderValue is! Map) return;
            final orderMap = Map<dynamic, dynamic>.from(orderValue as Map);
            final meta = _extractMeta(orderMap);
            if (meta == null) return;
            meta['orderId'] = (meta['orderId'] ?? orderKey).toString();
            list.add(meta);
          });
        }
      }
      list.sort((a, b) => _toInt(b['lastMessageAt']).compareTo(_toInt(a['lastMessageAt'])));
      if (mounted) {
        setState(() {
          _threads = list;
          _loading = false;
        });
      }
    });
  }

  bool _looksLikeLegacyThread(Map<dynamic, dynamic> row) {
    return row.containsKey('meta') || row.containsKey('messages') || row.containsKey('lastMessage');
  }

  Map<String, dynamic>? _extractMeta(Map<dynamic, dynamic> row) {
    final raw = row['meta'] is Map ? row['meta'] : row;
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw as Map);
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _fmtTime(dynamic value) {
    final ts = _toInt(value);
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final min = dt.minute.toString().padLeft(2, '0');
    return '$hour:$min ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Chats'),
        backgroundColor: const Color(0xFF075E54), // WhatsApp color
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const UserChatPage(
                orderId: 'support',
                orderType: 'support',
                orderCode: 'Ghartek Support',
                autoStartSupport: true,
              ),
            ),
          );
        },
        backgroundColor: Colors.blue,
        icon: const Icon(Icons.support_agent_rounded, color: Colors.white),
        label: const Text('New Support Chat', style: TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _threads.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded, size: 60, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No conversations yet.', style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _threads.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final row = _threads[i];
                    final lastMessage = (row['lastMessage'] ?? '').toString();
                    final orderId = (row['orderId'] ?? '').toString();
                    final orderType = (row['orderType'] ?? '').toString();
                    final orderCode = (row['orderCode'] ?? '').toString();
                    final title = orderCode.isNotEmpty ? orderCode : (orderId == 'support' ? 'Ghartek Support' : 'Order $orderId');
                    final unread = row['unreadByUser'] == true;

                    return ListTile(
                      tileColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey[200]!),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: unread ? Colors.blue : Colors.grey[100],
                        child: Icon(
                          orderId == 'support' ? Icons.support_agent_rounded : Icons.receipt_long_rounded,
                          color: unread ? Colors.white : Colors.grey[700],
                        ),
                      ),
                      title: Text(
                        title,
                        style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w600),
                      ),
                      subtitle: lastMessage.isNotEmpty
                          ? Text(
                              lastMessage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: unread ? Colors.black87 : Colors.grey[600],
                                fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                              ),
                            )
                          : null,
                      trailing: Text(
                        _fmtTime(row['lastMessageAt']),
                        style: TextStyle(fontSize: 11, color: unread ? Colors.blue : Colors.grey[500]),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserChatPage(
                              orderId: orderId,
                              orderType: orderType,
                              orderCode: orderCode,
                              autoStartSupport: orderId == 'support',
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}
