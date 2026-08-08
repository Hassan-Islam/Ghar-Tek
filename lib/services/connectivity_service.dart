import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'db/app_db_client.dart';

/// Tracks whether the GharTek backend is reachable (real internet + API up).
class ConnectivityService extends ChangeNotifier {
  static final ConnectivityService _instance = ConnectivityService._();
  factory ConnectivityService() => _instance;
  ConnectivityService._();

  bool _isConnected = true;
  bool get isConnected => _isConnected;
  bool get showBanner => !_isConnected;

  Timer? _pollTimer;

  void startListening() {
    _pollTimer?.cancel();
    unawaited(refreshStatus(force: true));
    _pollTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      refreshStatus();
    });
  }

  void _applyConnectionState(bool connected) {
    if (_isConnected != connected) {
      _isConnected = connected;
      notifyListeners();
    }
  }

  Future<void> refreshStatus({bool force = false}) async {
    try {
      await AppDbClient.instance.initialize();
      final base = AppDbClient.instance.httpBase;
      final res = await http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final body = res.body;
        _applyConnectionState(body.contains('"ok":true') || body.contains('"ok": true'));
      } else if (force) {
        _applyConnectionState(false);
      }
    } on TimeoutException {
      if (force) _applyConnectionState(false);
    } catch (_) {
      if (force) _applyConnectionState(false);
    }
  }

  void stopListening() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}

/// Wrap around app body to show offline banner
class ConnectivityWrapper extends StatefulWidget {
  final Widget child;
  const ConnectivityWrapper({super.key, required this.child});

  @override
  State<ConnectivityWrapper> createState() => _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends State<ConnectivityWrapper> {
  final _service = ConnectivityService();

  @override
  void initState() {
    super.initState();
    _service.startListening();
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
