import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../services/city_scope_service.dart';
import '../services/loyalty_service.dart';

class LoyaltyPointsPage extends StatefulWidget {
  const LoyaltyPointsPage({super.key});

  @override
  State<LoyaltyPointsPage> createState() => _LoyaltyPointsPageState();
}

class _LoyaltyPointsPageState extends State<LoyaltyPointsPage> {
  static const Color _primary = Color(0xFFFF6B00);
  static const String _defaultAdMobRewardedAdUnitId =
      'ca-app-pub-6268553487157911/9854686784';

  final LoyaltyService _loyaltyService = LoyaltyService();
  final DatabaseReference _database = FirebaseDatabase.instance.ref();

  int _points = 0;
  int _freeDeliveryCredits = 0;
  bool _loading = true;
  bool _isRedeeming = false;
  bool _loyaltyPointsEnabled = true;

  // Rewarded ad state for loyalty points
  bool _adMobInitialized = false;
  RewardedAd? _rewardedAd;
  bool _rewardedAdLoaded = false;
  bool _isLoadingRewardedAd = false;
  bool _isShowingRewardedAd = false;
  String? _rewardAdError;
  String _adMobRewardedAdUnitId = _defaultAdMobRewardedAdUnitId;

  StreamSubscription<DatabaseEvent>? _userSubscription;
  StreamSubscription<DatabaseEvent>? _appControlSubscription;

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  bool get _isAndroidRewardFlowEnabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    CityScopeService.ensureLoaded();
    _listenUserLoyalty();
    _listenAppControl();
    _initAdMobRewardedAds();
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _appControlSubscription?.cancel();
    _rewardedAd?.dispose();
    super.dispose();
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _listenUserLoyalty() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _points = 0;
          _freeDeliveryCredits = 0;
          _loading = false;
        });
      }
      return;
    }

    _userSubscription?.cancel();
    _userSubscription =
        _database.child('users/${user.uid}').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value is Map
          ? Map<String, dynamic>.from(event.snapshot.value as Map)
          : <String, dynamic>{};
      setState(() {
        _points = _toInt(data['loyaltyPoints']);
        _freeDeliveryCredits = _toInt(data['loyaltyFreeDeliveryCredits']);
        _loading = false;
      });
    });
  }

  Future<void> _listenAppControl() async {
    try {
      await CityScopeService.ensureLoaded();
      _appControlSubscription?.cancel();
      _appControlSubscription = _database
          .child(_tenantPath('settings/app-control'))
          .onValue
          .listen((event) {
        if (!mounted) return;
        if (event.snapshot.exists && event.snapshot.value is Map) {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          final nextAdUnitId = _resolveAdMobRewardedAdUnitId(data);
          final adUnitChanged = nextAdUnitId != _adMobRewardedAdUnitId;
          setState(() {
            _adMobRewardedAdUnitId = nextAdUnitId;
            _loyaltyPointsEnabled = data['loyaltyPointsEnabled'] != false;
          });
          if (adUnitChanged && _adMobInitialized) {
            _loadRewardedAd(forceReload: true);
          }
        } else {
          final adUnitChanged =
              _adMobRewardedAdUnitId != _defaultAdMobRewardedAdUnitId;
          setState(() {
            _adMobRewardedAdUnitId = _defaultAdMobRewardedAdUnitId;
            _loyaltyPointsEnabled = true;
          });
          if (adUnitChanged && _adMobInitialized) {
            _loadRewardedAd(forceReload: true);
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _initAdMobRewardedAds() async {
    if (!_isAndroidRewardFlowEnabled) return;

    try {
      await MobileAds.instance.initialize();
      if (!mounted) return;
      setState(() {
        _adMobInitialized = true;
        _rewardAdError = null;
      });
      _loadRewardedAd(forceReload: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _adMobInitialized = false;
        _rewardedAdLoaded = false;
        _isLoadingRewardedAd = false;
        _rewardAdError = 'Unable to initialize ads on this device.';
      });
    }
  }

  void _loadRewardedAd({bool forceReload = false}) {
    if (!_adMobInitialized || _isLoadingRewardedAd) {
      return;
    }
    if (!forceReload && _rewardedAdLoaded && _rewardedAd != null) {
      return;
    }

    _rewardedAd?.dispose();
    _rewardedAd = null;

    setState(() {
      _isLoadingRewardedAd = true;
      _rewardedAdLoaded = false;
      _rewardAdError = null;
    });

    RewardedAd.load(
      adUnitId: _adMobRewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() {
            _rewardedAd = ad;
            _rewardedAdLoaded = true;
            _isLoadingRewardedAd = false;
            _rewardAdError = null;
          });
        },
        onAdFailedToLoad: (error) {
          if (!mounted) return;
          setState(() {
            _rewardedAd = null;
            _rewardedAdLoaded = false;
            _isLoadingRewardedAd = false;
            _rewardAdError = 'Rewarded ad not available right now.';
          });
        },
      ),
    );
  }

  Future<void> _showRewardedAdForPoints() async {
    if (!_isAndroidRewardFlowEnabled) return;
    if (_isShowingRewardedAd) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final ad = _rewardedAd;
    if (!_rewardedAdLoaded || ad == null) {
      _loadRewardedAd(forceReload: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Loading ad... please try again in a moment.'),
          backgroundColor: Color(0xFFB45309),
        ),
      );
      return;
    }

    setState(() {
      _isShowingRewardedAd = true;
      _rewardedAdLoaded = false;
      _rewardedAd = null;
      _rewardAdError = null;
    });

    var rewardEarned = false;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!mounted) return;
        setState(() {
          _isShowingRewardedAd = false;
          if (!rewardEarned) {
            _rewardAdError = 'Ad closed early. Watch full ad to earn points.';
          }
        });
        _loadRewardedAd(forceReload: true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        if (!mounted) return;
        setState(() {
          _isShowingRewardedAd = false;
          _rewardAdError = 'Ad failed. Please try again.';
        });
        _loadRewardedAd(forceReload: true);
      },
    );

    ad.show(
      onUserEarnedReward: (ad, reward) async {
        rewardEarned = true;
        await _loyaltyService.addPoints(
          user.uid,
          LoyaltyService.pointsPerAd,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You earned 5 loyalty points!'),
            backgroundColor: Colors.green,
          ),
        );
      },
    );
  }

  String _resolveAdMobRewardedAdUnitId(Map<String, dynamic> data) {
    final candidates = <dynamic>[
      data['admobRewardedAdUnitId'],
      data['admobPointsRewardedAdUnitId'],
      data['pointsRewardedAdUnitId'],
      data['rewardedAdUnitId'],
    ];

    for (final candidate in candidates) {
      final value = candidate?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    return _defaultAdMobRewardedAdUnitId;
  }

  Future<void> _redeemFreeDelivery() async {
    if (_isRedeeming) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isRedeeming = true);
    final success = await _loyaltyService.redeemFreeDelivery(user.uid);
    if (!mounted) return;
    setState(() => _isRedeeming = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Free delivery redeemed. Credit added to your account.'
              : 'You need 140 points to redeem free delivery.',
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final threshold = LoyaltyService.freeDeliveryThreshold;
    final progress = threshold <= 0
        ? 0.0
        : (_points / threshold).clamp(0.0, 1.0);
    final pointsLeft = (threshold - _points).clamp(0, threshold);
    final canRedeem = _points >= threshold && _loyaltyPointsEnabled;
    final adBusy = _isShowingRewardedAd || _isLoadingRewardedAd;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7F6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Text(
          'Loyalty Points',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_loyaltyPointsEnabled) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF4F0),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFD6C8)),
                ),
                child: const Text(
                  'Loyalty points are currently disabled by admin.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFFD6C8)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _loading ? 'Your points' : 'Your points: $_points',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: const Color(0xFFF3F4F6),
                      valueColor: const AlwaysStoppedAnimation(_primary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _loading
                        ? 'Loading your rewards...'
                        : canRedeem
                            ? 'You are ready to redeem free delivery.'
                            : 'Earn $pointsLeft more points to redeem free delivery.',
                    style: TextStyle(
                      fontSize: 12,
                      color: canRedeem ? Colors.green[700] : Colors.grey[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Free delivery credits: $_freeDeliveryCredits',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Redeem 140 points for 1 free standard delivery credit.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed:
                          canRedeem && !_isRedeeming ? _redeemFreeDelivery : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        _isRedeeming ? 'Redeeming...' : 'Redeem Free Delivery',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How it works',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '- Earn 30 points for every delivered order.\n'
                    '- Watch an ad to earn 5 points (unlimited).\n'
                    '- Redeem 140 points for 1 free standard delivery.\n'
                    '- Free delivery applies to standard delivery only.\n'
                    '- Points are added after the order is delivered.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Watch an ad for points',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Earn 5 points every time you watch a full rewarded ad.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _loyaltyPointsEnabled
                          ? (adBusy ? null : _showRewardedAdForPoints)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.play_circle_fill_rounded, size: 18),
                      label: Text(adBusy ? 'Loading...' : 'Watch Ad +5'),
                    ),
                  ),
                  if (_rewardAdError != null && _rewardAdError!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _rewardAdError!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
