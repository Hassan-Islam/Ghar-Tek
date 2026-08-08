import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  final dbUrl = 'https://pak-delivers-default-rtdb.firebaseio.com';
  
  print("Connecting to database at $dbUrl...");

  // 1. Fetch settings/app-control
  try {
    final response = await http.get(Uri.parse('$dbUrl/settings/app-control.json'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map) {
        print("\n=== Global App Control Configuration ===");
        print("Configured Keys: ${data.keys.toList()}");
        print("fcmServiceAccountJson exists: ${data.containsKey('fcmServiceAccountJson')}");
        if (data.containsKey('fcmServiceAccountJson')) {
          final sa = data['fcmServiceAccountJson'].toString();
          print("fcmServiceAccountJson length: ${sa.length}");
          if (sa.isNotEmpty) {
            try {
              final parsed = jsonDecode(sa);
              print("Service Account JSON is valid JSON. project_id: ${parsed['project_id']}, client_email: ${parsed['client_email']}");
            } catch (e) {
              print("WARNING: fcmServiceAccountJson is NOT valid JSON: $e");
            }
          }
        }
      } else {
        print("\nGlobal App Control is empty/null.");
      }
    } else {
      print("Failed to fetch settings/app-control. Status: ${response.statusCode}");
    }
  } catch (e) {
    print("Error fetching settings/app-control: $e");
  }

  // 2. Fetch supported cities config
  final cities = ['vehari', 'islamabad'];
  print("\n=== Cities Scoped App Control Configuration ===");
  for (final cityKey in cities) {
    try {
      final response = await http.get(Uri.parse('$dbUrl/tenants/$cityKey/settings/app-control.json'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map) {
          print("City: $cityKey Scoped Keys: ${data.keys.toList()}");
          print("  fcmServiceAccountJson exists: ${data.containsKey('fcmServiceAccountJson')}");
          if (data.containsKey('fcmServiceAccountJson')) {
            final sa = data['fcmServiceAccountJson'].toString();
            print("  fcmServiceAccountJson length: ${sa.length}");
            if (sa.isNotEmpty) {
              try {
                final parsed = jsonDecode(sa);
                print("  Service Account JSON is valid JSON. project_id: ${parsed['project_id']}, client_email: ${parsed['client_email']}");
              } catch (e) {
                print("  WARNING: fcmServiceAccountJson is NOT valid JSON: $e");
              }
            }
          }
        } else {
          print("City: $cityKey Scoped App Control is empty/null.");
        }
      } else {
        print("Failed to fetch City: $cityKey. Status: ${response.statusCode}");
      }
    } catch (e) {
      print("Error fetching city $cityKey: $e");
    }
  }
}
