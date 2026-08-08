import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:ghartek_flutter_app/firebase_options.dart';
import 'package:ghartek_flutter_app/services/city_scope_service.dart';

void main() {
  test('Diagnose FCM config and user tokens', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print("Firebase Initialized!");

    final db = FirebaseDatabase.instance.ref();

    final testPaths = [
      'tenants/islamabad/settings/app-control/activeAdminTokens/test_write',
      'tenants/islamabad/activeAdminTokens/test_write',
      'tenants/islamabad/activeRiderTokens/test_write',
      'activeRiderTokens/test_write',
    ];

    print("\n=== Testing Database Writes (Unauthenticated) ===");
    for (final path in testPaths) {
      try {
        await db.child(path).set({
          'test': 'success',
          'timestamp': ServerValue.timestamp,
        });
        print("WRITE SUCCESS: $path");
        // Clean up
        await db.child(path).remove();
      } catch (e) {
        print("WRITE FAILED: $path - Error: $e");
      }
    }
  });
}
