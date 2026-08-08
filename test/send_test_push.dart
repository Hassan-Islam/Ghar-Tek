import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/auth_io.dart' as google_auth;

Future<void> main() async {
  final dbUrl = 'https://pak-delivers-default-rtdb.firebaseio.com';
  print("Fetching Service Account JSON...");
  
  String? serviceAccountJson;
  try {
    final response = await http.get(Uri.parse('$dbUrl/settings/app-control.json'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map && data.containsKey('fcmServiceAccountJson')) {
        serviceAccountJson = data['fcmServiceAccountJson'].toString();
      }
    }
  } catch (e) {
    print("Error fetching credentials: $e");
    return;
  }

  if (serviceAccountJson == null || serviceAccountJson.isEmpty) {
    print("No Service Account JSON found in DB!");
    return;
  }

  print("Obtaining OAuth access token...");
  final Map<String, dynamic> sa = jsonDecode(serviceAccountJson);
  final projectId = sa['project_id'];
  final clientEmail = sa['client_email'];
  print("Project: $projectId, Service Account: $clientEmail");

  final credentials = google_auth.ServiceAccountCredentials.fromJson(sa);
  final scopes = ['https://www.googleapis.com/auth/firebase.messaging'];
  
  google_auth.AutoRefreshingAuthClient? authClient;
  try {
    authClient = await google_auth.clientViaServiceAccount(credentials, scopes);
    final accessToken = authClient.credentials.accessToken.data;
    print("OAuth Access Token obtained successfully! (length: ${accessToken.length})");

    final endpoint = Uri.parse('https://fcm.googleapis.com/v1/projects/$projectId/messages:send');
    
    // We will send to 'city_islamabad' topic
    final payload = {
      'message': {
        'topic': 'city_islamabad',
        'notification': {
          'title': 'Test Direct Push',
          'body': 'This is a test notification from the direct REST script.',
        },
        'data': {
          'type': 'broadcast',
          'city': 'islamabad',
        },
        'android': {
          'priority': 'HIGH',
          'collapse_key': 'test_collapse',
          'notification': {
            'channel_id': 'ghartek_main',
            'sound': 'default',
          },
        },
        'apns': {
          'headers': {
            'apns-priority': '10',
          },
          'payload': {
            'aps': {
              'sound': 'default',
              'badge': 1,
              'content-available': 1,
            },
          },
        },
      }
    };

    print("Sending test push notification to topic 'city_islamabad'...");
    final res = await http.post(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(payload),
    );

    print("Response Status: ${res.statusCode}");
    print("Response Body: ${res.body}");
  } catch (e) {
    print("Error during direct send: $e");
  } finally {
    authClient?.close();
  }
}
