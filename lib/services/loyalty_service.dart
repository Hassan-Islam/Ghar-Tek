import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'city_scope_service.dart';

class LoyaltyService {
  static const int pointsPerOrderDelivered = 30;
  static const int pointsPerAd = 5;
  static const int freeDeliveryThreshold = 140;

  final DatabaseReference _database = FirebaseDatabase.instance.ref();

  Future<bool> _isLoyaltyEnabled() async {
    try {
      await CityScopeService.ensureLoaded();
      final snap = await _database
          .child(CityScopeService.tenantPath('settings/app-control'))
          .get();
      if (snap.exists && snap.value is Map) {
        final data = Map<String, dynamic>.from(snap.value as Map);
        return data['loyaltyPointsEnabled'] != false;
      }
    } catch (_) {}
    return true;
  }

  Future<int> getPoints(String userId) async {
    if (userId.isEmpty) return 0;
    try {
      final snap = await _database.child('users/$userId/loyaltyPoints').get();
      if (!snap.exists) return 0;
      final value = snap.value;
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> addPoints(String userId, int points) async {
    if (userId.isEmpty || points <= 0) return;
    try {
      await _database
          .child('users/$userId/loyaltyPoints')
          .runTransaction((current) {
        final currentValue = _toInt(current);
        return Transaction.success(currentValue + points);
      });
    } catch (_) {}
  }

  Future<void> awardOrderPoints({
    required String orderPath,
    required String orderId,
    required String userId,
  }) async {
    if (orderPath.isEmpty || orderId.isEmpty || userId.isEmpty) return;
    if (!await _isLoyaltyEnabled()) return;

    try {
      final orderRef = _database.child(orderPath).child(orderId);
      final snap = await orderRef.get();
      if (!snap.exists || snap.value is! Map) return;

      final data = Map<String, dynamic>.from(snap.value as Map);
      if (data['loyaltyPointsAwarded'] == true) return;

      await orderRef.update({
        'loyaltyPointsAwarded': true,
        'loyaltyPointsAwardedPoints': pointsPerOrderDelivered,
        'loyaltyPointsAwardedAt': DateTime.now().millisecondsSinceEpoch,
      });

      await addPoints(userId, pointsPerOrderDelivered);
    } catch (_) {}
  }

  Future<bool> redeemFreeDelivery(String userId) async {
    if (userId.isEmpty) return false;
    if (!await _isLoyaltyEnabled()) return false;

    try {
      final userRef = _database.child('users/$userId');
      final result = await userRef.runTransaction((current) {
        final data = current is Map
            ? Map<String, dynamic>.from(current)
            : <String, dynamic>{};
        final points = _toInt(data['loyaltyPoints']);
        if (points < freeDeliveryThreshold) {
          return Transaction.abort();
        }
        final credits = _toInt(data['loyaltyFreeDeliveryCredits']);
        data['loyaltyPoints'] = points - freeDeliveryThreshold;
        data['loyaltyFreeDeliveryCredits'] = credits + 1;
        data['loyaltyFreeDeliveryRedeemedAt'] =
            DateTime.now().millisecondsSinceEpoch;
        return Transaction.success(data);
      });

      return result.committed;
    } catch (_) {
      return false;
    }
  }

  Future<void> consumeFreeDeliveryCredit(String userId) async {
    if (userId.isEmpty) return;

    try {
      await _database
          .child('users/$userId/loyaltyFreeDeliveryCredits')
          .runTransaction((current) {
        final credits = _toInt(current);
        if (credits <= 0) {
          return Transaction.success(0);
        }
        return Transaction.success(credits - 1);
      });
    } catch (_) {}
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
