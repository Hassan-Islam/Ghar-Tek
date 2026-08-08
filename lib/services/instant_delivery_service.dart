import 'package:flutter/material.dart';

/// Resolved price label for instant product cards.
class InstantProductPrice {
  const InstantProductPrice({
    required this.price,
    this.originalPrice,
    this.isStartingFrom = false,
  });

  final double price;
  final double? originalPrice;
  final bool isStartingFrom;

  bool get hasPrice => price > 0;

  String get displayLabel {
    if (!hasPrice) return 'Price on request';
    final amount = price.round().toString();
    return isStartingFrom ? 'From Rs. $amount' : 'Rs. $amount';
  }
}

/// Helpers for Islamabad-only Instant Delivery feature.
class InstantDeliveryService {
  InstantDeliveryService._();

  static const String instantCategory = 'Instant';
  static const int deliveryMinutes = 20;
  static const double defaultDeliveryFee = 70;

  static const String headerLabel = 'INSTANT';
  static const String headerSubtitle = '20 min';
  static const String pageTitle = 'Instant Delivery';
  static const String promiseTitle = '20-Minute Delivery';
  static const String promiseSubtitle =
      'Not delivered in 20 minutes? Your delivery fee is on us.';
  static const String cartLabel = 'Instant Cart';
  static const String addedToastSuffix = 'added to Instant cart';
  static const String badgeLabel = '20 min';

  static String deliveryFeeLabel(double fee) {
    final amount = fee.round().toString();
    return 'Rs. $amount delivery fee';
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().trim());
  }

  static InstantProductPrice resolveDisplayPrice(Map<String, dynamic> product) {
    double? lowestPrice;
    double? lowestOriginal;
    var multipleOptions = false;

    void consider(double? price, {double? originalPrice}) {
      if (price == null || price <= 0) return;
      if (lowestPrice == null || price < lowestPrice!) {
        lowestPrice = price;
        lowestOriginal = originalPrice;
      }
    }

    final sizes = product['sizes'];
    if (sizes is List && sizes.isNotEmpty) {
      multipleOptions = sizes.length > 1;
      for (final raw in sizes) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        consider(
          _toDouble(row['price']),
          originalPrice: _toDouble(row['originalPrice']),
        );
      }
    } else if (sizes is Map && sizes.isNotEmpty) {
      multipleOptions = sizes.length > 1;
      for (final raw in sizes.values) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        consider(
          _toDouble(row['price']),
          originalPrice: _toDouble(row['originalPrice']),
        );
      }
    }

    final halfPrice = _toDouble(product['halfPrice']) ?? 0;
    final fullPrice = _toDouble(product['fullPrice']) ?? 0;
    if (halfPrice > 0 || fullPrice > 0) {
      if (halfPrice > 0 && fullPrice > 0) multipleOptions = true;
      consider(halfPrice, originalPrice: _toDouble(product['originalPrice']));
      consider(fullPrice);
    }

    final variants = product['variants'];
    if (variants is Map && variants.isNotEmpty) {
      if (variants.length > 1) multipleOptions = true;
      for (final raw in variants.values) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        consider(
          _toDouble(row['price'] ?? row['amount']),
          originalPrice: _toDouble(row['originalPrice'] ?? row['oldPrice']),
        );
      }
    }

    if (lowestPrice != null) {
      return InstantProductPrice(
        price: lowestPrice!,
        originalPrice:
            lowestOriginal != null && lowestOriginal! > lowestPrice!
                ? lowestOriginal
                : null,
        isStartingFrom: multipleOptions,
      );
    }

    final basePrice = _toDouble(product['price']) ?? 0;
    final baseOriginal = _toDouble(product['originalPrice']);
    final hasSizes = product['hasSizes'] == true;
    return InstantProductPrice(
      price: basePrice,
      originalPrice:
          baseOriginal != null && baseOriginal > basePrice ? baseOriginal : null,
      isStartingFrom: hasSizes && basePrice > 0,
    );
  }

  static bool isInstantProduct(Map<String, dynamic> product) {
    final category = (product['category'] ?? product['type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (category == instantCategory.toLowerCase()) return true;
    return product['instantDelivery'] == true || product['isInstant'] == true;
  }

  static bool isInstantCategory(String? category) {
    if (category == null) return false;
    return category.trim().toLowerCase() == instantCategory.toLowerCase();
  }

  static bool isInstantOrder(Map<String, dynamic> order) {
    if (order['isInstantOrder'] == true) return true;
    final speed = (order['deliverySpeed'] ?? '').toString().toLowerCase();
    return speed == 'instant';
  }

  static Widget buildOrderBadge({bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF3D00), Color(0xFFFF6B00)],
        ),
        borderRadius: BorderRadius.circular(compact ? 12 : 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bolt_rounded,
            color: Colors.white,
            size: compact ? 11 : 14,
          ),
          SizedBox(width: compact ? 3 : 5),
          Text(
            'INSTANT',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: compact ? 10 : 12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  static Widget buildOrderBanner({bool forCardTop = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF3D00), Color(0xFFFF6B00)],
        ),
        borderRadius: forCardTop
            ? const BorderRadius.vertical(top: Radius.circular(16))
            : BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            'INSTANT DELIVERY · $deliveryMinutes MIN',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 13,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
