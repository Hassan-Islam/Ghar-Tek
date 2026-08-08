import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/city_scope_service.dart';
import '../services/notification_service.dart';

class UserChatPage extends StatefulWidget {
  final String? orderId;
  final String? orderType;
  final String? orderCode;
  final bool isRiderChat;
  final String? riderName;
  final bool isRiderMode;

  final bool autoStartSupport;

  const UserChatPage({
    super.key,
    this.orderId,
    this.orderType,
    this.orderCode,
    this.isRiderChat = false,
    this.riderName,
    this.isRiderMode = false,
    this.autoStartSupport = false,
  });

  @override
  State<UserChatPage> createState() => _UserChatPageState();
}

class _UserChatPageState extends State<UserChatPage> with WidgetsBindingObserver {
  static const Color _primary = Color(0xFFFF6B00);
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _messageCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<DatabaseEvent>? _messagesSub;
  StreamSubscription<DatabaseEvent>? _metaSub;
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String _userName = '';
  String _userPhone = '';

  bool _adminOnline = false;
  bool _adminTyping = false;
  bool _userTyping = false;
  Timer? _typingTimer;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  String get _chatOrderId {
    final raw = (widget.orderId ?? '').toString().trim();
    return raw.isEmpty ? 'general' : raw;
  }

  String _chatPathForUser(String uid, String leaf) {
    if (widget.isRiderChat) {
      return _tenantPath('rider_chats/$_chatOrderId/$leaf');
    }
    return _tenantPath('chats/$uid/$_chatOrderId/$leaf');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CityScopeService.ensureLoaded();
    _loadUserProfile();
    _listenMessages();
    _listenMeta();
    _markReadForUser();
    _updateUserOnlineStatus(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateUserOnlineStatus(false);
    _messagesSub?.cancel();
    _metaSub?.cancel();
    _typingTimer?.cancel();
    _messageCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateUserOnlineStatus(true);
    } else {
      _updateUserOnlineStatus(false);
    }
  }

  Future<void> _updateUserOnlineStatus(bool isOnline) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();
    await _db.child(_chatPathForUser(user.uid, 'meta')).update({
      'userOnline': isOnline,
      'userLastSeen': ServerValue.timestamp,
    });
  }

  Future<void> _updateUserTypingStatus(bool isTyping) async {
    if (_userTyping == isTyping) return;
    _userTyping = isTyping;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();
    await _db.child(_chatPathForUser(user.uid, 'meta')).update({
      'userTyping': isTyping,
    });
  }

  void _onTextChanged(String text) {
    if (text.isNotEmpty) {
      _updateUserTypingStatus(true);
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 2), () {
        _updateUserTypingStatus(false);
      });
    } else {
      _updateUserTypingStatus(false);
      _typingTimer?.cancel();
    }
  }

  Future<void> _loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap = await _db.child('users/${user.uid}').get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        _userName = (data['name'] ?? user.displayName ?? '').toString().trim();
        _userPhone = (data['phoneNumber'] ?? '').toString().trim();
      }
    } catch (_) {}
  }

  void _listenMessages() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();

    _messagesSub?.cancel();
    _messagesSub = _db
      .child(_chatPathForUser(user.uid, 'messages'))
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
      list.sort(
        (a, b) => _toInt(
          a['createdAtClient'] ?? a['createdAt'],
        ).compareTo(_toInt(b['createdAtClient'] ?? b['createdAt'])),
      );
      if (mounted) {
        setState(() {
          _messages = list;
          _loading = false;
        });
        _scrollToBottom();
        if (widget.autoStartSupport && list.isEmpty) {
          _startConversation();
        }
      }
    });
  }

  void _listenMeta() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();
    
    _metaSub?.cancel();
    _metaSub = _db.child(_chatPathForUser(user.uid, 'meta')).onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
        if (mounted) {
          setState(() {
            _adminOnline = data['adminOnline'] == true;
            _adminTyping = data['adminTyping'] == true;
          });
          if (_adminTyping) {
            _scrollToBottom();
          }
        }
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

  Future<void> _markReadForUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();
    final updates = <String, dynamic>{
      'updatedAt': ServerValue.timestamp,
    };
    if (widget.isRiderMode) {
      updates['unreadByRider'] = false;
    } else if (widget.isRiderChat) {
      updates['unreadByUser'] = false;
    } else {
      updates['unreadByUser'] = false;
    }
    await _db.child(_chatPathForUser(user.uid, 'meta')).update(updates);
  }

  Future<void> _startConversation() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await CityScopeService.ensureLoaded();

    String welcomeMsg = widget.isRiderChat ? 'Hi, I am your Rider!' : 'How May I Help You?';
    if (widget.autoStartSupport) {
      welcomeMsg = 'Welcome to Ghartek Support!\nAap message ke zariye bhi apna order kar sakte hain. Please apna order ya sawal likhein.';
    }

    final msgRef = _db.child(_chatPathForUser(user.uid, 'messages')).push();
    await msgRef.set({
      'text': welcomeMsg,
      'senderRole': widget.isRiderChat ? 'rider' : 'admin',
      'senderId': 'system',
      'createdAt': ServerValue.timestamp,
      'createdAtClient': DateTime.now().millisecondsSinceEpoch,
    });
    
    final metaRef = _db.child(_chatPathForUser(user.uid, 'meta'));
    final metaUpdates = <String, dynamic>{
      'userId': user.uid,
      'userName': _userName.isNotEmpty ? _userName : user.displayName ?? 'User',
      'userPhone': _userPhone,
      'lastMessage': welcomeMsg,
      'lastMessageAt': ServerValue.timestamp,
      'orderId': _chatOrderId,
      'orderType': (widget.orderType ?? '').toString().trim(),
      'orderCode': (widget.orderCode ?? '').toString().trim(),
      'lastOrderId': _chatOrderId,
      'updatedAt': ServerValue.timestamp,
    };
    if (widget.isRiderChat) {
      metaUpdates['unreadByRider'] = false;
      metaUpdates['unreadByUser'] = true;
      metaUpdates['unreadByAdmin'] = false;
    } else {
      metaUpdates['unreadByAdmin'] = false;
      metaUpdates['unreadByUser'] = true;
      metaUpdates['unreadByRider'] = false;
    }
    await metaRef.update(metaUpdates);
  }

  Future<void> _sendMessage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final text = _messageCtrl.text.trim();
    if (text.isEmpty) return;

    _messageCtrl.clear();
    _updateUserTypingStatus(false);
    _typingTimer?.cancel();
    
    await CityScopeService.ensureLoaded();

    final msgRef = _db.child(_chatPathForUser(user.uid, 'messages')).push();
    await msgRef.set({
      'text': text,
      'senderRole': widget.isRiderMode ? 'rider' : 'user',
      'senderId': user.uid,
      'createdAt': ServerValue.timestamp,
      'createdAtClient': DateTime.now().millisecondsSinceEpoch,
    });

    final metaRef = _db.child(_chatPathForUser(user.uid, 'meta'));
    final metaUpdates = <String, dynamic>{
      'userId': user.uid,
      'userName': _userName.isNotEmpty ? _userName : user.displayName ?? 'User',
      'userPhone': _userPhone,
      'lastMessage': text,
      'lastMessageAt': ServerValue.timestamp,
      'orderId': _chatOrderId,
      'orderType': (widget.orderType ?? '').toString().trim(),
      'orderCode': (widget.orderCode ?? '').toString().trim(),
      'lastOrderId': _chatOrderId,
      'updatedAt': ServerValue.timestamp,
    };

    if (widget.isRiderMode) {
      metaUpdates['unreadByUser'] = true;
      metaUpdates['unreadByRider'] = false;
      metaUpdates['unreadByAdmin'] = false;
    } else if (widget.isRiderChat) {
      metaUpdates['unreadByRider'] = true;
      metaUpdates['unreadByUser'] = false;
      metaUpdates['unreadByAdmin'] = false;
    } else {
      metaUpdates['unreadByAdmin'] = true;
      metaUpdates['unreadByUser'] = false;
      metaUpdates['unreadByRider'] = false;
    }
    await metaRef.update(metaUpdates);

    if (widget.isRiderMode) {
      final customerId = await _resolveCustomerUserId();
      if (customerId.isNotEmpty) {
        unawaited(
          NotificationService.sendToSpecificUser(
            target: customerId,
            title: 'Message from Rider',
            body: text,
            type: 'chat_message',
            source: 'rider_chat',
            data: {
              'type': 'rider_chat_message',
              'orderId': _chatOrderId,
              'orderType': (widget.orderType ?? '').toString().trim(),
              'orderCode': (widget.orderCode ?? '').toString().trim(),
              'senderRole': 'rider',
            },
          ).catchError((_) => <String, String>{}),
        );
      }
    } else if (widget.isRiderChat) {
      final riderId = await _resolveAssignedRiderId();
      if (riderId.isNotEmpty) {
        unawaited(
          NotificationService.sendToSpecificUser(
            target: riderId,
            title: 'Message from Customer',
            body: text,
            type: 'chat_message',
            source: 'rider_chat',
            data: {
              'type': 'rider_chat_message',
              'orderId': _chatOrderId,
              'orderType': (widget.orderType ?? '').toString().trim(),
              'orderCode': (widget.orderCode ?? '').toString().trim(),
              'senderRole': 'user',
              'userId': user.uid,
              'userName':
                  _userName.isNotEmpty ? _userName : user.displayName ?? 'User',
            },
          ).catchError((_) => <String, String>{}),
        );
      }
    } else {
      // Send push notification to Admin
      unawaited(
        NotificationService.sendNotificationToRole(
          role: 'admin',
          title:
              'New Message from ${_userName.isNotEmpty ? _userName : user.displayName ?? 'User'}',
          body: text,
          city: CityScopeService.currentCity,
          data: {
            'type': 'chat_message',
            'senderRole': 'user',
            'userId': user.uid,
            'userName':
                _userName.isNotEmpty ? _userName : user.displayName ?? 'User',
            'userPhone': _userPhone,
            'orderId': _chatOrderId,
            'orderType': (widget.orderType ?? '').toString().trim(),
            'orderCode': (widget.orderCode ?? '').toString().trim(),
          },
        ).catchError((_) => <String, dynamic>{}),
      );

      // Push a notification entry for the admin so they get notified in real-time
      try {
        await _db.child(_tenantPath('notifications/admin/inbox')).push().set({
          'title': 'New Message',
          'body':
              'From ${_userName.isNotEmpty ? _userName : user.displayName ?? 'User'}: $text',
          'type': 'chat_message',
          'userId': user.uid,
          'userName':
              _userName.isNotEmpty ? _userName : user.displayName ?? 'User',
          'userPhone': _userPhone,
          'orderId': _chatOrderId,
          'orderType': (widget.orderType ?? '').toString().trim(),
          'orderCode': (widget.orderCode ?? '').toString().trim(),
          'createdAt': ServerValue.timestamp,
          'read': false,
        });
      } catch (_) {}
    }

    _scrollToBottom();
  }

  Future<String> _resolveAssignedRiderId() async {
    final orderType = (widget.orderType ?? 'shop').toString().trim();
    final path = orderType == 'custom' ? 'custom-orders' : 'shop-orders';
    try {
      final snap = await _db.child(_tenantPath('$path/$_chatOrderId')).get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        return (data['assignedRider'] ?? '').toString().trim();
      }
    } catch (_) {}
    return '';
  }

  Future<String> _resolveCustomerUserId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final metaSnap =
            await _db.child(_chatPathForUser(user.uid, 'meta')).get();
        if (metaSnap.exists && metaSnap.value is Map) {
          final data = Map<String, dynamic>.from(metaSnap.value as Map);
          final fromMeta = (data['userId'] ?? '').toString().trim();
          if (fromMeta.isNotEmpty) return fromMeta;
        }
      } catch (_) {}
    }

    final orderType = (widget.orderType ?? 'shop').toString().trim();
    final path = orderType == 'custom' ? 'custom-orders' : 'shop-orders';
    try {
      final snap = await _db.child(_tenantPath('$path/$_chatOrderId')).get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        return (data['userId'] ?? data['uid'] ?? '').toString().trim();
      }
    } catch (_) {}
    return '';
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    final senderRole = (msg['senderRole'] ?? '').toString();
    final isMe = widget.isRiderMode ? (senderRole == 'rider') : (senderRole == 'user');
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    
    // Parse time
    String timeStr = '';
    final ts = msg['createdAtClient'] ?? msg['createdAt'] ?? msg['timestamp'];
    if (ts != null) {
      int? ms;
      if (ts is int) {
        ms = ts;
      } else if (ts is num) {
        ms = ts.toInt();
      }
      if (ms != null && ms > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ms);
        timeStr =
            "${dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour)}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}";
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: isMe 
                ? const LinearGradient(
                    colors: [Color(0xFFFF6B00), Color(0xFFFF8A65)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
              color: isMe ? null : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: isMe ? const Radius.circular(20) : const Radius.circular(4),
                bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: isMe 
                    ? const Color(0xFFFF6B00).withValues(alpha: 0.25)
                    : Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  (msg['text'] ?? '').toString(),
                  style: TextStyle(
                    color: isMe ? Colors.white : const Color(0xFF1F2937),
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
                          color: isMe ? Colors.white.withValues(alpha: 0.8) : const Color(0xFF9CA3AF),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isMe) ...[
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

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.zero,
                bottomRight: Radius.circular(16),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DotAnimation(delay: 0),
                SizedBox(width: 4),
                _DotAnimation(delay: 200),
                SizedBox(width: 4),
                _DotAnimation(delay: 400),
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
      backgroundColor: const Color(0xFFE5DDD5), // WhatsApp chat background color
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54), // WhatsApp primary color
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white24,
              child: Icon(Icons.support_agent_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isRiderChat 
                        ? (widget.riderName?.isNotEmpty == true ? widget.riderName! : 'Rider')
                        : 'GharTek Support', 
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)
                  ),
                  if (_adminTyping)
                    const Text('typing...', style: TextStyle(fontSize: 12, color: Colors.white70))
                  else if (_adminOnline)
                    const Text('Online', style: TextStyle(fontSize: 12, color: Colors.white70))
                  else
                    const Text('Offline', style: TextStyle(fontSize: 12, color: Colors.white70)),
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
                            const SizedBox(height: 20),
                            ElevatedButton.icon(
                              onPressed: _startConversation,
                              icon: const Icon(Icons.play_arrow_rounded, size: 20),
                              label: const Text('Start Conversation'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF25D366),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                              ),
                            )
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length + (_adminTyping ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i < _messages.length) {
                            return _buildMessageBubble(_messages[i]);
                          } else {
                            return _buildTypingIndicator();
                          }
                        },
                      ),
          ),
          if (_messages.isNotEmpty)
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
                        onChanged: _onTextChanged,
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

class _DotAnimation extends StatefulWidget {
  final int delay;
  const _DotAnimation({required this.delay});

  @override
  State<_DotAnimation> createState() => _DotAnimationState();
}

class _DotAnimationState extends State<_DotAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _animation = Tween<double>(begin: 0.0, end: -5.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) {
        _controller.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _animation.value),
          child: Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Colors.black38,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}
