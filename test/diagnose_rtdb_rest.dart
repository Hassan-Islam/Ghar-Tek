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
        print("fcmServerKey exists: ${data.containsKey('fcmServerKey')}");
        if (data.containsKey('fcmServerKey')) {
          print("fcmServerKey length: ${data['fcmServerKey'].toString().length}");
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
  try {
    final citiesResponse = await http.get(Uri.parse('$dbUrl/settings/cities.json'));
    if (citiesResponse.statusCode == 200) {
      final cities = jsonDecode(citiesResponse.body);
      if (cities is Map) {
        print("\n=== Cities Scoped App Control Configuration ===");
        for (final cityKey in cities.keys) {
          final response = await http.get(Uri.parse('$dbUrl/$cityKey/settings/app-control.json'));
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
          }
        }
      }
    }
  } catch (e) {
    print("Error fetching cities: $e");
  }

  // 3. Fetch users and active tokens
  try {
    final response = await http.get(Uri.parse('$dbUrl/users.json'));
    if (response.statusCode == 200) {
      final users = jsonDecode(response.body);
      if (users is Map) {
        print("\n=== User Tokens Diagnosis ===");
        print("Total Users in DB: ${users.length}");
        int adminCount = 0;
        int riderCount = 0;
        int tokenCount = 0;
        users.forEach((key, val) {
          if (val is Map) {
            final role = (val['role'] ?? 'customer').toString().toLowerCase();
            final adminCity = val['adminCity']?.toString() ?? '';
            final userCity = val['userCity']?.toString() ?? '';
            final tokens = val['fcmTokens'];
            if (role == 'admin') adminCount++;
            if (role == 'rider') riderCount++;
            if (tokens is Map) {
              tokenCount += tokens.length;
              print("User UID: $key, Role: $role, adminCity: $adminCity, userCity: $userCity, Tokens: ${tokens.keys.toList()}");
            } else {
              print("User UID: $key, Role: $role, adminCity: $adminCity, userCity: $userCity, Has No Tokens");
            }
          }
        });
        print("\nSummary:");
        print("  Admins: $adminCount");
        print("  Riders: $riderCount");
        print("  Total tokens across all users: $tokenCount");
      }
    } else {
      print("Failed to fetch users. Status: ${response.statusCode}");
    }
  } catch (e) {
    print("Error fetching users: $e");
  }
}
