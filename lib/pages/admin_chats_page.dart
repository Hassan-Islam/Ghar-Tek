import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import '../services/notification_service.dart';

class AdminChatsPage extends StatefulWidget {
  const AdminChatsPage({super.key});

  @override
  State<AdminChatsPage> createState() => _AdminChatsPageState();
}

class _AdminChatsPageState extends State<AdminChatsPage> {
  static const Color _primary = Color(0xFFFF6B00);
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
    await CityScopeService.ensureLoaded();
    _chatsSub?.cancel();
    _chatsSub = _db.child(_tenantPath('chats')).onValue.listen((event) {
      final list = <Map<String, dynamic>>[];
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        data.forEach((userKey, userValue) {
          if (userValue is! Map) return;
          final userMap = Map<dynamic, dynamic>.from(userValue as Map);

          if (_looksLikeLegacyThread(userMap)) {
            final meta = _extractMeta(userMap);
            if (meta == null) return;
            meta['userId'] = (meta['userId'] ?? userKey).toString();
            meta['orderId'] = (meta['orderId'] ?? meta['lastOrderId'] ?? 'general').toString();
            list.add(meta);
            return;
          }

          userMap.forEach((orderKey, orderValue) {
            if (orderValue is! Map) return;
            final orderMap = Map<dynamic, dynamic>.from(orderValue as Map);
            final meta = _extractMeta(orderMap);
            if (meta == null) return;
            meta['userId'] = (meta['userId'] ?? userKey).toString();
            meta['orderId'] = (meta['orderId'] ?? orderKey).toString();
            list.add(meta);
          });
        });
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
    return row.containsKey('meta') ||
        row.containsKey('messages') ||
        row.containsKey('lastMessage');
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

  String _orderLabel(Map<String, dynamic> row) {
    final code = (row['orderCode'] ?? '').toString().trim();
    final id = (row['orderId'] ?? row['lastOrderId'] ?? '').toString().trim();
    return code.isNotEmpty ? code : id;
  }

  Future<Map<String, dynamic>?> _fetchOrder(String orderId, String orderType) async {
    await CityScopeService.ensureLoaded();
    try {
      final snap = await _db.child(_tenantPath('shop-orders/$orderId')).get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        data['id'] = orderId;
        data['orderType'] = 'shop';
        return data;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _openOrderPreview(String orderId, String orderType) async {
    final order = await _fetchOrder(orderId, orderType);
    if (!mounted) return;
    if (order == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order not found.')),
      );
      return;
    }

    final status = (order['status'] ?? '').toString();
    final shopName = (order['shopName'] ?? order['shop'] ?? 'Order').toString();
    final contact = (order['contact'] ?? order['userPhone'] ?? '').toString();
    final address = (order['address'] ?? order['fullAddress'] ?? '').toString();
    final orderCode = (order['customOrderId'] ?? order['id'] ?? '').toString();
    final total = (order['grandTotal'] ?? order['budget'] ?? '').toString();
    final items = order['items'];
    final itemsText = items is List
        ? items
            .map((i) => '${i['quantity'] ?? 1}× ${i['name'] ?? 'Item'}')
            .join(', ')
        : (order['whatYouWant'] ?? '').toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shopName,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('Order: $orderCode', style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 6),
            Text('Status: $status', style: TextStyle(color: Colors.grey[700])),
            if (total.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Total: Rs. $total', style: TextStyle(color: Colors.grey[700])),
            ],
            if (contact.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Contact: $contact', style: TextStyle(color: Colors.grey[700])),
            ],
            if (address.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Address: $address', style: TextStyle(color: Colors.grey[700])),
            ],
            if (itemsText.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Items: $itemsText', style: TextStyle(color: Colors.grey[700])),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _threads.isEmpty
              ? const Center(child: Text('No chats yet.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _threads.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final row = _threads[i];
                    final name = (row['userName'] ?? 'User').toString();
                    final phone = (row['userPhone'] ?? '').toString();
                    final lastMessage = (row['lastMessage'] ?? '').toString();
                    final orderId =
                      (row['orderId'] ?? row['lastOrderId'] ?? '').toString();
                    final orderType = (row['orderType'] ?? '').toString();
                    final orderLabel = _orderLabel(row);
                    final unread = row['unreadByAdmin'] == true;
                    return ListTile(
                      tileColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey[200]!),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: unread ? _primary : Colors.grey[300],
                        child: Icon(
                          Icons.chat_bubble_rounded,
                          color: unread ? Colors.white : Colors.grey[700],
                        ),
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (phone.isNotEmpty)
                            Text(phone, style: TextStyle(color: Colors.grey[600])),
                          if (lastMessage.isNotEmpty)
                            Text(
                              lastMessage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.grey[700]),
                            ),
                          if (orderLabel.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  'Order: $orderLabel',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: orderId.isEmpty
                                      ? null
                                      : () => _openOrderPreview(
                                            orderId,
                                            orderType,
                                          ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: _primary,
                                    side: BorderSide(
                                      color: _primary.withValues(alpha: 0.4),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    textStyle: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  child: const Text('View Order'),
                                ),
                              ],
                            ),
                        ],
                      ),
                      trailing: Text(
                        _fmtTime(row['lastMessageAt']),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AdminChatDetailPage(
                              userId: row['userId'] ?? '',
                              userName: name,
                              userPhone: phone,
                              orderId: orderId,
                              orderType: orderType,
                              orderCode: (row['orderCode'] ?? '').toString(),
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

class AdminChatDetailPage extends StatefulWidget {
  final String userId;
  final String userName;
  final String userPhone;
  final String orderId;
  final String orderType;
  final String orderCode;

  const AdminChatDetailPage({
    super.key,
    required this.userId,
    required this.userName,
    required this.userPhone,
    this.orderId = '',
    this.orderType = '',
    this.orderCode = '',
  });

  @override
  State<AdminChatDetailPage> createState() => _AdminChatDetailPageState();
}

class _AdminChatDetailPageState extends State<AdminChatDetailPage> {
  static const Color _primary = Color(0xFFFF6B00);
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _messageCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<DatabaseEvent>? _messagesSub;
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  String get _chatOrderId {
    final raw = widget.orderId.trim();
    return raw.isEmpty ? 'general' : raw;
  }

  String _chatPathForAdmin(String leaf) {
    return _tenantPath('chats/${widget.userId}/$_chatOrderId/$leaf');
  }

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    _listenMessages();
    _markReadForAdmin();
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _messageCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _listenMessages() async {
    await CityScopeService.ensureLoaded();
    _messagesSub?.cancel();
    _messagesSub = _db
      .child(_chatPathForAdmin('messages'))
        .onValue
        .listen((event) {
      final list = <Map<String, dynamic>>[];
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        data.forEach((key, value) {
          if (value is! Map) return;
          final row = Map<String, dynamic>.from(value);
          row['id'] = key.toString();
          list.add(row);
        });
      }
      list.sort((a, b) => _toInt(a['createdAt']).compareTo(_toInt(b['createdAt'])));
      if (mounted) {
        setState(() {
          _messages = list;
          _loading = false;
        });
        _scrollToBottom();
      }
    });
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _markReadForAdmin() async {
    await CityScopeService.ensureLoaded();
    await _db.child(_chatPathForAdmin('meta')).update({
      'unreadByAdmin': false,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageCtrl.text.trim();
    if (text.isEmpty) return;

    _messageCtrl.clear();
    await CityScopeService.ensureLoaded();

    final msgRef = _db.child(_chatPathForAdmin('messages')).push();
    await msgRef.set({
      'text': text,
      'senderRole': 'admin',
      'createdAt': ServerValue.timestamp,
      'createdAtClient': DateTime.now().millisecondsSinceEpoch,
    });

    await _db.child(_chatPathForAdmin('meta')).update({
      'userId': widget.userId,
      'userName': widget.userName,
      'userPhone': widget.userPhone,
      'lastMessage': text,
      'lastMessageAt': ServerValue.timestamp,
      'orderId': _chatOrderId,
      'orderType': widget.orderType.trim(),
      'orderCode': widget.orderCode.trim(),
      'lastOrderId': _chatOrderId,
      'unreadByAdmin': false,
      'unreadByUser': true,
      'updatedAt': ServerValue.timestamp,
    });

    // Push notification entry and send push notification to Customer
    try {
      unawaited(
        NotificationService.sendToSpecificUser(
          target: widget.userId,
          title: 'Message from Ghartek',
          body: text,
          type: 'admin_message',
          source: 'admin_chat',
          details: {
            'orderId': _chatOrderId,
            'orderType': widget.orderType.trim(),
            'orderCode': widget.orderCode.trim(),
          },
          data: {
            'type': 'chat_message',
            'senderRole': 'admin',
            'userId': widget.userId,
            'userName': widget.userName,
            'userPhone': widget.userPhone,
            'orderId': _chatOrderId,
            'orderType': widget.orderType.trim(),
            'orderCode': widget.orderCode.trim(),
          },
        ).catchError((_) => {}),
      );

      // Also increment unreadCount in meta so UI shows numeric badge
      try {
        final metaSnap = await _db.child(_chatPathForAdmin('meta')).get();
        int cur = 0;
        if (metaSnap.exists && metaSnap.value is Map) {
          final m = Map<dynamic, dynamic>.from(metaSnap.value as Map);
          cur = (m['unreadCount'] is int) ? m['unreadCount'] as int : int.tryParse((m['unreadCount'] ?? '').toString()) ?? 0;
        }
        await _db.child(_chatPathForAdmin('meta')).update({'unreadCount': cur + 1});
      } catch (_) {}
    } catch (_) {}

    _scrollToBottom();
  }

  String _fmtTime(dynamic value) {
    final ts = _toInt(value);
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final min = dt.minute.toString().padLeft(2, '0');
    return '$hour:$min ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    final isAdmin = (msg['senderRole'] ?? '') == 'admin';
    final align = isAdmin ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final timeStr = _fmtTime(msg['createdAt']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: isAdmin 
                ? const LinearGradient(
                    colors: [Color(0xFFFF6B00), Color(0xFFFF8A65)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
              color: isAdmin ? null : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: isAdmin ? const Radius.circular(20) : const Radius.circular(4),
                bottomRight: isAdmin ? const Radius.circular(4) : const Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: isAdmin 
                    ? const Color(0xFFFF6B00).withValues(alpha: 0.25)
                    : Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: isAdmin ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  (msg['text'] ?? '').toString(),
                  style: TextStyle(
                    color: isAdmin ? Colors.white : const Color(0xFF1F2937),
                    fontSize: 15,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (timeStr.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        timeStr,
                        style: TextStyle(
                          color: isAdmin ? Colors.white.withValues(alpha: 0.8) : const Color(0xFF9CA3AF),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isAdmin) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.done_all_rounded,
                          size: 14,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ],
                    ],
                  ),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE5DDD5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white24,
              child: Icon(Icons.person, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.userName.isNotEmpty ? widget.userName : 'Customer',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  if (widget.userPhone.isNotEmpty)
                    Text(
                      widget.userPhone,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  if (widget.orderCode.isNotEmpty)
                    Text(
                      'Order: ${widget.orderCode}',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.chat_bubble_outline_rounded, size: 40, color: Color(0xFF075E54)),
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              'No Messages Yet',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.black54),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _buildMessageBubble(_messages[i]),
                      ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            color: Colors.transparent,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          offset: const Offset(0, 1),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _messageCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        hintStyle: TextStyle(color: Colors.black38),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _sendMessage,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0xFF075E54),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
