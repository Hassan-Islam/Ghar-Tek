import 'package:mixpanel_flutter/mixpanel_flutter.dart';
import 'package:flutter/foundation.dart';

import '../config/app_env.dart';

class AnalyticsService {
  static Mixpanel? _mixpanel;
  static DateTime? _sessionStartTime;

  static Future<void> init() async {
    if (_mixpanel != null) return;
    try {
      _mixpanel = await Mixpanel.init(
        AppEnv.mixpanelToken,
        trackAutomaticEvents: true,
        optOutTrackingDefault: false,
      );
    } catch (e) {
      debugPrint('Mixpanel init error: $e');
    }
  }

  static void identifyUser(String uid, {String? name, String? email, String? city}) {
    if (_mixpanel == null) return;
    _mixpanel!.identify(uid);
    
    final props = <String, dynamic>{};
    if (name != null) props['\$name'] = name;
    if (email != null) props['\$email'] = email;
    if (city != null) props['City'] = city;
    
    if (props.isNotEmpty) {
      props.forEach((key, value) {
        _mixpanel!.getPeople().set(key, value);
      });
    }
  }

  static void appOpen() {
    _mixpanel?.track('App Opened');
  }

  static void sessionStart() {
    _sessionStartTime = DateTime.now();
    _mixpanel?.track('Session Started');
  }

  static void sessionEnd() {
    if (_sessionStartTime != null) {
      final duration = DateTime.now().difference(_sessionStartTime!).inSeconds;
      _mixpanel?.track('Session Ended', properties: {'Duration Seconds': duration});
      _sessionStartTime = null;
    }
  }

  static void shopView(String shopId, String shopName) {
    _mixpanel?.track('Shop View', properties: {
      'Shop ID': shopId,
      'Shop Name': shopName,
    });
  }

  static void shopClick(String shopId, String shopName) {
    _mixpanel?.track('Shop Click', properties: {
      'Shop ID': shopId,
      'Shop Name': shopName,
    });
  }

  static void productView(String productId, String productName, String shopId) {
    _mixpanel?.track('Product View', properties: {
      'Product ID': productId,
      'Product Name': productName,
      'Shop ID': shopId,
    });
  }

  static void productClick(String productId, String productName, String shopId) {
    _mixpanel?.track('Product Click', properties: {
      'Product ID': productId,
      'Product Name': productName,
      'Shop ID': shopId,
    });
  }

  static void addToCart(String productId, String productName, double price, String shopId) {
    _mixpanel?.track('Add To Cart', properties: {
      'Product ID': productId,
      'Product Name': productName,
      'Price': price,
      'Shop ID': shopId,
    });
  }

  static void checkoutVisit(int cartItemCount, double cartTotal) {
    _mixpanel?.track('Checkout Visit', properties: {
      'Item Count': cartItemCount,
      'Cart Total': cartTotal,
    });
  }

  static void orderPlaced(String orderId, double total, int itemCount) {
    _mixpanel?.track('Order Placed', properties: {
      'Order ID': orderId,
      'Total Amount': total,
      'Item Count': itemCount,
    });
  }

  static void orderAbandoned(double cartTotal, int cartItems, String abandonedAt) {
    _mixpanel?.track('Order Abandoned', properties: {
      'Cart Total': cartTotal,
      'Cart Items': cartItems,
      'Abandoned At': abandonedAt,
    });
  }

  static void search(String query, int resultsCount) {
    _mixpanel?.track('Search', properties: {
      'Query': query,
      'Results Count': resultsCount,
    });
  }

  static void bannerClick(String bannerId, String bannerTitle) {
    _mixpanel?.track('Banner Click', properties: {
      'Banner ID': bannerId,
      'Banner Title': bannerTitle,
    });
  }

  static void promoBannerClick(String promoId, String promoTitle) {
    _mixpanel?.track('Promo Banner Click', properties: {
      'Promo ID': promoId,
      'Promo Title': promoTitle,
    });
  }

  static void notificationClick(String notifId, String type) {
    _mixpanel?.track('Notification Click', properties: {
      'Notification ID': notifId,
      'Type': type,
    });
  }

  static void userLocation(String city, String area) {
    _mixpanel?.track('User Location', properties: {
      'City': city,
      'Area': area,
    });
  }

  static void deliveryZoneCheck(bool isValid, String zone) {
    _mixpanel?.track('Delivery Zone Check', properties: {
      'Is Valid': isValid,
      'Zone': zone,
    });
  }

  static void hostelDropdownUsed(String type, String value, {String? extra}) =>
      _mixpanel?.track('Hostel Dropdown Used', properties: {
        'type': type,
        'value': value,
        if (extra != null) 'extra': extra,
      });

  static void reset() {
    _mixpanel?.reset();
  }
}
