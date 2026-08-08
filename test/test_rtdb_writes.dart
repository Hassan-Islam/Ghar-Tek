import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  final dbUrl = 'https://pak-delivers-default-rtdb.firebaseio.com';
  
  final testPaths = [
    'tenants/islamabad/settings/app-control/activeAdminTokens/test_write',
    'tenants/islamabad/activeAdminTokens/test_write',
    'tenants/islamabad/activeRiderTokens/test_write',
    'activeRiderTokens/test_write',
    'public_tokens/test_write',
    'tenants/islamabad/public_tokens/test_write',
  ];

  print("Connecting to database at $dbUrl to test writes...");

  for (final path in testPaths) {
    try {
      final url = Uri.parse('$dbUrl/$path.json');
      final payload = jsonEncode({
        'test': 'success',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final response = await http.put(url, body: payload);
      if (response.statusCode == 200) {
        print("WRITE SUCCESS: $path (Status: 200)");
        // Clean it up
        await http.delete(url);
      } else {
        print("WRITE FAILED: $path (Status: ${response.statusCode}, Body: ${response.body})");
      }
    } catch (e) {
      print("Error testing write for $path: $e");
    }
  }
}
