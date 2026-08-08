import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalNotificationRecord {
  final String title;
  final String body;
  final DateTime dateTime;
  final Map<String, dynamic>? data;

  LocalNotificationRecord({
    required this.title,
    required this.body,
    required this.dateTime,
    this.data,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'body': body,
        'dateTime': dateTime.toIso8601String(),
        'data': data,
      };

  factory LocalNotificationRecord.fromJson(Map<String, dynamic> json) =>
      LocalNotificationRecord(
        title: json['title'] ?? '',
        body: json['body'] ?? '',
        dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now(),
        data: json['data'] != null ? Map<String, dynamic>.from(json['data']) : null,
      );
}

class LocalNotificationStore {
  static const String _key = 'ghartek_local_notifications_list';

  static Future<List<LocalNotificationRecord>> getNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? listRaw = prefs.getString(_key);
      if (listRaw == null) return [];
      final List decoded = jsonDecode(listRaw);
      return decoded
          .map((e) => LocalNotificationRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addNotification({
    required String title,
    required String body,
    Map<String, dynamic>? data,
    String? dedupeKey,
    DateTime? dateTime,
  }) async {
    try {
      final notifications = await getNotifications();
      if (dedupeKey != null &&
          notifications.any((n) => n.data?['dedupeKey'] == dedupeKey)) {
        return;
      }

      final enrichedData = data == null && dedupeKey == null
          ? null
          : {
              if (data != null) ...data,
              if (dedupeKey != null) 'dedupeKey': dedupeKey,
            };

      notifications.insert(
        0,
        LocalNotificationRecord(
          title: title,
          body: body,
          dateTime: dateTime ?? DateTime.now(),
          data: enrichedData,
        ),
      );
      if (notifications.length > 50) {
        notifications.removeRange(50, notifications.length);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(notifications.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  static Future<void> clearNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
