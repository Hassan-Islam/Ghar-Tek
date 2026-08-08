import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

/// All application data lives in the PostgreSQL backend (REST + WebSocket).
/// Firebase is used ONLY for authentication and push notifications — never for
/// reading/writing data. This avoids the "orders appear then disappear" flicker
/// and Firebase permission errors that happened when the client fell back to an
/// empty/denied Firebase Realtime Database.
class AppDbClient {
  AppDbClient._();
  static final AppDbClient instance = AppDbClient._();

  static const String _prefApiBase = 'ghartek_api_base';

  static const String _apiOverride =
      String.fromEnvironment('GHARTEK_API', defaultValue: '');

  /// Production backend on DigitalOcean (HTTPS via Caddy/Let's Encrypt).
  /// Tried first on real devices; app still falls back to Firebase RTDB when
  /// the server has no imported data yet.
  static const String _productionBase = 'https://168-144-126-109.sslip.io';

  String? _resolvedBase;
  // Data always comes from Postgres. Kept as a constant so the realtime helpers
  // that reference it keep compiling; it is never set true.
  final bool _useFirebase = false;
  bool _initialized = false;
  Future<void>? _initFuture;

  /// Always `postgres` — data never comes from Firebase.
  String get activeBackend => 'postgres';

  String get httpBase {
    if (_resolvedBase != null) return _resolvedBase!;
    if (_apiOverride.isNotEmpty) return _apiOverride;
    return _productionBase;
  }

  String get wsBase => '${httpBase.replaceFirst('http', 'ws')}/rtdb';

  Future<String?> Function()? tokenProvider;

  final http.Client _http = http.Client();

  /// Call once at app start. Resolves the best-reachable Postgres backend URL.
  /// Data always uses Postgres — it never switches to Firebase.
  Future<void> initialize() {
    _initFuture ??= _doInitialize();
    return _initFuture!;
  }

  Future<void> _doInitialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_prefApiBase);

    final candidates = <String>[
      if (_apiOverride.isNotEmpty) _apiOverride,
      if (cached != null && cached.isNotEmpty) cached,
      // Production DigitalOcean backend (HTTPS) — primary for real devices.
      _productionBase,
      // Local development fallbacks (adb reverse / emulator / desktop).
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
        'http://127.0.0.1:8080', // physical phone + adb reverse
        'http://10.0.2.2:8080', // Android emulator
      ],
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        'http://127.0.0.1:8080',
      'http://localhost:8080',
      if (kIsWeb) 'http://localhost:8080',
    ];

    final seen = <String>{};
    for (final url in candidates) {
      if (!seen.add(url)) continue;
      if (await _probeHealth(url)) {
        _resolvedBase = url;
        await prefs.setString(_prefApiBase, url);
        _initialized = true;
        debugPrint('[AppDb] using PostgreSQL backend at $url');
        return;
      }
    }

    // No health probe succeeded (transient network blip at startup). Still use
    // Postgres via the production base — NEVER fall back to Firebase for data.
    _resolvedBase = null; // httpBase getter returns the production base.
    _initialized = true;
    debugPrint(
      '[AppDb] health probe failed at startup; defaulting to Postgres production base',
    );
  }

  Future<bool> _probeHealth(String base) async {
    try {
      final res = await _http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body);
      return body is Map && body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureReady() async {
    if (!_initialized) await initialize();
  }

  Future<Map<String, String>> _headers() async {
    final headers = {'Content-Type': 'application/json'};
    try {
      final token = await tokenProvider?.call();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    } catch (_) {}
    return headers;
  }

  Future<Map<String, dynamic>> _post(String ep, Map<String, dynamic> body) async {
    await _ensureReady();
    final res = await _http
        .post(
          Uri.parse('${httpBase}$ep'),
          headers: await _headers(),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return {};
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('DB $ep failed (${res.statusCode}): ${res.body}');
  }

  Future<Object?> getValue(String db, String path, {bool shallow = false}) async {
    await _ensureReady();
    final ep = shallow ? '/v1/get-shallow' : '/v1/get';
    final r = await _post(ep, {'db': db, 'path': path});
    return r['value'];
  }

  /// Fast queue stats for Islamabad (active count + user positions).
  Future<Map<String, dynamic>> fetchQueueStats(
    String tenantPath,
    String userId,
  ) async {
    await _ensureReady();
    if (_useFirebase) return {};
    try {
      return await _post('/v1/queue-stats', {
        'db': 'main',
        'path': tenantPath,
        'userId': userId,
      });
    } catch (e) {
      debugPrint('[AppDb] queue-stats failed: $e');
      return {};
    }
  }

  Future<void> setValue(String db, String path, Object? value) async {
    await _ensureReady();
    await _post('/v1/set', {'db': db, 'path': path, 'value': value});
  }

  Future<void> updateValue(String db, String path, Map<String, Object?> value) async {
    await _ensureReady();
    await _post('/v1/update', {'db': db, 'path': path, 'value': value});
  }

  Future<void> removeValue(String db, String path) async {
    await _ensureReady();
    await _post('/v1/remove', {'db': db, 'path': path});
  }

  Future<Map<String, dynamic>> query(
    String db,
    String path,
    Map<String, dynamic> q,
  ) async {
    await _ensureReady();
    // Empty `order` is a valid result (no matching children). Always return the
    // Postgres result — never fall back to Firebase, which caused orders to
    // flicker in and out.
    return await _post('/v1/query', {'db': db, 'path': path, 'query': q});
  }

  Future<Map<String, dynamic>> compareAndSet(
    String db,
    String path,
    Object? expected,
    Object? value,
  ) async {
    await _ensureReady();
    return await _post('/v1/cas',
        {'db': db, 'path': path, 'expected': expected, 'value': value});
  }

  // ---- realtime ----------------------------------------------------------

  WebSocketChannel? _channel;
  bool _connecting = false;
  int _subCounter = 0;
  final Map<String, _Subscription> _subs = {};
  Timer? _reconnectTimer;

  Stream<DbEvent> subscribe({
    required String db,
    required String path,
    required String event,
    Map<String, dynamic>? query,
  }) {
    final subId = 's${_subCounter++}';
    late final StreamController<DbEvent> controller;
    controller = StreamController<DbEvent>.broadcast(
      onListen: () async {
        await _ensureReady();
        _subs[subId] =
            _Subscription(subId, db, path, event, query, controller);
        _ensureConnected();
        _sendSubscribe(_subs[subId]!);
      },
      onCancel: () {
        _send({'type': 'unsubscribe', 'subId': subId});
        _subs.remove(subId);
      },
    );
    return controller.stream;
  }

  void _ensureConnected() {
    if (_useFirebase || _channel != null || _connecting) return;
    _connecting = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsBase));
      _channel = channel;
      _connecting = false;
      channel.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
      for (final sub in _subs.values) {
        _sendSubscribe(sub);
      }
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _onDisconnected() {
    _channel = null;
    if (_subs.isNotEmpty && !_useFirebase) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_subs.isNotEmpty && !_useFirebase) _ensureConnected();
    });
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (msg['type'] != 'event') return;
    final sub = _subs[msg['subId']];
    if (sub == null || sub.controller.isClosed) return;
    sub.controller.add(DbEvent(
      event: msg['event'] as String? ?? 'value',
      key: msg['key'] as String?,
      value: msg['value'],
      order: (msg['order'] as List?)?.cast<String>(),
      previousChildKey: msg['prevKey'] as String?,
    ));
  }

  void _sendSubscribe(_Subscription sub) {
    _send({
      'type': 'subscribe',
      'subId': sub.subId,
      'db': sub.db,
      'path': sub.path,
      'event': sub.event,
      if (sub.query != null) 'query': sub.query,
    });
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _channel?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
  }
}

class _Subscription {
  _Subscription(this.subId, this.db, this.path, this.event, this.query,
      this.controller);
  final String subId;
  final String db;
  final String path;
  final String event;
  final Map<String, dynamic>? query;
  final StreamController<DbEvent> controller;
}

class DbEvent {
  DbEvent({
    required this.event,
    this.key,
    this.value,
    this.order,
    this.previousChildKey,
  });
  final String event;
  final String? key;
  final Object? value;
  final List<String>? order;
  final String? previousChildKey;
}
