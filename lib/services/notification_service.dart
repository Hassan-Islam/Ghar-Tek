import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:googleapis_auth/auth_io.dart' as google_auth;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'city_scope_service.dart';
import 'local_notification_store.dart';
import '../pages/user_chat_page.dart';
import '../pages/admin_chats_page.dart';
import '../pages/rider_orders_page.dart';
import 'rider_notification_service.dart';


class UserInboxNotification {
  final String id;
  final String title;
  final String body;
  final DateTime dateTime;
  final bool read;
  final Map<String, dynamic> data;

  const UserInboxNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.dateTime,
    required this.read,
    required this.data,
  });
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {}

  final title =
      (message.notification?.title ?? message.data['title'] ?? 'GharTek')
          .toString()
          .trim();
  final body =
      (message.notification?.body ?? message.data['body'] ?? '').toString().trim();
  if (title.isEmpty && body.isEmpty) return;

  final type = message.data['type']?.toString();
  if (type == 'rider_new_order') {
    final orderId = message.data['orderId']?.toString() ?? '';
    final orderType = message.data['orderType']?.toString() ?? 'shop';
    await RiderNotificationService.showIncomingOrderCall(
      title: title.isEmpty ? 'New Rider Order' : title,
      body: body,
      orderId: orderId,
      orderType: orderType,
    );
    return;
  }

  await LocalNotificationStore.addNotification(
    title: title.isEmpty ? 'GharTek' : title,
    body: body.isEmpty ? 'You have a new update.' : body,
    data: message.data.isNotEmpty ? Map<String, dynamic>.from(message.data) : null,
    dedupeKey: message.messageId,
  );
}

@pragma('vm:entry-point')
void onDidReceiveBackgroundNotificationResponse(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {}

  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;

  try {
    final data = Map<String, dynamic>.from(jsonDecode(payload));
    if (response.actionId != null) {
      data['actionId'] = response.actionId;
    }
    
    // In background, we only process backend updates if necessary
    // because `showsUserInterface: true` will also invoke foreground handler when the app wakes.
    final actionId = data['actionId']?.toString();
    final orderId = data['orderId']?.toString();
    final type = data['type']?.toString();
    final orderType = data['orderType']?.toString() ?? 'shop';

    if (type == 'rider_new_order' && actionId == 'accept_order' && orderId != null) {
       // Best-effort background accept if CityScopeService has cached city
       await CityScopeService.ensureLoaded();
       final city = CityScopeService.currentCity;
       if (city.isNotEmpty) {
           final db = FirebaseDatabase.instance.ref();
           final uid = FirebaseAuth.instance.currentUser?.uid;
           final cityPath = CityScopeService.tenantPath('');
           final typeStr = orderType == 'custom' ? 'custom-orders' : 'shop-orders';
           if (uid != null) {
              await db.child('$cityPath/$typeStr/$orderId').update({
                 'status': 'on_way',
                 'riderId': uid,
                 'riderName': FirebaseAuth.instance.currentUser?.displayName ?? 'Rider',
              });
           }
       }
    }
  } catch (_) {}
}

class NotificationService {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  bool _initialized = false;
  bool _foregroundHandlersBound = false;
  bool _authWatcherBound = false;

  String _boundCity = '';
  String _boundUserId = '';
  String _boundRole = 'guest';
  String _boundRealtimeScopeKey = '';
  String? _lastKnownToken;
  final Set<String> _subscribedTopics = <String>{};
  final Set<String> _seenRealtimeNotificationKeys = <String>{};
  final LinkedHashSet<String> _shownRealtimeMarkers = LinkedHashSet<String>();
  final LinkedHashSet<String> _shownRealtimeSignatures = LinkedHashSet<String>();
  final List<StreamSubscription<DatabaseEvent>> _realtimeNotificationSubs =
      <StreamSubscription<DatabaseEvent>>[];
  bool _shownRealtimeMarkersLoaded = false;
  bool _shownRealtimeSignaturesLoaded = false;
  // In-memory set of recently shown notification signatures to prevent duplicate display in the foreground.
  final Map<String, DateTime> _recentlyShownForegroundNotifications = {};

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'ghartek_main',
    'GharTek Notifications',
    description: 'Order updates and announcements',
    importance: Importance.high,
  );

  static const int _rtdbRecentWindowMs = 15 * 60 * 1000;
  static const int _maxPersistedRealtimeMarkers = 1500;
    static const int _maxPersistedRealtimeSignatures = 2000;
  static const String _seenRealtimeMarkersPref =
      'seen_rtdb_notification_markers_v1';
    static const String _seenRealtimeSignaturesPref =
      'seen_rtdb_notification_signatures_v1';
  static const int _fcmLegacyBatchSize = 500;
  static const String _fcmLegacyEndpoint =
      'https://fcm.googleapis.com/fcm/send';
    static const String _fcmHttpV1Scope =
      'https://www.googleapis.com/auth/firebase.messaging';
  static const String _manualFcmKeyPref = 'manual_fcm_server_key';

  Future<void> initialize() async {
    await CityScopeService.ensureLoaded();
    final currentCity = CityScopeService.currentCity;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    if (!_initialized) {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      await _plugin.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
        onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: onDidReceiveBackgroundNotificationResponse,
      );

      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);

      if (!kIsWeb) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }




      _initialized = true;
    }

    await _requestFcmPermissions();
    _bindForegroundMessageHandlers();
    _bindAuthStateWatcher();
    await _loadPersistedRealtimeMarkers();
    await _loadPersistedRealtimeSignatures();

    final shouldForceTokenUpsert =
        _boundCity != currentCity || _boundUserId != currentUid;

    await _syncTokenAndTopics(
      city: currentCity,
      userId: currentUid,
      forceTokenUpsert: shouldForceTokenUpsert,
    );
  }

  Future<void> _requestFcmPermissions() async {
    try {
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        announcement: false,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
      );
    } catch (_) {}

    try {
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {}
  }

  void _bindForegroundMessageHandlers() {
    if (_foregroundHandlersBound) return;

    _foregroundHandlersBound = true;

    FirebaseMessaging.onMessage.listen((message) {
      unawaited(_showFromRemoteMessage(message));
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      handleNotificationClick(Map<String, dynamic>.from(message.data));
    });

    _messaging.onTokenRefresh.listen((_) {
      unawaited(refreshScopeBindings());
    });

    unawaited(_messaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        handleNotificationClick(Map<String, dynamic>.from(message.data));
      }
    }));
  }

  static void _onDidReceiveNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final data = Map<String, dynamic>.from(jsonDecode(payload));
      if (response.actionId != null) {
        data['actionId'] = response.actionId;
      }
      handleNotificationClick(data);
    } catch (_) {}
  }

  static void handleNotificationClick(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    if (type == 'chat_message') {
      final context = navigatorKey.currentContext;
      if (context == null) return;

      final userId = data['userId']?.toString() ?? '';
      final userName = data['userName']?.toString() ?? 'User';
      final userPhone = data['userPhone']?.toString() ?? '';
      final orderId = data['orderId']?.toString() ?? 'general';
      final orderType = data['orderType']?.toString() ?? '';
      final orderCode = data['orderCode']?.toString() ?? '';

      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      if (currentUser.uid == userId) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserChatPage(
              orderId: orderId,
              orderType: orderType,
              orderCode: orderCode,
            ),
          ),
        );
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AdminChatDetailPage(
              userId: userId,
              userName: userName,
              userPhone: userPhone,
              orderId: orderId,
              orderType: orderType,
              orderCode: orderCode,
            ),
          ),
        );
      }
    } else if (type == 'rider_new_order') {
       final context = navigatorKey.currentContext;
       if (context == null) return;
       
       final actionId = data['actionId']?.toString();
       final orderId = data['orderId']?.toString();
       final orderType = data['orderType']?.toString() ?? 'shop';

       if (actionId == 'accept_order' && orderId != null) {
           final db = FirebaseDatabase.instance.ref();
           final uid = FirebaseAuth.instance.currentUser?.uid;
           final cityPath = CityScopeService.tenantPath('');
           final typeStr = orderType == 'custom' ? 'custom-orders' : 'shop-orders';
           if (uid != null) {
              db.child('$cityPath/$typeStr/$orderId').update({
                 'status': 'on_way',
                 'riderId': uid,
                 'riderName': FirebaseAuth.instance.currentUser?.displayName ?? 'Rider',
              });
           }
       }

       Navigator.push(
         context,
         MaterialPageRoute(builder: (_) => const RiderOrdersPage()),
       );
    }
  }

  void _bindAuthStateWatcher() {
    if (_authWatcherBound) return;

    _authWatcherBound = true;
    FirebaseAuth.instance.authStateChanges().listen((_) {
      unawaited(refreshScopeBindings());
    });
  }

  Future<void> _syncTokenAndTopics({
    required String city,
    required String userId,
    required bool forceTokenUpsert,
  }) async {
    final previousUserId = _boundUserId;
    final previousToken = _lastKnownToken;

    final role = await _resolveCurrentRole(userId);
    await _syncTopicSubscriptions(city: city, role: role, userId: userId);

    if (previousUserId.isNotEmpty &&
        previousUserId != userId &&
        previousToken != null &&
        previousToken.isNotEmpty) {
      await _removeTokenForUser(previousUserId, previousToken);
    }

    String? token;
    try {
      token = await _messaging.getToken();
    } catch (_) {
      token = null;
    }

    if (token != null && token.isNotEmpty) {
      final shouldUpsert =
          forceTokenUpsert ||
          previousToken != token ||
          _boundRole != role ||
          _boundCity != city;

      _lastKnownToken = token;

      if (userId.isNotEmpty && shouldUpsert) {
        await _upsertTokenForUser(
          userId: userId,
          token: token,
          city: city,
          role: role,
        );
      }
    }

    _boundCity = city;
    _boundUserId = userId;
    _boundRole = role;

    await _bindRealtimeNotificationListeners(
      city: city,
      userId: userId,
      role: role,
    );
  }

  String _tenantPath(String path, {String? city}) {
    return CityScopeService.tenantPath(path, city: city);
  }

  Future<void> _bindRealtimeNotificationListeners({
    required String city,
    required String userId,
    required String role,
  }) async {
    final normalizedCity = CityScopeService.normalizeCity(city);
    final normalizedRole = role.toLowerCase().trim();
    final scopeKey = '$normalizedCity|$userId|$normalizedRole';

    if (_boundRealtimeScopeKey == scopeKey &&
        _realtimeNotificationSubs.isNotEmpty) {
      return;
    }

    await _disposeRealtimeNotificationListeners();
    _boundRealtimeScopeKey = scopeKey;

    if (userId.isEmpty) return;

    final bindings = <Map<String, String>>[
      {
        'channel': 'user',
        'path': _tenantPath('notifications/user/$userId', city: normalizedCity),
      },
      {
        'channel': 'broadcast',
        'path': _tenantPath('notifications/broadcast', city: normalizedCity),
      },
    ];

    if (normalizedRole == 'admin') {
      bindings.addAll([
        {
          'channel': 'admin',
          'path': _tenantPath('notifications/admin/inbox', city: normalizedCity),
        },
      ]);
    }

    if (normalizedRole == 'rider') {
      bindings.addAll([
        {
          'channel': 'rider',
          'path': _tenantPath('notifications/rider/inbox', city: normalizedCity),
        },
      ]);
    }

    if (normalizedRole == 'merchant') {
      bindings.addAll([
        {
          'channel': 'merchant',
          'path':
              _tenantPath('notifications/merchant/$userId', city: normalizedCity),
        },
      ]);
    }

    final listenerBoundAt = DateTime.now().millisecondsSinceEpoch;

    for (final binding in bindings) {
      final path = binding['path'] ?? '';
      final channel = binding['channel'] ?? 'general';
      if (path.isEmpty) continue;
      await _bindRealtimePath(
        path: path,
        channel: channel,
        listenerBoundAt: listenerBoundAt,
      );
    }
  }

  Future<void> _disposeRealtimeNotificationListeners() async {
    for (final sub in _realtimeNotificationSubs) {
      await sub.cancel();
    }
    _realtimeNotificationSubs.clear();
    _seenRealtimeNotificationKeys.clear();
    _boundRealtimeScopeKey = '';
  }

  Future<void> _loadPersistedRealtimeMarkers() async {
    if (_shownRealtimeMarkersLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_seenRealtimeMarkersPref) ??
          const <String>[];

      for (final marker in stored) {
        if (marker.trim().isEmpty) continue;
        _shownRealtimeMarkers.add(marker);
      }
    } catch (_) {}

    _shownRealtimeMarkersLoaded = true;
  }

  Future<void> _loadPersistedRealtimeSignatures() async {
    if (_shownRealtimeSignaturesLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_seenRealtimeSignaturesPref) ??
          const <String>[];

      for (final signature in stored) {
        if (signature.trim().isEmpty) continue;
        _shownRealtimeSignatures.add(signature);
      }
    } catch (_) {}

    _shownRealtimeSignaturesLoaded = true;
  }

  Future<void> _rememberRealtimeMarker(String marker) async {
    if (marker.trim().isEmpty) return;
    await _loadPersistedRealtimeMarkers();

    if (_shownRealtimeMarkers.contains(marker)) return;
    _shownRealtimeMarkers.add(marker);

    while (_shownRealtimeMarkers.length > _maxPersistedRealtimeMarkers) {
      _shownRealtimeMarkers.remove(_shownRealtimeMarkers.first);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _seenRealtimeMarkersPref,
        _shownRealtimeMarkers.toList(growable: false),
      );
    } catch (_) {}
  }

  Future<void> _rememberRealtimeSignature(String signature) async {
    if (signature.trim().isEmpty) return;
    await _loadPersistedRealtimeSignatures();

    if (_shownRealtimeSignatures.contains(signature)) return;
    _shownRealtimeSignatures.add(signature);

    while (_shownRealtimeSignatures.length > _maxPersistedRealtimeSignatures) {
      _shownRealtimeSignatures.remove(_shownRealtimeSignatures.first);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _seenRealtimeSignaturesPref,
        _shownRealtimeSignatures.toList(growable: false),
      );
    } catch (_) {}
  }

  String _firstNonEmptyText(Iterable<dynamic> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _normalizeSignaturePart(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _buildRealtimeSignature({
    required String channel,
    required Map<String, dynamic> data,
    required String marker,
    required String title,
    required String body,
  }) {
    Map<String, dynamic>? details;
    if (data['details'] is Map) {
      details = Map<String, dynamic>.from(data['details'] as Map);
    }

    final orderIdentity = _firstNonEmptyText([
      details?['orderId'],
      details?['orderCode'],
      details?['customOrderId'],
      details?['id'],
      data['orderId'],
      data['orderCode'],
      data['customOrderId'],
      data['id'],
    ]);

    final normalizedTitle = _normalizeSignaturePart(title);
    final normalizedBody = _normalizeSignaturePart(body);

    if (orderIdentity.isNotEmpty) {
      return 'order|${channel.toLowerCase()}|${orderIdentity.toLowerCase()}|$normalizedTitle|$normalizedBody';
    }

    return 'generic|${channel.toLowerCase()}|$normalizedTitle|$normalizedBody|$marker';
  }

  Future<void> _bindRealtimePath({
    required String path,
    required String channel,
    required int listenerBoundAt,
  }) async {
    final query = FirebaseDatabase.instance.ref(path).limitToLast(250);

    final sub = query.onChildAdded.listen((event) {
      final key = event.snapshot.key ?? '';
      if (key.isEmpty) return;

      final marker = '$path::$key';
      if (_seenRealtimeNotificationKeys.contains(marker)) return;
      _seenRealtimeNotificationKeys.add(marker);

      unawaited(
        _showFromRealtimeSnapshot(
          channel: channel,
          path: path,
          key: key,
          snapshotValue: event.snapshot.value,
          listenerBoundAt: listenerBoundAt,
        ),
      );
    });

    _realtimeNotificationSubs.add(sub);
  }

  Future<void> _showFromRealtimeSnapshot({
    required String channel,
    required String path,
    required String key,
    required dynamic snapshotValue,
    required int listenerBoundAt,
  }) async {
    if (snapshotValue is! Map) return;

    final marker = '$path::$key';
    await _loadPersistedRealtimeMarkers();
    if (_shownRealtimeMarkers.contains(marker)) return;

    final data = Map<String, dynamic>.from(snapshotValue);
    if (data['read'] == true) return;

    final createdAt = _extractEpochMs(data);
    if (createdAt != null && createdAt < (listenerBoundAt - _rtdbRecentWindowMs)) {
      return;
    }

    final delivery = (data['delivery'] ?? '').toString().toLowerCase();
    final skipTray = delivery.contains('fcm');

    final title = (data['title'] ?? _defaultTitleForChannel(channel))
        .toString()
        .trim();
    String body = (data['body'] ?? '').toString().trim();

    if (body.isEmpty && data['details'] is Map) {
      final details = Map<String, dynamic>.from(data['details'] as Map);
      final orderCode = (details['orderCode'] ?? details['orderId'] ?? '')
          .toString()
          .trim();
      final status = (details['status'] ?? '').toString().trim();
      if (orderCode.isNotEmpty && status.isNotEmpty) {
        body = 'Order $orderCode is now ${status.replaceAll('_', ' ')}.';
      } else if (orderCode.isNotEmpty) {
        body = 'Order $orderCode has a new update.';
      }
    }

    if (body.isEmpty) {
      body = _defaultBodyForChannel(channel);
    }

    await _loadPersistedRealtimeSignatures();
    final signature = _buildRealtimeSignature(
      channel: channel,
      data: data,
      marker: marker,
      title: title.isEmpty ? 'GharTek' : title,
      body: body,
    );

    final storeData = <String, dynamic>{
      'type': data['type']?.toString() ?? 'rtdb_$channel',
      'channel': channel,
      'source': 'rtdb',
    };
    if (data['orderId'] != null) storeData['orderId'] = data['orderId'].toString();
    if (data['orderCode'] != null) {
      storeData['orderCode'] = data['orderCode'].toString();
    }

    final resolvedTitle = title.isEmpty ? 'GharTek' : title;
    final resolvedDate = createdAt != null
        ? DateTime.fromMillisecondsSinceEpoch(createdAt)
        : DateTime.now();

    await LocalNotificationStore.addNotification(
      title: resolvedTitle,
      body: body,
      data: storeData,
      dedupeKey: marker,
      dateTime: resolvedDate,
    );

    if (skipTray || _shownRealtimeSignatures.contains(signature)) {
      await _rememberRealtimeMarker(marker);
      if (!_shownRealtimeSignatures.contains(signature)) {
        await _rememberRealtimeSignature(signature);
      }
      return;
    }

    final type = data['type']?.toString();
    String? payload;
    if (type == 'admin_message' || type == 'chat_message') {
      final chatData = {
        'type': 'chat_message',
        'userId': data['userId'] ?? data['targetUserId'] ?? (channel == 'user' ? _boundUserId : ''),
        'userName': data['userName'] ?? 'Customer',
        'userPhone': data['userPhone'] ?? '',
        'orderId': data['orderId'] ?? 'general',
        'orderType': data['orderType'] ?? '',
        'orderCode': data['orderCode'] ?? '',
      };
      payload = jsonEncode(chatData);
    } else {
      payload = 'rtdb_$channel';
    }

    final notificationId = '$path::$key'.hashCode & 0x7fffffff;
    await showNotification(
      id: notificationId,
      title: resolvedTitle,
      body: body,
      payload: payload,
      dedupeKey: marker,
      saveLocally: false,
    );

    await _rememberRealtimeMarker(marker);
    await _rememberRealtimeSignature(signature);
  }

  int? _extractEpochMs(Map<String, dynamic> data) {
    final candidates = <dynamic>[
      data['createdAt'],
      data['createdAtClient'],
      data['timestamp'],
      data['updatedAt'],
    ];
    for (final value in candidates) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse((value ?? '').toString());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  String _defaultTitleForChannel(String channel) {
    switch (channel) {
      case 'admin':
        return 'New Admin Alert';
      case 'merchant':
        return 'Merchant Update';
      case 'rider':
        return 'Rider Alert';
      case 'broadcast':
        return 'Announcement';
      case 'user':
      default:
        return 'Order Update';
    }
  }

  String _defaultBodyForChannel(String channel) {
    switch (channel) {
      case 'admin':
        return 'A new order requires your attention.';
      case 'merchant':
        return 'A merchant notification has arrived.';
      case 'rider':
        return 'A rider task is available.';
      case 'broadcast':
        return 'A new announcement is available.';
      case 'user':
      default:
        return 'You have a new order update.';
    }
  }

  Future<void> _syncTopicSubscriptions({
    required String city,
    required String role,
    required String userId,
  }) async {
    final normalizedCity = CityScopeService.normalizeCity(city);
    final normalizedRole = role.toLowerCase();

    final targetTopics = <String>{_cityTopic(normalizedCity)};
    if (normalizedRole.isNotEmpty && normalizedRole != 'guest') {
      targetTopics.add(_roleTopic(normalizedRole, normalizedCity));
    }
    if (userId.trim().isNotEmpty) {
      targetTopics.add('user_$userId');
    }

    final removeTopics = _subscribedTopics.difference(targetTopics).toList();
    for (final topic in removeTopics) {
      try {
        await _messaging.unsubscribeFromTopic(topic);
      } catch (_) {}
    }

    final addTopics = targetTopics.difference(_subscribedTopics).toList();
    for (final topic in addTopics) {
      try {
        await _messaging.subscribeToTopic(topic);
      } catch (_) {}
    }

    _subscribedTopics
      ..clear()
      ..addAll(targetTopics);
  }

  String _cityTopic(String city) =>
      'city_${CityScopeService.normalizeCity(city)}';

  String _roleTopic(String role, String city) =>
      'role_${role.toLowerCase()}_${CityScopeService.normalizeCity(city)}';

  String _tokenDbKey(String token) {
    return token
        .replaceAll('.', '_')
        .replaceAll('#', '_')
        .replaceAll(r'$', '_')
        .replaceAll('[', '_')
        .replaceAll(']', '_')
        .replaceAll('/', '_');
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  Future<void> _upsertTokenForUser({
    required String userId,
    required String token,
    required String city,
    required String role,
  }) async {
    final tokenKey = _tokenDbKey(token);
    final normalizedCity = CityScopeService.normalizeCity(city);
    final normalizedRole = role.toLowerCase().trim();

    await FirebaseDatabase.instance
        .ref('users/$userId/fcmTokens/$tokenKey')
        .set({
          'token': token,
          'city': normalizedCity,
          'role': normalizedRole,
          'platform': _platformLabel(),
          'updatedAt': ServerValue.timestamp,
        });

    if (normalizedRole == 'admin' || normalizedRole == 'rider') {
      final pathSegment = normalizedRole == 'admin' ? 'activeAdminTokens' : 'activeRiderTokens';
      final targetCities = <String>{normalizedCity};
      for (final sc in CityScopeService.supportedCities) {
        targetCities.add(CityScopeService.normalizeCity(sc));
      }

      for (final targetCity in targetCities) {
        final tenantPath = CityScopeService.tenantPath(
          'settings/app-control/$pathSegment/$userId/$tokenKey',
          city: targetCity,
        );
        try {
          await FirebaseDatabase.instance
              .ref(tenantPath)
              .set({
                'token': token,
                'city': normalizedCity,
                'role': normalizedRole,
                'platform': _platformLabel(),
                'updatedAt': ServerValue.timestamp,
              });
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Failed to mirror token for $normalizedRole in $targetCity: $e');
          }
        }
      }
    }
  }

  Future<void> _removeTokenForUser(String userId, String token) async {
    final tokenKey = _tokenDbKey(token);
    await FirebaseDatabase.instance
        .ref('users/$userId/fcmTokens/$tokenKey')
        .remove();

    final targetCities = <String>{};
    for (final sc in CityScopeService.supportedCities) {
      targetCities.add(CityScopeService.normalizeCity(sc));
    }

    for (final targetCity in targetCities) {
      for (final roleSegment in ['activeAdminTokens', 'activeRiderTokens']) {
        final tenantPath = CityScopeService.tenantPath(
          'settings/app-control/$roleSegment/$userId/$tokenKey',
          city: targetCity,
        );
        try {
          await FirebaseDatabase.instance.ref(tenantPath).remove();
        } catch (_) {}
      }
    }
  }

  Future<String> _resolveCurrentRole(String userId) async {
    if (userId.isEmpty) return 'guest';
    try {
      final snap = await FirebaseDatabase.instance
          .ref('users/$userId/role')
          .get();
      if (!snap.exists) return 'customer';
      return (snap.value ?? 'customer').toString().toLowerCase();
    } catch (_) {
      return 'customer';
    }
  }

  Future<void> _showFromRemoteMessage(RemoteMessage message) async {
    final title =
        (message.notification?.title ?? message.data['title'] ?? 'GharTek')
            .toString();
    final body = (message.notification?.body ?? message.data['body'] ?? '')
        .toString();

    if (title.trim().isEmpty && body.trim().isEmpty) return;

    final type = message.data['type']?.toString();

    if (type == 'rider_new_order') {
      final orderId = message.data['orderId']?.toString() ?? '';
      final orderType = message.data['orderType']?.toString() ?? 'shop';
      await RiderNotificationService.showIncomingOrderCall(
        title: title.isEmpty ? 'New Rider Order' : title,
        body: body,
        orderId: orderId,
        orderType: orderType,
      );
      return;
    }

    String? payload;
    if (type == 'chat_message') {
      payload = jsonEncode(message.data);
    } else {
      final p = (message.data['type'] ?? message.data['payload'] ?? '')
          .toString()
          .trim();
      payload = p.isEmpty ? null : p;
    }

    final idSeed =
        (message.messageId ??
                message.data['notificationId'] ??
                DateTime.now().millisecondsSinceEpoch.toString())
            .toString();

    await showNotification(
      id: idSeed.hashCode,
      title: title,
      body: body,
      payload: payload,
      dedupeKey: idSeed,
    );
  }

  static Future<void> syncRtdbInboxToLocalStore() async {
    try {
      await CityScopeService.ensureLoaded();
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return;

      final city = CityScopeService.currentCity;
      final role = await NotificationService()._resolveCurrentRole(uid);
      final paths = <String>[
        CityScopeService.tenantPath('notifications/user/$uid', city: city),
        CityScopeService.tenantPath('notifications/broadcast', city: city),
      ];

      if (role == 'admin') {
        paths.add(
          CityScopeService.tenantPath('notifications/admin/inbox', city: city),
        );
      } else if (role == 'rider') {
        paths.add(
          CityScopeService.tenantPath('notifications/rider/inbox', city: city),
        );
      } else if (role == 'merchant') {
        paths.add(
          CityScopeService.tenantPath('notifications/merchant/$uid', city: city),
        );
      }

      for (final path in paths) {
        await _importRtdbNotificationPath(path);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('syncRtdbInboxToLocalStore failed: $e');
      }
    }
  }

  static Future<void> _importRtdbNotificationPath(String path) async {
    final snap = await FirebaseDatabase.instance.ref(path).limitToLast(50).get();
    if (!snap.exists || snap.value is! Map) return;

    final entries = Map<dynamic, dynamic>.from(snap.value as Map).entries.toList();
    entries.sort((a, b) {
      final aTime = _extractEpochMsFromDynamic(a.value);
      final bTime = _extractEpochMsFromDynamic(b.value);
      return bTime.compareTo(aTime);
    });

    for (final entry in entries) {
      if (entry.value is! Map) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      final key = entry.key.toString();
      final marker = '$path::$key';

      final title = (data['title'] ?? 'GharTek').toString().trim();
      var body = (data['body'] ?? '').toString().trim();
      if (body.isEmpty && data['details'] is Map) {
        final details = Map<String, dynamic>.from(data['details'] as Map);
        final orderCode = (details['orderCode'] ?? details['orderId'] ?? '')
            .toString()
            .trim();
        final status = (details['status'] ?? '').toString().trim();
        if (orderCode.isNotEmpty && status.isNotEmpty) {
          body = 'Order $orderCode is now ${status.replaceAll('_', ' ')}.';
        } else if (orderCode.isNotEmpty) {
          body = 'Order $orderCode has a new update.';
        }
      }
      if (body.isEmpty) {
        body = 'You have a new update.';
      }

      final createdAt = _extractEpochMsFromDynamic(data);
      await LocalNotificationStore.addNotification(
        title: title.isEmpty ? 'GharTek' : title,
        body: body,
        data: {
          'type': data['type']?.toString() ?? 'rtdb',
          'source': 'rtdb_sync',
          if (data['orderId'] != null) 'orderId': data['orderId'].toString(),
          if (data['orderCode'] != null) 'orderCode': data['orderCode'].toString(),
        },
        dedupeKey: marker,
        dateTime: createdAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(createdAt)
            : DateTime.now(),
      );
    }
  }

  static String userInboxPath(String uid, {String? city}) {
    return CityScopeService.tenantPath('notifications/user/$uid', city: city);
  }

  static int countUnreadUserNotifications(dynamic raw) {
    if (raw is! Map) return 0;
    var count = 0;
    for (final entry in raw.entries) {
      if (entry.value is! Map) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      if (data['read'] != true) count++;
    }
    return count;
  }

  static Stream<int> watchUnreadUserNotificationCount() async* {
    await CityScopeService.ensureLoaded();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      yield 0;
      return;
    }

    yield* FirebaseDatabase.instance
        .ref(userInboxPath(uid))
        .onValue
        .map((event) => countUnreadUserNotifications(event.snapshot.value));
  }

  static Future<List<UserInboxNotification>> fetchUserInboxNotifications() async {
    await CityScopeService.ensureLoaded();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return const [];

    final snap = await FirebaseDatabase.instance
        .ref(userInboxPath(uid))
        .limitToLast(50)
        .get();
    if (!snap.exists || snap.value is! Map) return const [];

    final items = <UserInboxNotification>[];
    for (final entry in Map<dynamic, dynamic>.from(snap.value as Map).entries) {
      if (entry.value is! Map) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      final createdAt = _extractEpochMsFromDynamic(data);
      var body = (data['body'] ?? '').toString().trim();
      if (body.isEmpty && data['details'] is Map) {
        final details = Map<String, dynamic>.from(data['details'] as Map);
        final orderCode = (details['orderCode'] ?? details['orderId'] ?? '')
            .toString()
            .trim();
        final status = (details['status'] ?? '').toString().trim();
        if (orderCode.isNotEmpty && status.isNotEmpty) {
          body = 'Order $orderCode is now ${status.replaceAll('_', ' ')}.';
        } else if (orderCode.isNotEmpty) {
          body = 'Order $orderCode has a new update.';
        }
      }
      if (body.isEmpty) body = 'You have a new update.';

      items.add(
        UserInboxNotification(
          id: entry.key.toString(),
          title: (data['title'] ?? 'GharTek').toString().trim(),
          body: body,
          dateTime: createdAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(createdAt)
              : DateTime.now(),
          read: data['read'] == true,
          data: data,
        ),
      );
    }

    items.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return items;
  }

  static Future<void> markAllUserInboxAsRead() async {
    await CityScopeService.ensureLoaded();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    final snap = await FirebaseDatabase.instance.ref(userInboxPath(uid)).get();
    if (!snap.exists || snap.value is! Map) return;

    final updates = <String, dynamic>{};
    for (final entry in Map<dynamic, dynamic>.from(snap.value as Map).entries) {
      if (entry.value is! Map) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);
      if (data['read'] == true) continue;
      updates['${entry.key}/read'] = true;
    }
    if (updates.isEmpty) return;

    await FirebaseDatabase.instance.ref(userInboxPath(uid)).update(updates);
  }

  static int _extractEpochMsFromDynamic(dynamic value) {
    if (value is! Map) return 0;
    final data = Map<String, dynamic>.from(value);
    final candidates = <dynamic>[
      data['createdAt'],
      data['createdAtClient'],
      data['timestamp'],
      data['updatedAt'],
    ];
    for (final candidate in candidates) {
      if (candidate is int) return candidate;
      if (candidate is num) return candidate.toInt();
      final parsed = int.tryParse((candidate ?? '').toString());
      if (parsed != null && parsed > 0) return parsed;
    }
    return 0;
  }

  Future<void> refreshScopeBindings() async {
    await initialize();
  }

  Future<bool> _areNotificationsEnabled() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return true;
      final snap = await FirebaseDatabase.instance
          .ref('users/${user.uid}/notificationsEnabled')
          .get();
      if (snap.exists && snap.value == false) return false;
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<void> showNotification({
    int id = 0,
    required String title,
    required String body,
    String? payload,
    String? dedupeKey,
    bool saveLocally = true,
  }) async {
    final String normalizedTitle = title.trim().toLowerCase();
    final String normalizedBody = body.trim().toLowerCase();
    final String duplicateCheckKey = '$normalizedTitle|$normalizedBody';

    final now = DateTime.now();
    if (_recentlyShownForegroundNotifications.containsKey(duplicateCheckKey)) {
      final lastShownTime = _recentlyShownForegroundNotifications[duplicateCheckKey]!;
      if (now.difference(lastShownTime).inSeconds < 5) {
        if (kDebugMode) {
          debugPrint('Suppressing duplicate foreground notification: $title - $body');
        }
        return;
      }
    }
    _recentlyShownForegroundNotifications[duplicateCheckKey] = now;

    // Clean up old entries in the map to prevent memory leak
    _recentlyShownForegroundNotifications.removeWhere((key, time) => now.difference(time).inSeconds > 30);

    // Parse payload to data Map if it is JSON
    Map<String, dynamic>? parsedData;
    if (payload != null && payload.trim().startsWith('{') && payload.trim().endsWith('}')) {
      try {
        parsedData = Map<String, dynamic>.from(jsonDecode(payload));
      } catch (_) {}
    } else if (payload != null && payload.trim().isNotEmpty) {
      parsedData = {'payload': payload};
    }

    if (saveLocally) {
      await LocalNotificationStore.addNotification(
        title: title,
        body: body,
        data: parsedData,
        dedupeKey: dedupeKey,
      );
    }

    if (!_initialized) await initialize();

    final enabled = await _areNotificationsEnabled();
    if (!enabled) return;

    int finalId = id;
    if (payload != null && payload.contains('order')) {
      finalId = 999;
    }

    await _plugin.show(
      finalId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFFFF6B00),
          tag: (payload != null && payload.contains('order'))
              ? 'order_alert'
              : null,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload,
    );
  }

  static List<List<String>> _chunkTokens(List<String> tokens, int size) {
    final chunks = <List<String>>[];
    for (var i = 0; i < tokens.length; i += size) {
      final end = (i + size < tokens.length) ? i + size : tokens.length;
      chunks.add(tokens.sublist(i, end));
    }
    return chunks;
  }

  static bool _looksLikeServiceAccountJson(String value) {
    final raw = value.trim();
    if (raw.isEmpty || !raw.startsWith('{')) return false;
    return raw.contains('"private_key"') &&
        raw.contains('"client_email"') &&
        raw.contains('"project_id"');
  }

  static bool _looksLikeLegacyServerKey(String value) {
    final raw = value.trim();
    if (raw.isEmpty || raw.startsWith('{')) return false;
    return raw.startsWith('AAAA') && raw.length > 20;
  }

  static List<String?> _extractFcmCredentialFields(Map<String, dynamic> data) {
    return <String?>[
      data['fcmServiceAccountJson']?.toString(),
      data['fcmHttpV1ServiceAccount']?.toString(),
      data['fcmServiceAccountKey']?.toString(),
      data['fcmServerKey']?.toString(),
      data['fcmLegacyServerKey']?.toString(),
      data['fcmPushServerKey']?.toString(),
    ];
  }

  static Future<List<String>> _collectManualFcmCredentialCandidates({
    required String city,
  }) async {
    final candidates = <String>[];
    final normalizedCity = CityScopeService.normalizeCity(city);
    final appControlPathVariants = <String>[
      'settings/app-control',
      'settings/appControl',
      'settings/app_control',
    ];

    void addCandidate(String? raw) {
      final value = (raw ?? '').trim();
      if (value.isNotEmpty) {
        candidates.add(value);
      }
    }

    Future<void> collectFromPath(String path) async {
      try {
        final snap = await FirebaseDatabase.instance.ref(path).get();
        if (snap.exists && snap.value is Map) {
          final data = Map<String, dynamic>.from(snap.value as Map);
          for (final value in _extractFcmCredentialFields(data)) {
            addCandidate(value);
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('FCM credential lookup failed at $path: $e');
        }
      }
    }

    final scopedCities = <String>[normalizedCity];
    for (final scopedCity in CityScopeService.supportedCities) {
      final fallbackCity = CityScopeService.normalizeCity(scopedCity);
      if (!scopedCities.contains(fallbackCity)) {
        scopedCities.add(fallbackCity);
      }
    }

    for (final scopedCity in scopedCities) {
      for (final path in appControlPathVariants) {
        await collectFromPath(CityScopeService.tenantPath(path, city: scopedCity));
      }
    }

    for (final path in appControlPathVariants) {
      await collectFromPath(path);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      addCandidate(prefs.getString(_manualFcmKeyPref));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FCM credential local cache lookup failed: $e');
      }
    }

    return candidates;
  }

  static Future<String?> _resolveManualFcmServiceAccountJson({
    required String city,
  }) async {
    final candidates = await _collectManualFcmCredentialCandidates(city: city);
    for (final candidate in candidates) {
      if (_looksLikeServiceAccountJson(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  static Future<String?> _resolveManualFcmServerKey({
    required String city,
  }) async {
    final candidates = await _collectManualFcmCredentialCandidates(city: city);
    for (final key in candidates) {
      if (_looksLikeLegacyServerKey(key)) {
        return key;
      }
    }
    return null;
  }

  static Future<Map<String, String>> _resolveHttpV1Auth({
    required String serviceAccountJson,
  }) async {
    late final Map<String, dynamic> serviceAccount;
    try {
      final decoded = jsonDecode(serviceAccountJson);
      if (decoded is! Map) {
        throw Exception('JSON root must be an object');
      }
      serviceAccount = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw Exception(
        'Invalid Service Account JSON. Paste full JSON file content from Firebase service account key.',
      );
    }

    final projectId = (serviceAccount['project_id'] ?? '').toString().trim();
    final clientEmail =
        (serviceAccount['client_email'] ?? '').toString().trim();
    final privateKey = (serviceAccount['private_key'] ?? '').toString().trim();

    if (projectId.isEmpty || clientEmail.isEmpty || privateKey.isEmpty) {
      throw Exception(
        'Service Account JSON missing required fields: project_id, client_email, private_key.',
      );
    }

    google_auth.AutoRefreshingAuthClient? authClient;
    try {
      final creds = google_auth.ServiceAccountCredentials.fromJson(
        serviceAccount,
      );
      authClient = await google_auth.clientViaServiceAccount(
        creds,
        <String>[_fcmHttpV1Scope],
      );
      final accessToken = authClient.credentials.accessToken.data.trim();
      if (accessToken.isEmpty) {
        throw Exception('Empty OAuth access token');
      }
      return {
        'projectId': projectId,
        'accessToken': accessToken,
      };
    } finally {
      authClient?.close();
    }
  }

  static Future<Map<String, dynamic>> _sendHttpV1FcmToTokens({
    required String serviceAccountJson,
    required List<String> tokens,
    required String title,
    required String body,
    required Map<String, String> data,
    String? channelId,
  }) async {
    if (tokens.isEmpty) {
      return {
        'successCount': 0,
        'failureCount': 0,
        'firstError': '',
      };
    }

    final auth = await _resolveHttpV1Auth(
      serviceAccountJson: serviceAccountJson,
    );
    final projectId = auth['projectId']!;
    final accessToken = auth['accessToken']!;
    final endpoint = Uri.parse(
      'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
    );

    var totalSuccess = 0;
    var totalFailure = 0;
    String firstError = '';

    final uniqueTokens = tokens.toSet().toList(growable: false);
    final requests = uniqueTokens.map((token) async {
      final messageData = Map<String, String>.from(data);
      if (channelId == 'rider_new_order') {
        messageData['title'] = title;
        messageData['body'] = body;
      }

      final payload = <String, dynamic>{
        'message': <String, dynamic>{
          'token': token,
          if (channelId != 'rider_new_order')
            'notification': <String, dynamic>{
              'title': title,
              'body': body,
            },
          'data': messageData,
          'android': <String, dynamic>{
            'priority': 'HIGH',
            'collapse_key': data['orderId'] != null ? 'order_${data['orderId']}' : 'general_alert',
            if (channelId != 'rider_new_order')
              'notification': <String, dynamic>{
                'channel_id': channelId ?? _channel.id,
                'sound': 'default',
              },
          },
          'apns': <String, dynamic>{
            'headers': <String, String>{
              'apns-priority': '10',
            },
            'payload': <String, dynamic>{
              'aps': <String, dynamic>{
                'sound': 'default',
                'badge': 1,
                'content-available': 1,
              },
            },
          },
        },
      };

      try {
        final response = await http.post(
          endpoint,
          headers: <String, String>{
            'Content-Type': 'application/json; charset=UTF-8',
            'Authorization': 'Bearer $accessToken',
          },
          body: jsonEncode(payload),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return {'success': true};
        } else {
          String message = 'HTTP ${response.statusCode}';
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map) {
              final err = decoded['error'];
              if (err is Map) {
                final serverMessage = (err['message'] ?? '').toString().trim();
                if (serverMessage.isNotEmpty) {
                  message = serverMessage;
                }
              }
            }
          } catch (_) {}
          return {'success': false, 'error': message};
        }
      } catch (e) {
        return {'success': false, 'error': e.toString()};
      }
    });

    final results = await Future.wait(requests);
    for (final res in results) {
      if (res['success'] == true) {
        totalSuccess++;
      } else {
        totalFailure++;
        if (firstError.isEmpty) {
          firstError = (res['error'] ?? '').toString();
        }
      }
    }

    return {
      'successCount': totalSuccess,
      'failureCount': totalFailure,
      'firstError': firstError,
    };
  }

  static List<String> _extractTokensFromUserData(
    Map<String, dynamic> userData, {
    String? cityFilter,
  }) {
    final cityNormalized = cityFilter == null || cityFilter.trim().isEmpty
        ? null
        : CityScopeService.normalizeCity(cityFilter);

    final role = (userData['role'] ?? 'customer').toString().toLowerCase();
    final fallbackCity = CityScopeService.normalizeCity(
      role == 'admin'
          ? (userData['adminCity'] ?? '').toString()
          : (userData['userCity'] ?? '').toString(),
    );

    final tokensNode = userData['fcmTokens'];
    if (tokensNode == null) return const <String>[];

    final tokens = <String>{};

    void parseTokenValue(dynamic value) {
      if (value == null) return;
      var token = '';
      var tokenCity = fallbackCity;

      if (value is String) {
        token = value.trim();
      } else if (value is Map) {
        final row = Map<String, dynamic>.from(value);
        token = (row['token'] ?? '').toString().trim();
        final rawCity = (row['city'] ?? '').toString().trim();
        if (rawCity.isNotEmpty) {
          tokenCity = CityScopeService.normalizeCity(rawCity);
        }
      }

      if (token.isEmpty) return;
      if (cityNormalized != null && tokenCity != cityNormalized) return;
      tokens.add(token);
    }

    if (tokensNode is Map) {
      final mapNode = Map<dynamic, dynamic>.from(tokensNode);
      for (final val in mapNode.values) {
        parseTokenValue(val);
      }
    } else if (tokensNode is List) {
      for (final val in tokensNode) {
        parseTokenValue(val);
      }
    } else {
      parseTokenValue(tokensNode);
    }

    return tokens.toList(growable: false);
  }



  static Future<List<String>> _collectTokensForCity(String city) async {
    final cityNormalized = CityScopeService.normalizeCity(city);
    final tokens = <String>{};

    try {
      final snap = await FirebaseDatabase.instance.ref('users').get();
      if (!snap.exists || snap.value is! Map) return const <String>[];

      final users = snap.value as Map<dynamic, dynamic>;
      for (final value in users.values) {
        if (value is! Map) continue;
        final userData = Map<String, dynamic>.from(value);
        final role = (userData['role'] ?? 'customer').toString().toLowerCase();
        final userCity = CityScopeService.normalizeCity(
          role == 'admin'
              ? (userData['adminCity'] ?? '').toString()
              : (userData['userCity'] ?? '').toString(),
        );
        if (userCity != cityNormalized) continue;

        // City is filtered by user profile scope above; token city metadata may
        // be missing/outdated on some devices, so collect all user tokens here.
        tokens.addAll(
          _extractTokensFromUserData(userData, cityFilter: cityNormalized),
        );
      }
    } catch (_) {}

    return tokens.toList(growable: false);
  }

  static Future<int> _backfillMissingUserCityFromTokens({
    required String targetCity,
  }) async {
    final cityNormalized = CityScopeService.normalizeCity(targetCity);
    int updatedCount = 0;

    try {
      final snap = await FirebaseDatabase.instance.ref('users').get();
      if (!snap.exists || snap.value is! Map) return 0;

      final updates = <String, dynamic>{};
      final users = snap.value as Map<dynamic, dynamic>;

      for (final entry in users.entries) {
        if (entry.value is! Map) continue;
        final userId = entry.key.toString();
        final userData = Map<String, dynamic>.from(entry.value as Map);
        final role = (userData['role'] ?? 'customer').toString().toLowerCase();
        final cityField = role == 'admin' ? 'adminCity' : 'userCity';
        final currentCity = (userData[cityField] ?? '').toString().trim();
        if (currentCity.isNotEmpty) continue;

        final tokensNode = userData['fcmTokens'];
        if (tokensNode is! Map) continue;

        final tokenCities = <String>{};
        for (final value in tokensNode.values) {
          if (value is Map) {
            final rawCity = (value['city'] ?? '').toString().trim();
            if (rawCity.isEmpty) continue;
            tokenCities.add(CityScopeService.normalizeCity(rawCity));
          }
        }

        if (tokenCities.length != 1) continue;
        if (!tokenCities.contains(cityNormalized)) continue;

        updates['users/$userId/$cityField'] = cityNormalized;
        updates['users/$userId/${cityField}AssignedAt'] =
            ServerValue.timestamp;
        updatedCount++;
      }

      if (updates.isNotEmpty) {
        await FirebaseDatabase.instance.ref().update(updates);
      }
    } catch (_) {}

    return updatedCount;
  }

  static Future<Map<String, dynamic>> _sendLegacyFcmToTokens({
    required String serverKey,
    required List<String> tokens,
    required String title,
    required String body,
    required Map<String, String> data,
    String? channelId,
  }) async {
    if (tokens.isEmpty) {
      return {
        'successCount': 0,
        'failureCount': 0,
        'firstError': '',
      };
    }

    var totalSuccess = 0;
    var totalFailure = 0;
    String firstError = '';

    final uri = Uri.parse(_fcmLegacyEndpoint);
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=UTF-8',
      'Authorization': 'key=$serverKey',
    };

    for (final chunk in _chunkTokens(tokens, _fcmLegacyBatchSize)) {
      final payload = <String, dynamic>{
        'registration_ids': chunk,
        'collapse_key': data['orderId'] != null ? 'order_${data['orderId']}' : 'general_alert',
        'priority': 'high',
        'content_available': true,
        'notification': <String, dynamic>{
          'title': title,
          'body': body,
          'sound': 'default',
          'android_channel_id': channelId ?? _channel.id,
        },
        'data': data,
      };

      final response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('FCM send failed (${response.statusCode})');
      }

      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final chunkSuccess = (decoded['success'] as num?)?.toInt() ?? 0;
          final chunkFailure = (decoded['failure'] as num?)?.toInt() ?? 0;
          totalSuccess += chunkSuccess;
          totalFailure += chunkFailure;

          if (firstError.isEmpty && decoded['results'] is List) {
            final results = decoded['results'] as List<dynamic>;
            for (final item in results) {
              if (item is Map && item['error'] != null) {
                firstError = item['error'].toString();
                break;
              }
            }
          }
        }
      } catch (_) {
        // If response is non-standard but 2xx, proceed with best-effort counts.
      }
    }

    return {
      'successCount': totalSuccess,
      'failureCount': totalFailure,
      'firstError': firstError,
    };
  }

  // Called from admin to send broadcast push notification
  static Future<Map<String, String>> sendBroadcastToAll({
    required String title,
    required String body,
  }) async {
    await CityScopeService.ensureLoaded();
    final user = FirebaseAuth.instance.currentUser;
    String targetCity = CityScopeService.currentCity;

    if (user != null) {
      try {
        final userSnap = await FirebaseDatabase.instance
            .ref('users/${user.uid}')
            .get();
        if (userSnap.exists && userSnap.value is Map) {
          final data = Map<String, dynamic>.from(userSnap.value as Map);
          final role = (data['role'] ?? 'customer').toString().toLowerCase();
          final rawCity = role == 'admin'
              ? (data['adminCity'] ?? '').toString()
              : (data['userCity'] ?? '').toString();
          if (rawCity.trim().isNotEmpty) {
            targetCity = CityScopeService.normalizeCity(rawCity);
          }
        }
      } catch (_) {}
    }

    await CityScopeService.setSelectedCity(targetCity);

    await _backfillMissingUserCityFromTokens(targetCity: targetCity);

    final targetTokens = await _collectTokensForCity(targetCity);
    if (targetTokens.isEmpty) {
      throw Exception(
        'No user FCM tokens found in ${CityScopeService.cityLabel(targetCity)}. Users must login once and allow notifications.',
      );
    }

    final serviceAccountJson =
        await _resolveManualFcmServiceAccountJson(city: targetCity);
    final legacyServerKey = await _resolveManualFcmServerKey(city: targetCity);

    if (serviceAccountJson == null && legacyServerKey == null) {
      throw Exception(
        'FCM sender credential missing. Set Admin App Settings > FCM HTTP v1 Service Account JSON first.',
      );
    }

    var delivery = 'fcm_http_v1_manual';
    var fcmSent = 0;
    var fcmFailed = 0;

    late final Map<String, dynamic> fcmResult;
    if (serviceAccountJson != null) {
      fcmResult = await _sendHttpV1FcmToTokens(
        serviceAccountJson: serviceAccountJson,
        tokens: targetTokens,
        title: title,
        body: body,
        data: <String, String>{
          'type': 'broadcast',
          'city': targetCity,
          'source': 'admin_manual_broadcast',
        },
      );
    } else {
      final serverKey = legacyServerKey!;
      if (serverKey.startsWith('AIza')) {
        throw Exception(
          'Invalid credential: API key detected. Paste Service Account JSON for HTTP v1 method.',
        );
      }
      delivery = 'fcm_manual_legacy';
      fcmResult = await _sendLegacyFcmToTokens(
        serverKey: serverKey,
        tokens: targetTokens,
        title: title,
        body: body,
        data: <String, String>{
          'type': 'broadcast',
          'city': targetCity,
          'source': 'admin_manual_broadcast',
        },
      );
    }

    fcmSent = (fcmResult['successCount'] as int?) ?? 0;
    fcmFailed = (fcmResult['failureCount'] as int?) ?? 0;

    if (fcmSent <= 0) {
      final error = (fcmResult['firstError'] ?? '').toString().trim();
      throw Exception(
        error.isNotEmpty
            ? 'FCM failed: $error'
            : 'FCM failed: 0 successful deliveries',
      );
    }

    await FirebaseDatabase.instance
        .ref(
          CityScopeService.tenantPath(
            'notifications/broadcast',
            city: targetCity,
          ),
        )
        .push()
        .set({
          'title': title,
          'body': body,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'sentBy': FirebaseAuth.instance.currentUser?.uid ?? 'admin',
          'city': targetCity,
          'delivery': delivery,
          'fcmSentCount': fcmSent,
          'fcmFailedCount': fcmFailed,
        });

    return {
      'city': targetCity,
      'fcmSent': fcmSent.toString(),
      'fcmFailed': fcmFailed.toString(),
    };
  }

  // Called from admin/merchant/customer to send direct push notification to one user
  static Future<Map<String, String>> sendToSpecificUser({
    required String target,
    required String title,
    required String body,
    Map<String, String>? data,
    Map<String, dynamic>? details,
    String? type,
    String? source,
  }) async {
    await CityScopeService.ensureLoaded();

    final rawTarget = target.trim();
    if (rawTarget.isEmpty) {
      throw Exception('Target user UID/email is required');
    }

    final usersRef = FirebaseDatabase.instance.ref('users');
    String targetUserId = rawTarget;
    Map<String, dynamic>? userData;

    try {
      if (rawTarget.contains('@')) {
        final usersSnap = await usersRef.get();
        if (usersSnap.exists && usersSnap.value is Map) {
          final allUsers = usersSnap.value as Map<dynamic, dynamic>;
          for (final entry in allUsers.entries) {
            if (entry.value is! Map) continue;
            final data = Map<String, dynamic>.from(entry.value as Map);
            final email = (data['email'] ?? '').toString().toLowerCase();
            if (email == rawTarget.toLowerCase()) {
              targetUserId = entry.key.toString();
              userData = data;
              break;
            }
          }
        }
      } else {
        final userSnap = await usersRef.child(rawTarget).get();
        if (userSnap.exists && userSnap.value is Map) {
          userData = Map<String, dynamic>.from(userSnap.value as Map);
        }
      }
    } catch (_) {}

    final role = userData != null
        ? (userData['role'] ?? 'customer').toString().toLowerCase()
        : 'customer';

    final rawCity = userData != null
        ? (role == 'admin'
            ? (userData['adminCity'] ?? '').toString()
            : (userData['userCity'] ?? '').toString())
        : '';
    final targetCity = rawCity.trim().isNotEmpty
        ? CityScopeService.normalizeCity(rawCity)
        : CityScopeService.currentCity;

    final displayName = userData != null
        ? (userData['name'] ??
                userData['displayName'] ??
                userData['email'] ??
                targetUserId)
            .toString()
        : targetUserId;

    final serviceAccountJson =
        await _resolveManualFcmServiceAccountJson(city: targetCity);
    final legacyServerKey = await _resolveManualFcmServerKey(city: targetCity);

    if (serviceAccountJson == null && legacyServerKey == null) {
      throw Exception(
        'FCM sender credential missing. Set Admin App Settings > FCM HTTP v1 Service Account JSON first.',
      );
    }

    final dataPayload = <String, String>{
      'type': 'direct_push',
      'city': targetCity,
      'source': 'direct_push',
      'targetUserId': targetUserId,
      if (data != null) ...data,
    };

    var delivery = 'fcm_http_v1_manual';
    var fcmSent = 0;
    var fcmFailed = 0;

    // Send to personal topic
    final topic = 'user_$targetUserId';
    try {
      if (serviceAccountJson != null) {
        await _sendHttpV1FcmToTopic(
          serviceAccountJson: serviceAccountJson,
          topic: topic,
          title: title,
          body: body,
          data: dataPayload,
        );
      } else {
        await _sendLegacyFcmToTopic(
          serverKey: legacyServerKey!,
          topic: topic,
          title: title,
          body: body,
          data: dataPayload,
        );
      }
      fcmSent++;
    } catch (_) {}

    // Send to individual tokens as backup
    final targetTokens = <String>{};
    if (userData != null) {
      targetTokens.addAll(_extractTokensFromUserData(userData));
    }

    if (targetTokens.isEmpty) {
      for (final roleSegment in ['activeAdminTokens', 'activeRiderTokens']) {
        final tenantPath = CityScopeService.tenantPath(
          'settings/app-control/$roleSegment/$targetUserId',
          city: targetCity,
        );
        try {
          final snap = await FirebaseDatabase.instance.ref(tenantPath).get();
          if (snap.exists && snap.value != null) {
            final val = snap.value;
            if (val is Map) {
              final tokensMap = Map<dynamic, dynamic>.from(val);
              for (final tokenEntry in tokensMap.values) {
                if (tokenEntry is Map) {
                  final t = (tokenEntry['token'] ?? '').toString().trim();
                  if (t.isNotEmpty) {
                    targetTokens.add(t);
                  }
                } else if (tokenEntry is String) {
                  final t = tokenEntry.trim();
                  if (t.isNotEmpty) {
                    targetTokens.add(t);
                  }
                }
              }
            }
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Failed to fetch specific user mirrored tokens at $tenantPath: $e');
          }
        }
      }
    }

    if (targetTokens.isNotEmpty) {
      late final Map<String, dynamic> fcmResult;
      final tokensList = targetTokens.toList(growable: false);
      if (serviceAccountJson != null) {
        fcmResult = await _sendHttpV1FcmToTokens(
          serviceAccountJson: serviceAccountJson,
          tokens: tokensList,
          title: title,
          body: body,
          data: dataPayload,
        );
      } else {
        final serverKey = legacyServerKey!;
        delivery = 'fcm_manual_legacy';
        fcmResult = await _sendLegacyFcmToTokens(
          serverKey: serverKey,
          tokens: tokensList,
          title: title,
          body: body,
          data: dataPayload,
        );
      }
      fcmSent += (fcmResult['successCount'] as int?) ?? 0;
      fcmFailed += (fcmResult['failureCount'] as int?) ?? 0;
    }

    try {
      await FirebaseDatabase.instance
          .ref(
            CityScopeService.tenantPath(
              'notifications/user/$targetUserId',
              city: targetCity,
            ),
          )
          .push()
          .set({
            'title': title,
            'body': body,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'sentBy': FirebaseAuth.instance.currentUser?.uid ?? 'system',
            'city': targetCity,
            'type': type ?? 'direct_push',
            'source': source ?? 'direct_push',
            'delivery': delivery,
            'fcmSentCount': fcmSent,
            'fcmFailedCount': fcmFailed,
            'read': false,
            if (details != null) 'details': details,
          });
    } catch (_) {}

    return {
      'userId': targetUserId,
      'city': targetCity,
      'userLabel': displayName,
      'fcmSent': fcmSent.toString(),
      'fcmFailed': fcmFailed.toString(),
    };
  }

  // Send background push notification to all users with a specific role in a city scope
  static Future<Map<String, dynamic>> sendNotificationToRole({
    required String role,
    required String title,
    required String body,
    required Map<String, String> data,
    String? city,
    String? channelId,
  }) async {
    try {
      await CityScopeService.ensureLoaded();
      final cityNormalized = city != null && city.trim().isNotEmpty
          ? CityScopeService.normalizeCity(city)
          : CityScopeService.currentCity;

      final roleNormalized = role.toLowerCase().trim();
      final topic = 'role_${roleNormalized}_$cityNormalized';

      final serviceAccountJson =
          await _resolveManualFcmServiceAccountJson(city: cityNormalized);
      final legacyServerKey = await _resolveManualFcmServerKey(city: cityNormalized);

      if (serviceAccountJson == null && legacyServerKey == null) {
        return {
          'successCount': 0,
          'failureCount': 0,
          'firstError': 'FCM sender credentials missing for city $cityNormalized',
        };
      }

      // Send to Topic
      Map<String, dynamic> topicResult;
      if (serviceAccountJson != null) {
        topicResult = await _sendHttpV1FcmToTopic(
          serviceAccountJson: serviceAccountJson,
          topic: topic,
          title: title,
          body: body,
          data: data,
          channelId: channelId,
        );
      } else {
        topicResult = await _sendLegacyFcmToTopic(
          serverKey: legacyServerKey!,
          topic: topic,
          title: title,
          body: body,
          data: data,
          channelId: channelId,
        );
      }

      // Try sending to individual tokens as backup
      final targetTokens = <String>{};

      // 1. Fetch mirrored tokens from public path first
      final pathSegment = roleNormalized == 'admin' ? 'activeAdminTokens' : 'activeRiderTokens';
      final tenantPath = CityScopeService.tenantPath('settings/app-control/$pathSegment', city: cityNormalized);
      try {
        final snap = await FirebaseDatabase.instance.ref(tenantPath).get();
        if (snap.exists && snap.value != null) {
          final val = snap.value;
          if (val is Map) {
            final userMap = Map<dynamic, dynamic>.from(val);
            for (final userEntry in userMap.values) {
              if (userEntry is Map) {
                final tokensMap = Map<dynamic, dynamic>.from(userEntry);
                for (final tokenEntry in tokensMap.values) {
                  if (tokenEntry is Map) {
                    final t = (tokenEntry['token'] ?? '').toString().trim();
                    if (t.isNotEmpty) {
                      targetTokens.add(t);
                    }
                  } else if (tokenEntry is String) {
                    final t = tokenEntry.trim();
                    if (t.isNotEmpty) {
                      targetTokens.add(t);
                    }
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to read mirrored tokens for role $roleNormalized from $tenantPath: $e');
        }
      }

      // 2. Fetch from user profiles (only as fallback if mirrored tokens are empty)
      if (targetTokens.isEmpty) {
        try {
          final snap = await FirebaseDatabase.instance
              .ref('users')
              .orderByChild('role')
              .equalTo(roleNormalized)
              .get();

          if (snap.exists) {
            final val = snap.value;
            final usersList = <Map<String, dynamic>>[];
            if (val is Map) {
              for (final value in val.values) {
                if (value is Map) {
                  usersList.add(Map<String, dynamic>.from(value));
                }
              }
            } else if (val is List) {
              for (final value in val) {
                if (value is Map) {
                  usersList.add(Map<String, dynamic>.from(value));
                }
              }
            }

            for (final userData in usersList) {
              final userRole = (userData['role'] ?? 'customer').toString().toLowerCase().trim();
              if (userRole != roleNormalized) continue;

              final rawCity = userRole == 'admin'
                  ? (userData['adminCity'] ?? '').toString().trim().toLowerCase()
                  : (userData['userCity'] ?? '').toString().trim().toLowerCase();

              if (userRole == 'admin' && (rawCity.isEmpty || rawCity == 'all' || rawCity == 'global')) {
                // Super admin gets notifications for all cities
              } else {
                final userCity = CityScopeService.normalizeCity(rawCity);
                if (userCity != cityNormalized) continue;
              }

              final userTokens = _extractTokensFromUserData(userData);
              targetTokens.addAll(userTokens);
            }
          }
        } catch (_) {}
      }

      if (targetTokens.isNotEmpty) {
        try {
          if (serviceAccountJson != null) {
            await _sendHttpV1FcmToTokens(
              serviceAccountJson: serviceAccountJson,
              tokens: targetTokens.toList(growable: false),
              title: title,
              body: body,
              data: data,
              channelId: channelId,
            );
          } else {
            await _sendLegacyFcmToTokens(
              serverKey: legacyServerKey!,
              tokens: targetTokens.toList(growable: false),
              title: title,
              body: body,
              data: data,
              channelId: channelId,
            );
          }
        } catch (_) {}
      }

      return topicResult;
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('sendNotificationToRole failed: $e\n$stack');
      }
      return {
        'successCount': 0,
        'failureCount': 1,
        'firstError': 'Exception: $e',
      };
    }
  }

  static Future<Map<String, dynamic>> _sendHttpV1FcmToTopic({
    required String serviceAccountJson,
    required String topic,
    required String title,
    required String body,
    required Map<String, String> data,
    String? channelId,
  }) async {
    final auth = await _resolveHttpV1Auth(
      serviceAccountJson: serviceAccountJson,
    );
    final projectId = auth['projectId']!;
    final accessToken = auth['accessToken']!;
    final endpoint = Uri.parse(
      'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
    );

    final payload = <String, dynamic>{
      'message': <String, dynamic>{
        'topic': topic,
        'notification': <String, dynamic>{
          'title': title,
          'body': body,
        },
        'data': data,
        'android': <String, dynamic>{
          'priority': 'HIGH',
          'collapse_key': data['orderId'] != null ? 'order_${data['orderId']}' : 'general_alert',
          'notification': <String, dynamic>{
            'channel_id': channelId ?? _channel.id,
            'sound': 'default',
          },
        },
        'apns': <String, dynamic>{
          'headers': <String, String>{
            'apns-priority': '10',
          },
          'payload': <String, dynamic>{
            'aps': <String, dynamic>{
              'sound': 'default',
              'badge': 1,
              'content-available': 1,
            },
          },
        },
      },
    };

    final response = await http.post(
      endpoint,
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(payload),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return {
        'successCount': 1,
        'failureCount': 0,
        'firstError': '',
      };
    }

    String message = 'HTTP ${response.statusCode}';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map) {
          final serverMessage = (err['message'] ?? '').toString().trim();
          if (serverMessage.isNotEmpty) {
            message = serverMessage;
          }
        }
      }
    } catch (_) {}

    return {
      'successCount': 0,
      'failureCount': 1,
      'firstError': message,
    };
  }

  static Future<Map<String, dynamic>> _sendLegacyFcmToTopic({
    required String serverKey,
    required String topic,
    required String title,
    required String body,
    required Map<String, String> data,
    String? channelId,
  }) async {
    final uri = Uri.parse(_fcmLegacyEndpoint);
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=UTF-8',
      'Authorization': 'key=$serverKey',
    };

    final payload = <String, dynamic>{
      'to': '/topics/$topic',
      'collapse_key': data['orderId'] != null ? 'order_${data['orderId']}' : 'general_alert',
      'priority': 'high',
      'content_available': true,
      'notification': <String, dynamic>{
        'title': title,
        'body': body,
        'sound': 'default',
        'android_channel_id': channelId ?? _channel.id,
      },
      'data': data,
    };

    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode(payload),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return {
        'successCount': 0,
        'failureCount': 1,
        'firstError': 'HTTP ${response.statusCode}',
      };
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        if (decoded['message_id'] != null || decoded['multicast_id'] != null) {
          return {
            'successCount': 1,
            'failureCount': 0,
            'firstError': '',
          };
        }
        if (decoded['error'] != null) {
          return {
            'successCount': 0,
            'failureCount': 1,
            'firstError': decoded['error'].toString(),
          };
        }
      }
    } catch (_) {}

    return {
      'successCount': 1,
      'failureCount': 0,
      'firstError': '',
    };
  }

  static Future<void> deleteUserInboxNotification(String id) async {
    await CityScopeService.ensureLoaded();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    try {
      await FirebaseDatabase.instance
          .ref(userInboxPath(uid))
          .child(id)
          .remove();
    } catch (_) {}
  }

  static Future<void> deleteAllUserInboxNotifications() async {
    await CityScopeService.ensureLoaded();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    try {
      await FirebaseDatabase.instance
          .ref(userInboxPath(uid))
          .remove();
    } catch (_) {}
  }

  static Map<String, String> getOrderStatusNotificationCopy({
    required String status,
    required String orderCode,
    String? shopName,
    String? cancelReason,
  }) {
    final s = status.trim().toLowerCase();
    final code = orderCode.trim();
    final shop = (shopName ?? '').trim();
    final orderLabel = code.isNotEmpty ? 'Order #$code' : 'Your order';

    String title = 'Order Update';
    String body = '$orderLabel status has been updated.';

    switch (s) {
      case 'pending':
        title = 'Order Placed';
        body = '$orderLabel has been successfully placed and is being reviewed.';
        break;
      case 'merchant_pending':
      case 'accepted':
        title = 'Order Accepted';
        body = '$orderLabel has been accepted and is waiting for merchant confirmation.';
        break;
      case 'confirmed':
        title = 'Order Confirmed';
        body = '$orderLabel has been confirmed and will be prepared shortly.';
        break;
      case 'preparing':
        title = 'Order Preparing';
        body = shop.isNotEmpty
            ? '$shop is now preparing your order #$code.'
            : 'Your order #$code is now being prepared.';
        break;
      case 'picked':
      case 'picked_up':
        title = 'Order Picked Up';
        body = shop.isNotEmpty
            ? 'Your order #$code has been picked up from $shop and is ready for delivery.'
            : 'Your order #$code has been picked up by the rider.';
        break;
      case 'on_the_way':
      case 'on_way':
      case 'out_for_delivery':
        title = 'Order Out for Delivery';
        body = 'Our rider is on the way with your order #$code. Get ready!';
        break;
      case 'delivered':
        title = 'Order Delivered';
        body = 'Your order #$code has been delivered successfully. Enjoy your meal!';
        break;
      case 'cancelled':
      case 'canceled':
        title = 'Order Cancelled';
        final reason = (cancelReason ?? '').trim();
        body = reason.isNotEmpty
            ? '$orderLabel has been cancelled: $reason.'
            : '$orderLabel has been cancelled.';
        break;
    }

    return {'title': title, 'body': body};
  }

  static Future<void> sendOrderStatusNotification({
    required String targetUserId,
    required String status,
    required String orderId,
    required String orderCode,
    String? shopName,
    String? cancelReason,
  }) async {
    final copy = getOrderStatusNotificationCopy(
      status: status,
      orderCode: orderCode,
      shopName: shopName,
      cancelReason: cancelReason,
    );

    final title = copy['title']!;
    final body = copy['body']!;

    try {
      await sendToSpecificUser(
        target: targetUserId,
        title: title,
        body: body,
        type: 'order_status',
        source: 'order_lifecycle',
        data: {
          'orderId': orderId,
          'orderCode': orderCode,
          'status': status,
          if (shopName != null) 'shopName': shopName,
          if (cancelReason != null) 'cancelReason': cancelReason,
        },
        details: {
          'orderId': orderId,
          'orderCode': orderCode,
          'status': status,
          if (shopName != null) 'shopName': shopName,
          if (cancelReason != null) 'cancelReason': cancelReason,
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to send order status notification via FCM: $e');
      }
      await CityScopeService.ensureLoaded();
      final targetCity = CityScopeService.currentCity;
      await FirebaseDatabase.instance
          .ref(
            CityScopeService.tenantPath(
              'notifications/user/$targetUserId',
              city: targetCity,
            ),
          )
          .push()
          .set({
            'title': title,
            'body': body,
            'createdAt': ServerValue.timestamp,
            'read': false,
            'type': 'order_status',
            'source': 'order_lifecycle',
            'details': {
              'orderId': orderId,
              'orderCode': orderCode,
              'status': status,
              if (shopName != null) 'shopName': shopName,
              if (cancelReason != null) 'cancelReason': cancelReason,
            },
          });
    }
  }
}
