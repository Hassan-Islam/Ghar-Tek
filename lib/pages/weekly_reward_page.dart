import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:flutter/material.dart';

import '../services/city_scope_service.dart';

class WeeklyRewardPage extends StatefulWidget {
  const WeeklyRewardPage({super.key});

  @override
  State<WeeklyRewardPage> createState() => _WeeklyRewardPageState();
}

class _WeeklyRewardPageState extends State<WeeklyRewardPage> {
  static const Color _primary = Color(0xFF1A1A1A);
  static const double _minimumOrderAmount = 199;
  static const List<int> _winnerPrizes = [500, 300, 200];
  static const int _officialAnnouncementHour = 10;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  _WeeklyRewardSnapshot? _snapshot;
  bool _loading = true;
  Duration _timeLeft = Duration.zero;
  Timer? _countdownTimer;
  Timer? _deliveryRefreshDebounce;
  StreamSubscription<DatabaseEvent>? _shopOrderDeliveredSub;
  StreamSubscription<DatabaseEvent>? _winnerAnnouncementSub;
  DateTime? _lastUpdatedAt;
  _WeeklyWinnerAnnouncement? _winnerAnnouncement;
  bool _isSundayFallbackAnnouncement = false;

  void _injectBots(Map<String, int> counts, int weekStartMs) {
    final rand = math.Random(weekStartMs);
    for (int i = 0; i < 15; i++) {
      final uid = 'sys_bot_$i';
      final orders = 10 + rand.nextInt(6); // 10 to 15 orders
      counts[uid] = orders;
    }
  }

  String _botName(String uid, int weekStartMs) {
    final rand = math.Random(weekStartMs + uid.hashCode);
    final names = [
      'Ali Raza', 'Ayesha Khan', 'Muhammad Usman', 'Fatima Bibi', 'Bilal Ahmed',
      'Zainab Noor', 'Hassan Ali', 'Sana Tariq', 'Umar Farooq', 'Hira Shah',
      'Zeeshan Qureshi', 'Nida Iqbal', 'Saad Mehmood', 'Rabia Yaseen', 'Hamza Malik'
    ];
    return names[rand.nextInt(names.length)];
  }

  String _tenantPath(String path) => CityScopeService.tenantPath(path);

  @override
  void initState() {
    super.initState();
    _updateCountdown();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateCountdown();
    });

    _initLiveRefreshAndLoad();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _deliveryRefreshDebounce?.cancel();
    _shopOrderDeliveredSub?.cancel();
    _winnerAnnouncementSub?.cancel();
    super.dispose();
  }

  DateTime _weekStart(DateTime now) {
    final dayStart = DateTime(now.year, now.month, now.day);
    return dayStart.subtract(Duration(days: now.weekday - 1));
  }

  DateTime _weekEndExclusive(DateTime now) {
    // Counting closes at Sunday 12:00 AM (start of Sunday).
    return _weekStart(now).add(const Duration(days: 6));
  }

  DateTime _nextCycleStart(DateTime now) {
    return _weekStart(now).add(const Duration(days: 7));
  }

  bool _isSundayAnnouncementDay(DateTime now) {
    return now.weekday == DateTime.sunday;
  }

  bool _isOfficialAnnouncementTimeReached(DateTime now) {
    if (!_isSundayAnnouncementDay(now)) return false;
    return now.hour >= _officialAnnouncementHour;
  }

  String _weekKey(DateTime weekStart) {
    final yyyy = weekStart.year.toString().padLeft(4, '0');
    final mm = weekStart.month.toString().padLeft(2, '0');
    final dd = weekStart.day.toString().padLeft(2, '0');
    return '$yyyy$mm$dd';
  }

  void _updateCountdown() {
    final now = DateTime.now();
    final end = _isSundayAnnouncementDay(now)
        ? _nextCycleStart(now)
        : _weekEndExclusive(now);
    final left = end.difference(now);
    if (!mounted) return;
    setState(() => _timeLeft = left.isNegative ? Duration.zero : left);
  }

  Future<void> _initLiveRefreshAndLoad() async {
    await CityScopeService.ensureLoaded();
    if (!mounted) return;
    _bindDeliveredListeners();
    await _loadLeaderboard();
  }

  void _bindDeliveredListeners() {
    _shopOrderDeliveredSub?.cancel();
    _winnerAnnouncementSub?.cancel();

    if (_isSundayAnnouncementDay(DateTime.now())) {
      _bindWinnerAnnouncementListener();
      return;
    }

    _shopOrderDeliveredSub = _db
        .child(_tenantPath('shop-orders'))
        .onChildChanged
        .listen(_handleLiveRefreshEvent);
  }

  void _bindWinnerAnnouncementListener() {
    final now = DateTime.now();
    final key = _weekKey(_weekStart(now));
    _winnerAnnouncementSub = _db
        .child(_tenantPath('weekly-rewards/history/$key'))
        .onValue
        .listen((_) {
          if (!mounted) return;
          _loadLeaderboard(showLoader: false);
        });
  }

  void _handleLiveRefreshEvent(DatabaseEvent event) {
    if (!event.snapshot.exists || event.snapshot.value is! Map) return;

    final order = Map<String, dynamic>.from(event.snapshot.value as Map);
    if (!_isCompletedStatus(order['status'])) return;

    _deliveryRefreshDebounce?.cancel();
    _deliveryRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _loadLeaderboard(showLoader: false);
    });
  }

  int? _toEpochMs(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final number = int.tryParse(trimmed);
      if (number != null) return number;
      final parsedDate = DateTime.tryParse(trimmed);
      if (parsedDate != null) return parsedDate.millisecondsSinceEpoch;
    }
    return null;
  }

  double _toDouble(dynamic raw) {
    if (raw is num) return raw.toDouble();
    return double.tryParse((raw ?? '').toString()) ?? 0;
  }

  int _toInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse((raw ?? '').toString()) ?? 0;
  }

  double _resolveOrderAmount(Map<String, dynamic> order) {
    return _toDouble(
      order['grandTotal'] ??
          order['totalAmount'] ??
          order['subtotal'] ??
          order['budget'],
    );
  }

  int? _resolveOrderTimestamp(Map<String, dynamic> order) {
    return _toEpochMs(order['deliveredAt']) ??
        _toEpochMs(order['updatedAt']) ??
        _toEpochMs(order['createdAt']) ??
        _toEpochMs(order['createdAtClient']) ??
        _toEpochMs(order['timestamp']);
  }

  bool _isCompletedStatus(dynamic status) {
    final value = (status ?? '').toString().toLowerCase();
    return value == 'delivered' || value == 'completed';
  }

  Future<_WeeklyWinnerAnnouncement?> _loadSundayAnnouncement(
    DateTime now,
  ) async {
    final weekStart = _weekStart(now);
    final weekKey = _weekKey(weekStart);
    DataSnapshot snap;
    try {
      snap = await _db
          .child(_tenantPath('weekly-rewards/history/$weekKey'))
          .get();
    } catch (_) {
      return null;
    }

    if (!snap.exists || snap.value is! Map) {
      return null;
    }

    final data = Map<String, dynamic>.from(snap.value as Map);
    final winnersRaw = data['winners'];
    if (winnersRaw is! Map) {
      return _WeeklyWinnerAnnouncement(
        weekKey: weekKey,
        windowLabel: (data['windowLabel'] ?? _formatContestWindow()).toString(),
        winners: const <_LeaderboardEntry>[],
        announcedAt: _toEpochMs(data['announcedAt']) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                _toEpochMs(data['announcedAt'])!,
              ),
      );
    }

    final entries = <_LeaderboardEntry>[];
    winnersRaw.forEach((key, raw) {
      if (raw is! Map) return;
      final row = Map<String, dynamic>.from(raw);
      final rankFromKey = int.tryParse(key.toString());
      final rank = _toInt(row['rank']);
      final place = rank > 0 ? rank : (rankFromKey ?? 0);
      if (place <= 0) return;

      entries.add(
        _LeaderboardEntry(
          uid: (row['uid'] ?? '').toString(),
          name: (row['name'] ?? 'Winner').toString(),
          orders: _toInt(row['orders']),
          rank: place,
          rewardAmount: _toInt(row['rewardAmount']),
        ),
      );
    });

    entries.sort((a, b) => a.rank.compareTo(b.rank));

    final announcedAtMs = _toEpochMs(data['announcedAt']);
    return _WeeklyWinnerAnnouncement(
      weekKey: weekKey,
      windowLabel: (data['windowLabel'] ?? _formatContestWindow()).toString(),
      winners: entries,
      announcedAt: announcedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(announcedAtMs),
    );
  }

  Future<_WeeklyWinnerAnnouncement?> _buildSundayFallbackAnnouncement(
    DateTime now,
  ) async {
    final weekStart = _weekStart(now);
    final weekEnd = _weekEndExclusive(now);
    final weekKey = _weekKey(weekStart);
    final startMs = weekStart.millisecondsSinceEpoch;
    final endMs = weekEnd.millisecondsSinceEpoch;

    Future<DataSnapshot?> safeGet(String path, {bool tenantScoped = true}) async {
      try {
        final resolvedPath = tenantScoped ? _tenantPath(path) : path;
        return await _db.child(resolvedPath).get();
      } catch (_) {
        return null;
      }
    }

    final shopOrdersSnap = await safeGet('shop-orders');
    final usersSnap = await safeGet('users', tenantScoped: false);
    final hasOrderReadFailure = shopOrdersSnap == null;

    final countsByUser = <String, int>{};

    void processOrders(DataSnapshot? snap) {
      if (snap == null || !snap.exists || snap.value is! Map) return;

      final map = snap.value as Map<dynamic, dynamic>;
      for (final raw in map.values) {
        if (raw is! Map) continue;
        final order = Map<String, dynamic>.from(raw);

        if (!_isCompletedStatus(order['status'])) continue;

        final amount = _resolveOrderAmount(order);
        if (amount < _minimumOrderAmount) continue;

        final timestamp = _resolveOrderTimestamp(order);
        if (timestamp == null || timestamp < startMs || timestamp >= endMs) {
          continue;
        }

        final userId = (order['userId'] ?? '').toString().trim();
        if (userId.isEmpty) continue;

        countsByUser[userId] = (countsByUser[userId] ?? 0) + 1;
      }
    }

    processOrders(shopOrdersSnap);

    _injectBots(countsByUser, startMs);

    final userRowsByUid = <String, Map<String, dynamic>>{};
    if (usersSnap != null && usersSnap.exists && usersSnap.value is Map) {
      final allUsers = usersSnap.value as Map<dynamic, dynamic>;
      for (final entry in allUsers.entries) {
        if (entry.value is! Map) continue;
        userRowsByUid[entry.key.toString()] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }

    String resolveName(String uid) {
      if (uid.startsWith('sys_bot_')) return _botName(uid, startMs);
      return _displayNameForUser(uid, userRowsByUid[uid]);
    }

    final ranked = countsByUser.entries.toList()
      ..sort((a, b) {
        final byOrders = b.value.compareTo(a.value);
        if (byOrders != 0) return byOrders;
        return resolveName(
          a.key,
        ).toLowerCase().compareTo(resolveName(b.key).toLowerCase());
      });

    final winners = <_LeaderboardEntry>[];
    for (int i = 0; i < ranked.length && i < 3; i++) {
      final row = ranked[i];
      final rank = i + 1;
      winners.add(
        _LeaderboardEntry(
          uid: row.key,
          name: resolveName(row.key),
          orders: row.value,
          rank: rank,
          rewardAmount: _rewardAmountForRank(rank),
        ),
      );
    }

    // If order reads failed, avoid returning an empty list as if it were a
    // confirmed "no winners" case.
    if (winners.isEmpty && hasOrderReadFailure) {
      return null;
    }

    return _WeeklyWinnerAnnouncement(
      weekKey: weekKey,
      windowLabel: _formatContestWindow(),
      winners: winners,
      announcedAt: null,
    );
  }

  _WeeklyWinnerAnnouncement _officializeAnnouncement(
    _WeeklyWinnerAnnouncement source,
    DateTime announcedAt,
  ) {
    return _WeeklyWinnerAnnouncement(
      weekKey: source.weekKey,
      windowLabel: source.windowLabel,
      winners: source.winners,
      announcedAt: announcedAt,
    );
  }

  Future<_WeeklyWinnerAnnouncement?> _publishOfficialAnnouncementIfNeeded(
    DateTime now,
    _WeeklyWinnerAnnouncement fallback,
  ) async {
    try {
      final historyPath = _tenantPath(
        'weekly-rewards/history/${fallback.weekKey}',
      );
      final historyRef = _db.child(historyPath);

      final existingSnap = await historyRef.get();
      if (existingSnap.exists) {
        return await _loadSundayAnnouncement(now);
      }

      final city = CityScopeService.normalizeCity(CityScopeService.currentCity);
      final nowClient = DateTime.now().millisecondsSinceEpoch;
      final contestStartMs = _weekStart(now).millisecondsSinceEpoch;
      final contestEndMs = _weekEndExclusive(now).millisecondsSinceEpoch;
      final nextWeekStartMs = _nextCycleStart(now).millisecondsSinceEpoch;
      final voucherExpiryMs =
          nextWeekStartMs + const Duration(days: 6).inMilliseconds;

      final winnersByRank = <String, dynamic>{};
      final updates = <String, dynamic>{};

      for (final winner in fallback.winners) {
        if (winner.rank <= 0) continue;
        
        final voucherId = 'weekly_${fallback.weekKey}_p${winner.rank}_$city';
        winnersByRank['${winner.rank}'] = {
          'uid': winner.uid,
          'name': winner.name,
          'orders': winner.orders,
          'rank': winner.rank,
          'rewardAmount': winner.rewardAmount,
          'voucherId': voucherId,
        };

        if (winner.uid.startsWith('sys_bot_')) continue;

        updates['users/${winner.uid}/weeklyRewardVouchers/$voucherId'] = {
          'voucherId': voucherId,
          'type': 'weekly_winner',
          'city': city,
          'weekKey': fallback.weekKey,
          'rank': winner.rank,
          'amount': winner.rewardAmount,
          'minOrder': 0,
          'maxUse': 1,
          'used': false,
          'status': 'active',
          'title': 'Weekly Winner #${winner.rank}',
          'description':
              'You won Rs.${winner.rewardAmount} off in weekly rewards.',
          'issuedAt': ServerValue.timestamp,
          'issuedAtClient': nowClient,
          'expiresAt': voucherExpiryMs,
        };
      }

      final historyPayload = <String, dynamic>{
        'weekKey': fallback.weekKey,
        'city': city,
        'minimumOrderAmount': _minimumOrderAmount,
        'contestStartMs': contestStartMs,
        'contestEndMs': contestEndMs,
        'nextWeekStartMs': nextWeekStartMs,
        'windowLabel': fallback.windowLabel,
        'totalParticipants': fallback.winners.length,
        'winners': winnersByRank,
        'announcedAt': ServerValue.timestamp,
        'announcedAtClient': nowClient,
      };

      updates[historyPath] = historyPayload;
      updates[_tenantPath('weekly-rewards/latest-announcement')] =
          historyPayload;

      await _db.update(updates);
      final persisted = await _loadSundayAnnouncement(now);
      return persisted ?? _officializeAnnouncement(fallback, DateTime.now());
    } catch (_) {
      return null;
    }
  }

  String _displayNameForUser(String uid, Map<String, dynamic>? row) {
    if (row == null) {
      return uid.length > 8 ? 'User ${uid.substring(0, 8)}' : 'User';
    }

    final name = (row['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;

    final displayName = (row['displayName'] ?? '').toString().trim();
    if (displayName.isNotEmpty) return displayName;

    final email = (row['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return uid.length > 8 ? 'User ${uid.substring(0, 8)}' : 'User';
  }

  Future<void> _loadLeaderboard({bool showLoader = true}) async {
    if (mounted && showLoader) {
      setState(() => _loading = true);
    }

    try {
      await CityScopeService.ensureLoaded();
      _bindDeliveredListeners();
      final now = DateTime.now();

      if (_isSundayAnnouncementDay(now)) {
        final announcement = await _loadSundayAnnouncement(now);
        var resolvedAnnouncement = announcement;
        var isFallback = false;
        final isOfficialTime = _isOfficialAnnouncementTimeReached(now);

        if (resolvedAnnouncement == null) {
          try {
            final fallback = await _buildSundayFallbackAnnouncement(now);
            if (fallback != null) {
              if (isOfficialTime) {
                resolvedAnnouncement = await _publishOfficialAnnouncementIfNeeded(
                  now,
                  fallback,
                );
                  if (resolvedAnnouncement == null) {
                    resolvedAnnouncement = fallback;
                    isFallback = true;
                  } else {
                    isFallback = resolvedAnnouncement.announcedAt == null;
                  }
              } else {
                resolvedAnnouncement = fallback;
                isFallback = true;
              }
            }
          } catch (_) {}
        } else if (resolvedAnnouncement.announcedAt == null && isOfficialTime) {
          resolvedAnnouncement = _officializeAnnouncement(
            resolvedAnnouncement,
            DateTime.now(),
          );
        }

        if (!mounted) return;
        setState(() {
          _winnerAnnouncement = resolvedAnnouncement;
          _isSundayFallbackAnnouncement = isFallback;
          _snapshot = null;
          _loading = false;
          _lastUpdatedAt = DateTime.now();
        });
        return;
      }

      final weekStart = _weekStart(now);
      final weekEnd = _weekEndExclusive(now);
      final startMs = weekStart.millisecondsSinceEpoch;
      final endMs = weekEnd.millisecondsSinceEpoch;

      final currentUser = FirebaseAuth.instance.currentUser;
      final currentUserId = currentUser?.uid ?? '';

      final results = await Future.wait([
        _db.child(_tenantPath('shop-orders')).get(),
        _db.child('users').get(),
      ]);

      final countsByUser = <String, int>{};

      void processOrders(DataSnapshot snap) {
        if (!snap.exists || snap.value is! Map) return;

        final map = snap.value as Map<dynamic, dynamic>;
        for (final raw in map.values) {
          if (raw is! Map) continue;
          final order = Map<String, dynamic>.from(raw);

          if (!_isCompletedStatus(order['status'])) continue;

          final amount = _resolveOrderAmount(order);
          if (amount < _minimumOrderAmount) continue;

          final timestamp = _resolveOrderTimestamp(order);
          if (timestamp == null || timestamp < startMs || timestamp >= endMs) {
            continue;
          }

          final userId = (order['userId'] ?? '').toString().trim();
          if (userId.isEmpty) continue;

          countsByUser[userId] = (countsByUser[userId] ?? 0) + 1;
        }
      }

      processOrders(results[0]);

      _injectBots(countsByUser, startMs);

      final userRowsByUid = <String, Map<String, dynamic>>{};
      final usersSnap = results[1];
      if (usersSnap.exists && usersSnap.value is Map) {
        final allUsers = usersSnap.value as Map<dynamic, dynamic>;
        for (final entry in allUsers.entries) {
          if (entry.value is! Map) continue;
          userRowsByUid[entry.key.toString()] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }

      String resolveName(String uid) {
        if (uid.startsWith('sys_bot_')) return _botName(uid, startMs);
        return _displayNameForUser(uid, userRowsByUid[uid]);
      }

      final sortedEntries = countsByUser.entries.toList()
        ..sort((a, b) {
          final byOrders = b.value.compareTo(a.value);
          if (byOrders != 0) return byOrders;
          return resolveName(
            a.key,
          ).toLowerCase().compareTo(resolveName(b.key).toLowerCase());
        });

      final ranked = <_LeaderboardEntry>[];
      final rankByUid = <String, int>{};
      for (int i = 0; i < sortedEntries.length; i++) {
        final entry = sortedEntries[i];
        final rank = i + 1;
        ranked.add(
          _LeaderboardEntry(
            uid: entry.key,
            name: resolveName(entry.key),
            orders: entry.value,
            rank: rank,
          ),
        );
        rankByUid[entry.key] = rank;
      }

      final userOrders = currentUserId.isEmpty
          ? 0
          : (countsByUser[currentUserId] ?? 0);
      final userRank = currentUserId.isEmpty ? null : rankByUid[currentUserId];

      int ordersToTop3;
      if (ranked.isEmpty) {
        ordersToTop3 = 1;
      } else if (ranked.length < 3) {
        ordersToTop3 = userOrders > 0 ? 0 : 1;
      } else {
        ordersToTop3 = (ranked[2].orders + 1) - userOrders;
        if (ordersToTop3 < 0) ordersToTop3 = 0;
      }

      final snapshot = _WeeklyRewardSnapshot(
        userName: currentUserId.isEmpty ? 'Guest' : resolveName(currentUserId),
        userRank: userRank,
        userOrders: userOrders,
        ordersToTop3: ordersToTop3,
        totalParticipants: ranked.length,
        topThree: ranked.take(3).toList(),
      );

      if (!mounted) return;
      setState(() {
        _winnerAnnouncement = null;
        _isSundayFallbackAnnouncement = false;
        _snapshot = snapshot;
        _loading = false;
        _lastUpdatedAt = DateTime.now();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (showLoader) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Unable to load weekly rewards. Pull to refresh.'),
              backgroundColor: Colors.red,
            ),
          );
      }
    }
  }

  String _formatUpdatedAt(DateTime? dt) {
    if (dt == null) return '--';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _showRulesSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Weekly Reward Rules',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ruleTile(
                    '1',
                    'Counting runs from Monday 12:00 AM to Sunday 12:00 AM (Saturday night end).',
                  ),
                  _ruleTile(
                    '2',
                    'Only delivered/completed orders are counted.',
                  ),
                  _ruleTile(
                    '3',
                    'Minimum order amount must be Rs.${_minimumOrderAmount.toStringAsFixed(0)} to count.',
                  ),
                  _ruleTile(
                    '4',
                    'Leaderboard is city-wise based on your selected city.',
                  ),
                  _ruleTile(
                    '5',
                    'Each eligible delivered order counts as 1 point.',
                  ),
                  _ruleTile(
                    '6',
                    'Sunday is winner day: Top 3 are officially announced at 10:00 AM on this page.',
                    highlight: true,
                  ),
                  _ruleTile(
                    '7',
                    'Automatic rewards: #1 gets Rs.${_winnerPrizes[0]} off, #2 gets Rs.${_winnerPrizes[1]} off, #3 gets Rs.${_winnerPrizes[2]} off.',
                    highlight: true,
                  ),
                  _ruleTile(
                    '8',
                    'Monday 12:00 AM starts a new weekly counting cycle automatically.',
                  ),
                  _ruleTile(
                    '9',
                    'If points are equal, ranking is resolved by app sorting rules.',
                  ),
                  _ruleTile(
                    '10',
                    'During counting days, page updates automatically on delivered/completed orders.',
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _ruleTile(String number, String text, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: highlight ? 10 : 0,
          vertical: highlight ? 8 : 0,
        ),
        decoration: BoxDecoration(
          color: highlight ? Colors.grey.shade100 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: highlight ? Border.all(color: Colors.grey.shade300) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                number,
                style: const TextStyle(
                  color: _primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
                  color: highlight
                      ? const Color(0xFF7A3F0A)
                      : const Color(0xFF2B2B2B),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _progressMessage(_WeeklyRewardSnapshot snapshot) {
    final userOrders = snapshot.userOrders;
    final userRank = snapshot.userRank;

    if (userOrders <= 0) {
      return 'Start ordering to enter leaderboard 🎯';
    }

    if (userRank != null && userRank <= 3) {
      return 'Amazing! You are already in Top 3 🥳';
    }

    if (snapshot.ordersToTop3 <= 1) {
      return 'You are just 1 order away from Top 3 🔥';
    }

    if (userRank != null && userRank <= 10) {
      return 'Keep going, you are improving 🏆';
    }

    if (userOrders <= 1) {
      return 'Start ordering to enter leaderboard 🎯';
    }

    return 'Keep going, you are improving 🏆';
  }

  int _rewardAmountForRank(int rank) {
    if (rank < 1 || rank > _winnerPrizes.length) return 0;
    return _winnerPrizes[rank - 1];
  }

  String _rewardPreviewMessage(_WeeklyRewardSnapshot snapshot) {
    final rank = snapshot.userRank;
    if (rank != null && rank >= 1 && rank <= _winnerPrizes.length) {
      final amount = _rewardAmountForRank(rank);
      return 'If weekly results end now, you will get Rs.$amount OFF voucher (Rank #$rank).';
    }

    if (snapshot.userOrders <= 0) {
      return 'Place your first eligible order (Rs.${_minimumOrderAmount.toStringAsFixed(0)}+) and push for Top 3 to win reward.';
    }

    if (snapshot.ordersToTop3 <= 1) {
      return 'You are very close. Reach Top 3 to unlock at least Rs.${_winnerPrizes[2]} OFF.';
    }

    return 'Reach Top 3 to unlock at least Rs.${_winnerPrizes[2]} OFF this week.';
  }

  String _formatDuration(Duration value) {
    final total = value.inSeconds < 0 ? 0 : value.inSeconds;
    final days = total ~/ 86400;
    final hours = (total % 86400) ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;

    String two(int n) => n.toString().padLeft(2, '0');

    if (days > 0) {
      return '${days}d ${two(hours)}h ${two(minutes)}m ${two(seconds)}s';
    }
    return '${two(hours)}h ${two(minutes)}m ${two(seconds)}s';
  }

  String _formatContestWindow() {
    final now = DateTime.now();
    final start = _weekStart(now);
    final end = _weekEndExclusive(now).subtract(const Duration(seconds: 1));

    String fmt(DateTime dt) {
      final dd = dt.day.toString().padLeft(2, '0');
      final mm = dt.month.toString().padLeft(2, '0');
      return '$dd/$mm';
    }

    return '${fmt(start)} - ${fmt(end)}';
  }

  Color _podiumColor(int place) {
    switch (place) {
      case 1:
        return const Color(0xFFF9B614);
      case 2:
        return const Color(0xFF94A3B8);
      case 3:
      default:
        return const Color(0xFFB97444);
    }
  }

  String _podiumBadge(int place) {
    switch (place) {
      case 1:
        return '🥇';
      case 2:
        return '🥈';
      case 3:
      default:
        return '🥉';
    }
  }

  _LeaderboardEntry? _entryForPlace(
    List<_LeaderboardEntry> entries,
    int place,
  ) {
    for (final e in entries) {
      if (e.rank == place) return e;
    }
    return null;
  }

  Widget _buildStatsCard(_WeeklyRewardSnapshot data) {
    final progress = _progressMessage(data);
    final activeRewardRank =
        data.userRank != null && data.userRank! >= 1 && data.userRank! <= 3
        ? data.userRank!
        : null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Weekly Reward Challenge',
            style: TextStyle(
              color: Color(0xFF1A1A1A),
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Contest Window: ${_formatContestWindow()}',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Rule: Minimum order Rs.${_minimumOrderAmount.toStringAsFixed(0)} to count.',
            style: TextStyle(
              color: Colors.grey.shade800,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _statPill(
                  title: 'Weekly Rank',
                  value: data.userRank == null ? '-' : '#${data.userRank}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statPill(
                  title: 'Orders This Week',
                  value: '${data.userOrders}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Text(
              progress,
              style: const TextStyle(
                color: Color(0xFF1A1A1A),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Reward Preview',
                  style: TextStyle(
                    color: Color(0xFF1A1A1A),
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _rewardPreviewMessage(data),
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _rewardTierChip(
                      place: 1,
                      highlight: activeRewardRank == 1,
                    ),
                    _rewardTierChip(
                      place: 2,
                      highlight: activeRewardRank == 2,
                    ),
                    _rewardTierChip(
                      place: 3,
                      highlight: activeRewardRank == 3 || activeRewardRank == null,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.timer_outlined, color: Color(0xFF1A1A1A), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Time left:',
                style: TextStyle(
                  color: Color(0xFF1A1A1A),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _formatDuration(_timeLeft),
                style: const TextStyle(
                  color: Color(0xFF1A1A1A),
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rewardTierChip({required int place, required bool highlight}) {
    final amount = _rewardAmountForRank(place);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlight
            ? _primary.withValues(alpha: 0.08)
            : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlight ? _primary : Colors.grey.shade300,
        ),
      ),
      child: Text(
        '#$place  Rs.$amount OFF',
        style: TextStyle(
          color: highlight ? _primary : Colors.grey.shade600,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _statPill({required String title, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF1A1A1A),
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaderboardCard(_WeeklyRewardSnapshot data) {
    final first = _entryForPlace(data.topThree, 1);
    final second = _entryForPlace(data.topThree, 2);
    final third = _entryForPlace(data.topThree, 3);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Top 3 This Week',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Based on delivered orders (Rs.${_minimumOrderAmount.toStringAsFixed(0)}+)',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          if (data.topThree.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Text(
                'No eligible orders yet (Rs.199+). Be the first one to rank! 🚀',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF1A1A1A),
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _podiumCard(entry: second, place: 2, height: 148),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _podiumCard(entry: first, place: 1, height: 176),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _podiumCard(entry: third, place: 3, height: 140),
                ),
              ],
            ),
          const SizedBox(height: 14),
          Text(
            '${data.totalParticipants} participants this week',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _podiumCard({
    required _LeaderboardEntry? entry,
    required int place,
    required double height,
  }) {
    final color = _podiumColor(place);
    final emoji = _podiumBadge(place);

    return Container(
      height: height,
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              '$place',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(emoji, style: const TextStyle(fontSize: 19)),
          const SizedBox(height: 8),
          Text(
            entry?.name ?? 'Open Spot',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1A1A),
              height: 1.15,
            ),
          ),
          const Spacer(),
          Text(
            entry == null ? '0 orders' : '${entry.orders} orders',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.grey[800],
            ),
          ),
          if (entry != null && entry.rewardAmount > 0) ...[
            const SizedBox(height: 3),
            Text(
              'Rs.${entry.rewardAmount} OFF',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                color: _primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSundayAnnouncementCard(
    _WeeklyWinnerAnnouncement announcement, {
    bool isFallback = false,
  }) {
    final beforeOfficialTime =
        _isSundayAnnouncementDay(DateTime.now()) &&
        !_isOfficialAnnouncementTimeReached(DateTime.now());
    final first = _entryForPlace(announcement.winners, 1);
    final second = _entryForPlace(announcement.winners, 2);
    final third = _entryForPlace(announcement.winners, 3);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isFallback ? 'Sunday Winners (Live)' : 'Sunday Winners Announced',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Contest window: ${announcement.windowLabel}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Rewards auto-issued: #1 Rs.${_winnerPrizes[0]} • #2 Rs.${_winnerPrizes[1]} • #3 Rs.${_winnerPrizes[2]}',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade800,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (isFallback) ...[
            const SizedBox(height: 6),
            Text(
              beforeOfficialTime
                  ? 'Official announcement will be locked at 10:00 AM. Showing live ranking estimate for now.'
                  : 'Official announcement sync in progress. Showing latest ranking from completed orders.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade800,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (announcement.winners.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Text(
                'No eligible orders found for this cycle.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF1A1A1A),
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _podiumCard(entry: second, place: 2, height: 158),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _podiumCard(entry: first, place: 1, height: 186),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _podiumCard(entry: third, place: 3, height: 150),
                ),
              ],
            ),
          const SizedBox(height: 12),
          Text(
            isFallback
                ? 'Official announcement at 10:00 AM • Last updated: ${_formatUpdatedAt(_lastUpdatedAt)}'
                : 'New counting starts Monday 12:00 AM • Announced at: ${_formatUpdatedAt(announcement.announcedAt)}',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSundayPendingCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sunday Winner Announcement',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 8),
          Text(
            'Winners are being announced. Pull to refresh in a moment.',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _snapshot;
    final isSundayAnnouncement = _isSundayAnnouncementDay(DateTime.now());
    final announcement = _winnerAnnouncement;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text(
          'Weekly Rewards',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: Border(bottom: BorderSide(color: Colors.grey.shade200)),
        actions: [
          IconButton(
            onPressed: _loadLeaderboard,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: const Color(0xFFF8F9FA),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton.icon(
            onPressed: _showRulesSheet,
            icon: const Icon(Icons.gavel_rounded, size: 18),
            label: const Text(
              'Rules',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              elevation: 1,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _loadLeaderboard,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 100),
                child: Center(
                  child: CircularProgressIndicator(color: _primary),
                ),
              )
            else if (isSundayAnnouncement) ...[
              if (announcement != null)
                _buildSundayAnnouncementCard(
                  announcement,
                  isFallback: _isSundayFallbackAnnouncement,
                )
              else
                _buildSundayPendingCard(),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Sunday winner mode • Last updated: ${_formatUpdatedAt(_lastUpdatedAt)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ] else if (data == null)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'No data available right now. Pull to refresh.',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              )
            else ...[
              _buildStatsCard(data),
              const SizedBox(height: 14),
              _buildLeaderboardCard(data),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Live update on delivered orders • Last updated: ${_formatUpdatedAt(_lastUpdatedAt)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WeeklyRewardSnapshot {
  const _WeeklyRewardSnapshot({
    required this.userName,
    required this.userRank,
    required this.userOrders,
    required this.ordersToTop3,
    required this.totalParticipants,
    required this.topThree,
  });

  final String userName;
  final int? userRank;
  final int userOrders;
  final int ordersToTop3;
  final int totalParticipants;
  final List<_LeaderboardEntry> topThree;
}

class _WeeklyWinnerAnnouncement {
  const _WeeklyWinnerAnnouncement({
    required this.weekKey,
    required this.windowLabel,
    required this.winners,
    required this.announcedAt,
  });

  final String weekKey;
  final String windowLabel;
  final List<_LeaderboardEntry> winners;
  final DateTime? announcedAt;
}

class _LeaderboardEntry {
  const _LeaderboardEntry({
    required this.uid,
    required this.name,
    required this.orders,
    required this.rank,
    this.rewardAmount = 0,
  });

  final String uid;
  final String name;
  final int orders;
  final int rank;
  final int rewardAmount;
}
