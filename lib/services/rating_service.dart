import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'city_scope_service.dart';

class RatingService {
  static final RatingService _instance = RatingService._internal();
  factory RatingService() => _instance;
  RatingService._internal();

  final FirebaseDatabase _primaryDb = FirebaseDatabase.instance;
  
  FirebaseDatabase get _ratingsDb {
    try {
      return FirebaseDatabase.instanceFor(app: Firebase.app('ratingsApp'));
    } catch (e) {
      // Fallback if not initialized for some reason
      return FirebaseDatabase.instance;
    }
  }

  Future<void> submitShopRating({
    required String shopId,
    required double rating,
    required String comment,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('User not logged in');
    
    await CityScopeService.ensureLoaded();
    final cityKey = CityScopeService.normalizeCityKey(CityScopeService.currentCity);
    final tenantPath = 'tenants/$cityKey';

    // 1. Save individual rating
    final ratingData = {
      'rating': rating,
      'comment': comment,
      'timestamp': ServerValue.timestamp,
      'userId': user.uid,
      'userName': user.displayName ?? 'Anonymous',
    };

    await _ratingsDb
        .ref('$tenantPath/ratings/shops/$shopId/${user.uid}')
        .set(ratingData);

    // 2. Recalculate average and count
    final snapshot = await _ratingsDb.ref('$tenantPath/ratings/shops/$shopId').get();
    
    if (snapshot.exists && snapshot.value != null) {
      final ratingsMap = Map<dynamic, dynamic>.from(snapshot.value as Map);
      double totalRating = 0.0;
      int count = 0;
      
      ratingsMap.forEach((key, value) {
        final r = Map<String, dynamic>.from(value);
        final rVal = (r['rating'] as num?)?.toDouble() ?? 0.0;
        totalRating += rVal;
        count++;
      });
      
      final averageRating = count > 0 ? (totalRating / count) : 0.0;
      final formattedRating = averageRating.toStringAsFixed(1);

      // 3. Update shop node
      await _primaryDb.ref('$tenantPath/shops/$shopId').update({
        'rating': formattedRating,
        'ratingCount': count,
      });
    }
  }

  Future<void> submitProductRating({
    required String shopId,
    required String productId,
    required double rating,
    required String comment,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('User not logged in');
    
    await CityScopeService.ensureLoaded();
    final cityKey = CityScopeService.normalizeCityKey(CityScopeService.currentCity);
    final tenantPath = 'tenants/$cityKey';

    // 1. Save individual rating
    final ratingData = {
      'rating': rating,
      'comment': comment,
      'timestamp': ServerValue.timestamp,
      'userId': user.uid,
      'userName': user.displayName ?? 'Anonymous',
    };

    await _ratingsDb
        .ref('$tenantPath/ratings/products/$shopId/$productId/${user.uid}')
        .set(ratingData);

    // 2. Recalculate average and count
    final snapshot = await _ratingsDb.ref('$tenantPath/ratings/products/$shopId/$productId').get();
    
    if (snapshot.exists && snapshot.value != null) {
      final ratingsMap = Map<dynamic, dynamic>.from(snapshot.value as Map);
      double totalRating = 0.0;
      int count = 0;
      
      ratingsMap.forEach((key, value) {
        final r = Map<String, dynamic>.from(value);
        final rVal = (r['rating'] as num?)?.toDouble() ?? 0.0;
        totalRating += rVal;
        count++;
      });
      
      final averageRating = count > 0 ? (totalRating / count) : 0.0;
      final formattedRating = averageRating.toStringAsFixed(1);

      // 3. Update product node in shop's menu
      await _primaryDb.ref('$tenantPath/shops/$shopId/menu/$productId').update({
        'rating': formattedRating,
        'ratingCount': count,
      });
    }
  }

  Future<void> submitOrderRating({
    required String orderId,
    required String shopId,
    required int foodRating,
    required int packagingRating,
    required int riderRating,
    required String comment,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('User not logged in');

    await CityScopeService.ensureLoaded();
    final cityKey = CityScopeService.normalizeCityKey(CityScopeService.currentCity);
    final tenantPath = 'tenants/$cityKey';

    final ratingData = {
      'foodRating': foodRating,
      'packagingRating': packagingRating,
      'riderRating': riderRating,
      'comment': comment,
      'timestamp': ServerValue.timestamp,
      'userId': user.uid,
      'userName': user.displayName ?? 'Anonymous',
      'shopId': shopId,
    };

    // 1. Save to dedicated order ratings path
    await _ratingsDb.ref('$tenantPath/ratings/orders/$orderId').set(ratingData);

    // 2. Mark order as rated
    await _primaryDb.ref('$tenantPath/orders/${user.uid}/$orderId/isRated').set(true);
    await _primaryDb.ref('$tenantPath/shopOrders/$shopId/$orderId/isRated').set(true);

    // 3. Update shop rating (using foodRating as the shop rating)
    // We overwrite the user's previous shop rating, just like submitShopRating does
    final shopRatingData = {
      'rating': foodRating.toDouble(),
      'comment': comment,
      'timestamp': ServerValue.timestamp,
      'userId': user.uid,
      'userName': user.displayName ?? 'Anonymous',
    };
    
    await _ratingsDb.ref('$tenantPath/ratings/shops/$shopId/${user.uid}').set(shopRatingData);

    // 4. Recalculate average shop rating
    final snapshot = await _ratingsDb.ref('$tenantPath/ratings/shops/$shopId').get();
    if (snapshot.exists && snapshot.value != null) {
      final ratingsMap = Map<dynamic, dynamic>.from(snapshot.value as Map);
      double totalRating = 0.0;
      int count = 0;
      
      ratingsMap.forEach((key, value) {
        final r = Map<String, dynamic>.from(value);
        final rVal = (r['rating'] as num?)?.toDouble() ?? 0.0;
        totalRating += rVal;
        count++;
      });
      
      final averageRating = count > 0 ? (totalRating / count) : 0.0;
      final formattedRating = averageRating.toStringAsFixed(1);

      await _primaryDb.ref('$tenantPath/shops/$shopId').update({
        'rating': formattedRating,
        'ratingCount': count,
      });
    }
  }
}
