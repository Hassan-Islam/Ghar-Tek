import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import '../services/image_helper.dart';
import 'dart:async';
import 'dart:math';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/order_tracking_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'user_chat_page.dart';

class OrderTrackingPage extends StatefulWidget {
  final Map<String, dynamic> order;
  const OrderTrackingPage({super.key, required this.order});

  @override
  State<OrderTrackingPage> createState() => _OrderTrackingPageState();
}

class _OrderTrackingPageState extends State<OrderTrackingPage>
    with TickerProviderStateMixin {
  // -- Theme ------------------------------------------------------------------
  static const Color _primary = Color(0xFFFF6B00);
  static const Color _primaryLight = Color(0xFFFFF3E8);
  static const Color _bg = Colors.white;

  // -- Animations -------------------------------------------------------------
  late AnimationController _progressCtrl;
  late AnimationController _pulseCtrl;
  late AnimationController _riderCtrl;
  late Animation<double> _progressAnim;
  late Animation<double> _pulseAnim;
  late Animation<double> _riderAnim;

  // -- Tracking ---------------------------------------------------------------
  final OrderTrackingService _trackingService = OrderTrackingService();
  final _database = FirebaseDatabase.instance.ref();
  StreamSubscription? _orderSub;
  Timer? _localTimer;

  Map<String, dynamic>? _orderData;
  double _progress = 0.0;
  int _remainingTime = 0;
  String _status = 'pending';
  Map<String, dynamic>? _riderInfo;

  String _customerVisibleStatus(dynamic rawStatus) {
    final status = (rawStatus ?? 'pending').toString().toLowerCase().trim();
    if (status == 'on_way' || status == 'out_for_delivery') return 'on_the_way';
    if (status == 'available') return 'pending';
    if (status == 'picked') return 'preparing';
    return status;
  }

  @override
  void initState() {
    super.initState();
    _orderData = Map<String, dynamic>.from(widget.order);

    _progressCtrl = AnimationController(
        duration: const Duration(milliseconds: 1800), vsync: this);
    _pulseCtrl = AnimationController(
        duration: const Duration(milliseconds: 1200), vsync: this)
      ..repeat(reverse: true);
    _riderCtrl = AnimationController(
        duration: const Duration(seconds: 4), vsync: this)
      ..repeat();

    _progressAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _progressCtrl, curve: Curves.easeInOut));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.35).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _riderAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _riderCtrl, curve: Curves.linear));

    _initOrder();
    _listenToOrder();
    _loadRiderInfo();
  }

  Future<void> _initOrder() async {
    _status = _customerVisibleStatus(_orderData!['status']);
    const active = ['confirmed', 'preparing', 'on_the_way'];
    if (!active.contains(_status)) {
      setState(() {
        _progress = _statusToProgress(_status);
        _remainingTime = 0;
      });
      _progressCtrl.animateTo(_progress);
      return;
    }
    await _loadSavedTimer();
    _progressCtrl.animateTo(_progress);
    if (_remainingTime > 0) _startLocalTimer();
  }

  Future<void> _loadSavedTimer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = (widget.order['id'] ?? '').toString();
      if (id.isEmpty) return;

      final startMs = prefs.getInt('ts_start_$id');
      final estMin = prefs.getInt('ts_est_$id');

      if (startMs != null && estMin != null) {
        final elapsed = DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(startMs))
            .inSeconds;
        final total = estMin * 60;
        if (elapsed < total) {
          setState(() {
            _remainingTime = total - elapsed;
            _progress = (elapsed / total).clamp(0.0, 1.0);
            _status = _progressToStatus(_progress);
          });
          return;
        } else {
          setState(() {
            _remainingTime = 0;
            _progress = 1.0;
            _status = 'delivered';
          });
          _updateDeliveredStatus();
          return;
        }
      }

      final ts = _orderData!['timestamp'] ?? _orderData!['createdAt'];
      DateTime orderTime =
          ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now();
      int estMinutes = (_orderData!['estimatedTime'] ?? 40) as int;
      if ((_orderData!['deliveryOption'] ?? '') == 'Fast') {
        estMinutes = (estMinutes * 0.6).round();
      }
      final elapsed = DateTime.now().difference(orderTime).inSeconds;
      final total = estMinutes * 60;
      setState(() {
        _remainingTime = (total - elapsed).clamp(0, total);
        _progress = (elapsed / total).clamp(0.0, 1.0);
        _status = _progressToStatus(_progress);
      });
      await prefs.setInt('ts_start_$id', orderTime.millisecondsSinceEpoch);
      await prefs.setInt('ts_est_$id', estMinutes);
    } catch (_) {}
  }

  void _listenToOrder() {
    final id = (widget.order['id'] ?? '').toString();
    if (id.isEmpty) return;
    _orderSub = _trackingService.getOrderTrackingStream(id).listen((data) {
      if (data != null && mounted) {
        setState(() {
          _orderData!.addAll(data);
          final remoteStatus = _customerVisibleStatus(data['status'] ?? _status);
          if (remoteStatus != _status) {
            _status = remoteStatus;
            _progress = _statusToProgress(_status);
            _progressCtrl.animateTo(_progress);
          }
        });
      }
    });
  }

  Future<void> _loadRiderInfo() async {
    try {
      final snap = await _database
          .child('riders')
          .orderByChild('active')
          .equalTo(true)
          .limitToFirst(1)
          .get();
      if (snap.exists && mounted) {
        final data = snap.value as Map<dynamic, dynamic>;
        data.forEach((k, v) {
          setState(() => _riderInfo = Map<String, dynamic>.from(v));
        });
      }
    } catch (_) {}
  }

  void _startLocalTimer() {
    _localTimer?.cancel();
    _localTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_remainingTime <= 0) {
        t.cancel();
        setState(() {
          _progress = 1.0;
          _status = 'delivered';
        });
        _progressCtrl.animateTo(1.0);
        _updateDeliveredStatus();
        return;
      }
      setState(() {
        _remainingTime--;
        final estMin = (_orderData!['estimatedTime'] ?? 40) as int;
        final total = estMin * 60;
        _progress = ((total - _remainingTime) / total).clamp(0.0, 1.0);
        final newStatus = _progressToStatus(_progress);
        if (newStatus != _status) {
          _status = newStatus;
          _showStatusSnack();
        }
        _progressCtrl.animateTo(_progress);
      });
    });
  }

  Future<void> _updateDeliveredStatus() async {
    try {
      final id = (widget.order['id'] ?? '').toString();
      if (id.isNotEmpty) await _trackingService.updateOrderStatus(id, 'delivered');
    } catch (_) {}
  }

  void _showStatusSnack() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '${_statusToEmoji(_status)} ${_statusToLabel(_status)}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      backgroundColor: _primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  void dispose() {
    _progressCtrl.dispose();
    _pulseCtrl.dispose();
    _riderCtrl.dispose();
    _orderSub?.cancel();
    _localTimer?.cancel();
    super.dispose();
  }

  // -- Helpers ----------------------------------------------------------------
  double _statusToProgress(String s) {
    final status = _customerVisibleStatus(s);
    switch (status) {
      case 'pending': return 0.05;
      case 'confirmed': return 0.25;
      case 'preparing': return 0.5;
      case 'on_the_way': case 'out_for_delivery': return 0.8;
      case 'delivered': return 1.0;
      default: return 0.05;
    }
  }

  String _progressToStatus(double p) {
    if (p >= 1.0) return 'delivered';
    if (p >= 0.75) return 'on_the_way';
    if (p >= 0.35) return 'preparing';
    if (p >= 0.1) return 'confirmed';
    return 'pending';
  }

  String _statusToLabel(String s) {
    final status = _customerVisibleStatus(s);
    switch (status) {
      case 'pending': return 'Waiting for rider pickup';
      case 'confirmed': return 'Order Confirmed!';
      case 'preparing': return 'Being Prepared...';
      case 'on_the_way': case 'out_for_delivery': return 'Rider on the way!';
      case 'delivered': return 'Delivered!';
      default: return 'Processing...';
    }
  }

  String _statusToEmoji(String s) {
    final status = _customerVisibleStatus(s);
    switch (status) {
      case 'pending': return '?';
      case 'confirmed': return '?';
      case 'preparing': return '?????';
      case 'on_the_way': case 'out_for_delivery': return '??';
      case 'delivered': return '??';
      default: return '??';
    }
  }

  String _formatTime(int secs) {
    if (secs <= 0) return '00:00';
    return '${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  String _eta() {
    final ts = _orderData!['timestamp'] ?? _orderData!['createdAt'];
    final orderTime =
        ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now();
    final estMin = (_orderData!['estimatedTime'] ?? 40) as int;
    final eta = orderTime.add(Duration(minutes: estMin));
    final h = eta.hour > 12 ? eta.hour - 12 : eta.hour == 0 ? 12 : eta.hour;
    final m = eta.minute.toString().padLeft(2, '0');
    final ampm = eta.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  int _stepIndexFromStatus(String s) {
    final status = _customerVisibleStatus(s);
    switch (status) {
      case 'confirmed':
        return 0;
      case 'preparing':
        return 1;
      case 'on_the_way':
      case 'out_for_delivery':
        return 2;
      case 'delivered':
        return 3;
      default:
        return -1;
    }
  }

  String _visualState() {
    final status = _customerVisibleStatus(_status);
    if (status == 'on_the_way' || status == 'out_for_delivery') {
      return 'on_the_way';
    }
    if (status == 'delivered') return 'delivered';
    return 'preparing';
  }

  int _etaMinutes() {
    if (_remainingTime > 0) return (_remainingTime / 60).ceil();
    return (_orderData?['estimatedTime'] ?? 40) as int;
  }

  // -- Build -------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final orderId = (widget.order['id'] ?? '').toString();
    final shortId =
        orderId.length >= 8 ? orderId.substring(0, 8).toUpperCase() : orderId.toUpperCase();
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(shortId),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 30),
                child: Column(
                  children: [
                    _buildStatusStepper(),
                    _buildStateSwitcherSection(),
                    _buildDetailsSheet(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String shortId) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x0A000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          ),
          const Expanded(
            child: Text(
              'Track Order',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A1A)),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _primaryLight,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _primary.withValues(alpha: 0.2)),
            ),
            child: Text(
              '#$shortId',
              style: const TextStyle(
                  fontSize: 12, color: _primary, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusStepper() {
    final steps = ['Accepted', 'Preparing', 'On the Way', 'Delivered'];
    final activeIndex = _stepIndexFromStatus(_status);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _stepItem(steps[0], activeIndex, 0),
          _stepLine(activeIndex >= 1),
          _stepItem(steps[1], activeIndex, 1),
          _stepLine(activeIndex >= 2),
          _stepItem(steps[2], activeIndex, 2),
          _stepLine(activeIndex >= 3),
          _stepItem(steps[3], activeIndex, 3),
        ],
      ),
    );
  }

  Widget _stepItem(String label, int activeIndex, int index) {
    final isActive = activeIndex >= index && activeIndex >= 0;
    return SizedBox(
      width: 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: isActive ? _primary : Colors.grey[300],
              shape: BoxShape.circle,
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: _primary.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: isActive ? _primary : Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepLine(bool isActive) {
    return Expanded(
      child: Container(
        height: 3,
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          color: isActive ? _primary : Colors.grey[200],
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }

  Widget _buildStateSwitcherSection() {
    final visual = _visualState();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final scale = Tween<double>(begin: 0.96, end: 1.0)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOut));
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: scale, child: child),
          );
        },
        child: visual == 'on_the_way'
            ? _buildOnTheWayState(key: const ValueKey('on_the_way'))
            : visual == 'delivered'
                ? _buildDeliveredState(key: const ValueKey('delivered'))
                : _buildPreparingState(key: const ValueKey('preparing')),
      ),
    );
  }

  Widget _buildPreparingState({Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            height: 240,
            child: Lottie.asset(
              'assets/cooking.json',
              fit: BoxFit.contain,
              repeat: true,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Great choice! The kitchen is preparing your order.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Freshly cooked and packed with care.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnTheWayState({Key? key}) {
    final etaMin = _etaMinutes();
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            height: 220,
            child: Lottie.asset(
              'assets/rider.json',
              fit: BoxFit.contain,
              repeat: true,
            ),
          ),
          const SizedBox(height: 10),
          _buildEtaBox(etaMin),
          const SizedBox(height: 12),
          _buildRiderInlineCard(),
        ],
      ),
    );
  }

  Widget _buildDeliveredState({Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: _primaryLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded,
                size: 46, color: _primary),
          ),
          const SizedBox(height: 14),
          const Text(
            'Delivered! Enjoy your meal.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Thank you for ordering with us.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildEtaBox(int etaMin) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _primaryLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, color: _primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ETA: $etaMin mins',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: _primary,
              ),
            ),
          ),
          Text(
            _eta(),
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildRiderInlineCard() {
    final name = _riderInfo?['name'] ?? 'Muhammad Usman';
    final phone = _riderInfo?['phone'] ?? '+92 300 1234567';
    final bike = _riderInfo?['vehicle'] ?? 'Honda CD 70';
    final rating = _riderInfo?['rating']?.toString() ?? '4.8';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _primaryLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.delivery_dining_rounded,
                color: _primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.star_rounded,
                        color: Colors.amber, size: 12),
                    const SizedBox(width: 3),
                    Text(rating,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[600])),
                    const SizedBox(width: 8),
                    const Icon(Icons.motorcycle_rounded,
                        color: Colors.grey, size: 12),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        bike,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  phone,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsSheet() {
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 18, 0, 0),
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildOrderDetailsCard(),
          _buildItemsCard(),
          _buildBillCard(),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    final isDelivered = _status == 'delivered';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDelivered
              ? [const Color(0xFF2E7D32), const Color(0xFF4CAF50)]
              : [const Color(0xFFFF6B00), const Color(0xFFFF9A3D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: (isDelivered ? Colors.green : _primary).withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Transform.scale(
              scale: isDelivered ? 1.0 : _pulseAnim.value,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _statusToEmoji(_status),
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusToLabel(_status),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 5),
                if (_remainingTime > 0)
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined,
                          color: Colors.white70, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        '${_formatTime(_remainingTime)} remaining',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  )
                else if (!isDelivered)
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded,
                          color: Colors.white70, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        'Est. arrival by ${_eta()}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  )
                else
                  const Text(
                    'Khana khosh raho! ??',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapSection() {
    final showRider = _status == 'on_the_way' ||
        _status == 'out_for_delivery' ||
        _status == 'preparing' ||
        _status == 'delivered';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      height: 230,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Map background
          CustomPaint(painter: _MapGridPainter()),

          // Animated route
          if (showRider)
            AnimatedBuilder(
              animation: _progressAnim,
              builder: (_, __) => CustomPaint(
                painter: _RoutePainter(
                    progress: _progress.clamp(0.0, 1.0), primary: _primary),
              ),
            ),

          // Destination pin
          Positioned(
            top: 36,
            right: 56,
            child: _mapPin(Icons.home_rounded, Colors.green[600]!),
          ),

          // Shop pin
          Positioned(
            bottom: 36,
            left: 56,
            child: _mapPin(Icons.storefront_rounded, const Color(0xFFFF6B00)),
          ),

          // Animated rider dot
          if (showRider)
            AnimatedBuilder(
              animation: _progressAnim,
              builder: (ctx, __) {
                final w = MediaQuery.of(ctx).size.width - 32;
                final x = 56.0 + (w - 112) * _progress.clamp(0.0, 1.0);
                final y = 194.0 - 158.0 * _progress.clamp(0.0, 1.0);
                return Positioned(
                  left: x - 22,
                  top: y - 22,
                  child: AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (_, __) => Transform.scale(
                      scale: _status == 'delivered' ? 1.0 : _pulseAnim.value,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _primary,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: _primary.withValues(alpha: 0.6),
                              blurRadius: 14,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.delivery_dining_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // Top bar
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.map_rounded,
                          size: 12, color: _primary),
                      SizedBox(width: 4),
                      Text('Live Tracking',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: _primary)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: _status == 'delivered'
                              ? Colors.grey
                              : Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _status == 'delivered' ? 'Completed' : 'Live',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _status == 'delivered'
                              ? Colors.grey
                              : Colors.green[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Legend
          Positioned(
            bottom: 14,
            left: 12,
            child: Row(
              children: [
                _legend(const Color(0xFFFF6B00), 'Restaurant'),
                const SizedBox(width: 12),
                _legend(Colors.green[600]!, 'Your Home'),
                const SizedBox(width: 12),
                _legend(_primary, 'Rider'),
              ],
            ),
          ),

          // Progress bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _progressAnim,
              builder: (_, __) => LinearProgressIndicator(
                value: _progressAnim.value,
                backgroundColor: Colors.grey[200],
                valueColor: AlwaysStoppedAnimation(_primary),
                minHeight: 4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapPin(IconData icon, Color color) {
    return Column(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 8,
                  spreadRadius: 2),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
        Container(width: 2, height: 8, color: color),
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ],
    );
  }

  Widget _legend(Color color, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildProgressTracker() {
    final stages = [
      {'key': 'pending', 'label': 'Order Placed', 'sub': 'We received your order', 'emoji': '??', 'minP': 0.0},
      {'key': 'confirmed', 'label': 'Confirmed', 'sub': 'Restaurant accepted', 'emoji': '?', 'minP': 0.1},
      {'key': 'preparing', 'label': 'Preparing', 'sub': 'Being cooked fresh', 'emoji': '?????', 'minP': 0.35},
      {'key': 'on_the_way', 'label': 'On the Way', 'sub': 'Rider heading to you', 'emoji': '??', 'minP': 0.75},
      {'key': 'delivered', 'label': 'Delivered', 'sub': 'Enjoy your meal!', 'emoji': '??', 'minP': 1.0},
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.timeline_rounded, color: _primary, size: 20),
              SizedBox(width: 8),
              Text('Order Timeline',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 20),
          ...stages.asMap().entries.map((e) {
            final i = e.key;
            final stage = e.value;
            final done = _progress >= (stage['minP'] as double);
            final isCurrent = done &&
                (i == stages.length - 1 ||
                    _progress < (stages[i + 1]['minP'] as double));
            return _stageRow(
              stage['emoji'] as String,
              stage['label'] as String,
              stage['sub'] as String,
              done,
              isCurrent,
              i < stages.length - 1,
            );
          }),
        ],
      ),
    );
  }

  Widget _stageRow(String emoji, String label, String sub, bool done,
      bool isCurrent, bool hasLine) {
    return Column(
      children: [
        Row(
          children: [
            AnimatedBuilder(
              animation: isCurrent ? _pulseAnim : const AlwaysStoppedAnimation(1.0),
              builder: (_, __) => Transform.scale(
                scale: isCurrent ? _pulseAnim.value : 1.0,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: done ? _primary : Colors.grey[100],
                    shape: BoxShape.circle,
                    boxShadow: isCurrent
                        ? [
                            BoxShadow(
                                color: _primary.withValues(alpha: 0.4),
                                blurRadius: 12,
                                spreadRadius: 3),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: Text(emoji,
                        style: TextStyle(fontSize: done ? 20 : 18)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: done ? const Color(0xFF1A1A1A) : Colors.grey[400],
                    ),
                  ),
                  Text(sub,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey[500])),
                ],
              ),
            ),
            if (done)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: isCurrent ? _primaryLight : Colors.green[50],
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isCurrent ? 'Current' : 'Done',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isCurrent ? _primary : Colors.green[700],
                  ),
                ),
              ),
          ],
        ),
        if (hasLine)
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Container(
              width: 2,
              height: 18,
              color: done ? _primary : Colors.grey[200],
            ),
          ),
      ],
    );
  }

  Widget _buildOrderDetailsCard() {
    final order = _orderData!;
    final shop = order['shopName'] ?? order['shop'] ?? 'Restaurant';
    final address = order['address'] ?? order['deliveryAddress'] ?? 'N/A';
    final payment = order['paymentMethod'] ?? 'Cash on Delivery';
    final orderType = (order['type'] ?? 'shop').toString();
    final instructions =
        order['deliveryInstructions'] ?? order['specialInstructions'] ?? '';
    final createdAt = order['createdAt'] ?? order['timestamp'];
    String dateStr = '';
    if (createdAt is int) {
      final dt = DateTime.fromMillisecondsSinceEpoch(createdAt);
      dateStr =
          '${dt.day}-${dt.month}-${dt.year} at ${dt.hour > 12 ? dt.hour - 12 : dt.hour}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? "PM" : "AM"}';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: _primaryLight,
                      borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.receipt_long_rounded,
                      color: _primary, size: 20),
                ),
                const SizedBox(width: 12),
                const Text('Order Details',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _detailRow('??', 'Restaurant', shop),
                _detailRow('??', 'Address', address),
                _detailRow('??', 'Payment', payment),
                _detailRow('???', 'Type',
                    orderType == 'custom' ? 'Custom Order' : 'Shop Order'),
                if (dateStr.isNotEmpty) _detailRow('??', 'Placed On', dateStr),
                if (instructions.isNotEmpty)
                  _detailRow('??', 'Note', instructions),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String emoji, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF1A1A1A),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsCard() {
    final items = _orderData!['items'];
    if (items == null) {
      final what = _orderData!['whatYouWant'];
      if (what == null) return const SizedBox.shrink();
      return _singleItemCard(what.toString());
    }

    List<dynamic> list = [];
    if (items is List) {
      list = items;
    } else if (items is Map<dynamic, dynamic>) {
      list = items.values.toList();
    }
    if (list.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: _primaryLight,
                      borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.fastfood_rounded,
                      color: _primary, size: 20),
                ),
                const SizedBox(width: 12),
                const Text('Items Ordered',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: _primaryLight,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('${list.length} items',
                      style: const TextStyle(
                          fontSize: 11,
                          color: _primary,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
          ...list.take(5).map((item) {
            if (item is! Map) return const SizedBox.shrink();
            return _itemRow(Map<String, dynamic>.from(item));
          }),
          if (list.length > 5)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
              child: Text('+${list.length - 5} more items',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            )
          else
            const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _itemRow(Map<String, dynamic> item) {
    final name = item['name'] ?? 'Item';
    final qty = item['quantity'] ?? 1;
    final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
    final img = item['imageUrl'] ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
                color: _primaryLight,
                borderRadius: BorderRadius.circular(12)),
            child: img.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ImageHelper.networkImage(url: img,
                        fit: BoxFit.cover),
                  )
                : const Icon(Icons.fastfood, color: _primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text('x$qty',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey[500])),
              ],
            ),
          ),
          Text('Rs. ${(price * (qty is int ? qty : 1)).toStringAsFixed(0)}',
              style: const TextStyle(
                  color: _primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
        ],
      ),
    );
  }

  Widget _singleItemCard(String text) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: _primaryLight,
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.fastfood_rounded, color: _primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildBillCard() {
    final order = _orderData!;
    final subtotal = order['subtotal'] ?? order['itemsTotal'] ?? 0;
    final delivery = order['deliveryFee'] ?? order['deliveryCharge'] ?? 50;
    final tax = order['tax'] ?? 0;
    final grand = order['grandTotal'] ??
        order['totalPrice'] ??
        order['budget'] ??
        0;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: _primaryLight,
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.calculate_rounded,
                    color: _primary, size: 20),
              ),
              const SizedBox(width: 12),
              const Text('Bill Summary',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 16),
          _billRow2('Items Total', 'Rs. $subtotal'),
          const SizedBox(height: 8),
          _billRow2('Delivery Fee', 'Rs. $delivery'),
          if ((double.tryParse(tax.toString()) ?? 0) > 0) ...[
            const SizedBox(height: 8),
            _billRow2('Tax (3%)', 'Rs. $tax'),
          ],
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Grand Total',
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
              Text('Rs. $grand',
                  style: const TextStyle(
                      color: _primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 18)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _billRow2(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        Text(value,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildRiderCard() {
    final name = _riderInfo?['name'] ?? 'Muhammad Usman';
    final phone = _riderInfo?['phone'] ?? '+92 300 1234567';
    final bike = _riderInfo?['vehicle'] ?? 'Honda CD 70';
    final rating = _riderInfo?['rating']?.toString() ?? '4.8';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your Rider',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1)),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                child: AnimatedBuilder(
                  animation: _riderAnim,
                  builder: (_, __) => Transform.translate(
                    offset: Offset(sin(_riderAnim.value * 2 * pi) * 3, 0),
                    child: const Icon(Icons.delivery_dining_rounded,
                        color: Colors.white, size: 30),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        )),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded,
                            color: Colors.amber, size: 13),
                        const SizedBox(width: 3),
                        Text(rating,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        const SizedBox(width: 10),
                        const Icon(Icons.motorcycle_rounded,
                            color: Colors.white54, size: 12),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(bike,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  GestureDetector(
                    onTap: () async {
                      if (phone.isNotEmpty) {
                        try {
                          await launchUrl(Uri.parse('tel:$phone'), mode: LaunchMode.externalApplication);
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not launch dialer')));
                        }
                      }
                    },
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4), width: 1.5),
                      ),
                      child: const Icon(Icons.phone_rounded,
                          color: Colors.white, size: 22),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserChatPage(
                            orderId: widget.order['id']?.toString() ?? '',
                            orderType: (widget.order['orderType'] ?? widget.order['type'] ?? '').toString(),
                            orderCode: (widget.order['customOrderId'] ?? widget.order['id'] ?? '').toString(),
                            isRiderChat: true,
                            riderName: name,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4), width: 1.5),
                      ),
                      child: const Icon(Icons.chat_bubble_rounded,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on_rounded,
                    color: Colors.white, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Rider is approaching your delivery address',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: Colors.greenAccent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: Colors.greenAccent.withValues(alpha: 0.7),
                          blurRadius: 8,
                          spreadRadius: 2),
                    ],
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

// -- Custom Painters ----------------------------------------------------------
class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFFE8F4FD),
    );

    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 10;
    final grid = Paint()
      ..color = const Color(0xFFD0E8F8)
      ..strokeWidth = 0.5;

    for (double y = 40; y < size.height; y += 48) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), road);
    }
    for (double x = 40; x < size.width; x += 60) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), road);
    }
    for (double y = 0; y < size.height; y += 10) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (double x = 0; x < size.width; x += 10) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.35, size.height * 0.25, 90, 55),
          const Radius.circular(8)),
      Paint()..color = const Color(0xFFD4EDDA),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.5, size.height * 0.5, 60, 40),
          const Radius.circular(6)),
      Paint()..color = const Color(0xFFFFE0B2),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _RoutePainter extends CustomPainter {
  final double progress;
  final Color primary;

  const _RoutePainter({required this.progress, required this.primary});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final start = Offset(56, size.height - 48);
    final end = Offset(size.width - 56, 48);

    final unTraveled = Paint()
      ..color = Colors.grey[300]!
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final traveled = Paint()
      ..color = primary
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        start.dx + (end.dx - start.dx) * 0.25, start.dy,
        end.dx - (end.dx - start.dx) * 0.25, end.dy,
        end.dx, end.dy,
      );

    canvas.drawPath(path, unTraveled);

    final metrics = path.computeMetrics().toList();
    if (metrics.isNotEmpty) {
      final m = metrics.first;
      final traveledPath = m.extractPath(0, m.length * progress);
      canvas.drawPath(traveledPath, traveled);
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) => old.progress != progress;
}
