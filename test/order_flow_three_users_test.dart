import 'package:flutter_test/flutter_test.dart';
import 'package:ghartek_flutter_app/services/rider_orders_loader.dart';

/// Validates order-flow logic from three user perspectives:
/// 1. Customer — order appears in active list when status is non-terminal
/// 2. Rider — pool orders (available) + own assigned orders surface instantly
/// 3. Merchant/Admin — status normalization keeps tabs consistent
void main() {
  group('RiderOrdersLoader — rider perspective', () {
    test('available pool orders are relevant to any rider', () {
      expect(
        RiderOrdersLoader.isRelevantForRider(
          {'status': 'available', 'assignedRider': ''},
          'rider-1',
        ),
        isTrue,
      );
    });

    test('picked unassigned orders are in the rider pool', () {
      expect(
        RiderOrdersLoader.isRelevantForRider(
          {'status': 'picked', 'assignedRider': ''},
          'rider-1',
        ),
        isTrue,
      );
    });

    test('assigned active orders belong only to that rider', () {
      expect(
        RiderOrdersLoader.isRelevantForRider(
          {'status': 'on_the_way', 'assignedRider': 'rider-1'},
          'rider-1',
        ),
        isTrue,
      );
      expect(
        RiderOrdersLoader.isRelevantForRider(
          {'status': 'on_the_way', 'assignedRider': 'rider-2'},
          'rider-1',
        ),
        isFalse,
      );
    });

    test('delivered orders stay visible for assigned rider history tab', () {
      expect(
        RiderOrdersLoader.isRelevantForRider(
          {'status': 'delivered', 'assignedRider': 'rider-1'},
          'rider-1',
        ),
        isTrue,
      );
    });

    test('cancelled orders are excluded from rider pool', () {
      expect(
        RiderOrdersLoader.isRelevantForRider(
          {'status': 'cancelled', 'assignedRider': ''},
          'rider-1',
        ),
        isFalse,
      );
    });
  });

  group('RiderOrdersLoader — customer perspective (status visibility)', () {
    test('confirmed and preparing map to available for rider notifications', () {
      expect(RiderOrdersLoader.normalizeStatus('confirmed'), 'available');
      expect(RiderOrdersLoader.normalizeStatus('preparing'), 'available');
    });

    test('legacy on_way statuses normalize to on_the_way', () {
      expect(RiderOrdersLoader.normalizeStatus('on_way'), 'on_the_way');
      expect(RiderOrdersLoader.normalizeStatus('out_for_delivery'), 'on_the_way');
    });
  });

  group('RiderOrdersLoader — merchant/admin perspective (status buckets)', () {
    test('terminal statuses are not in rider active pool', () {
      for (final status in ['delivered', 'cancelled', 'canceled']) {
        expect(
          RiderOrdersLoader.isRelevantForRider(
            {'status': status, 'assignedRider': 'other-rider'},
            'rider-1',
          ),
          isFalse,
          reason: '$status should not appear in rider new/active pool',
        );
      }
    });

    test('new order available status is immediately rider-relevant', () {
      final newOrder = {
        'status': 'available',
        'assignedRider': '',
        'shopName': 'Test Shop',
        'grandTotal': 500,
      };
      expect(RiderOrdersLoader.isRelevantForRider(newOrder, 'rider-abc'), isTrue);
      expect(RiderOrdersLoader.normalizeStatus(newOrder['status']), 'available');
    });
  });
}
