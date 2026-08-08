class CategoryTimingService {
  static String normalizeCategory(dynamic category) {
    final raw = (category ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return '';

    return raw
        .replaceAll('&', 'and')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  static bool toBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return fallback;
  }

  static int? parseTimeToMinutes(String input) {
    final value = input.trim().toUpperCase();
    final match = RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$').firstMatch(value);
    if (match == null) return null;

    int hour = int.tryParse(match.group(1) ?? '') ?? -1;
    final minute = int.tryParse(match.group(2) ?? '') ?? -1;
    final amPm = match.group(3);
    if (hour < 0 || minute < 0 || minute > 59) return null;

    if (amPm != null) {
      if (hour == 12) hour = 0;
      if (amPm == 'PM') hour += 12;
    }

    if (hour < 0 || hour > 23) return null;
    return hour * 60 + minute;
  }

  static bool isWithinWindow({
    required String openTime,
    required String closeTime,
    DateTime? now,
  }) {
    final openMinutes = parseTimeToMinutes(openTime);
    final closeMinutes = parseTimeToMinutes(closeTime);
    if (openMinutes == null || closeMinutes == null) return true;

    final current = now ?? DateTime.now();
    final nowMinutes = current.hour * 60 + current.minute;

    if (openMinutes == closeMinutes) return true;
    if (openMinutes < closeMinutes) {
      return nowMinutes >= openMinutes && nowMinutes < closeMinutes;
    }

    // Overnight window (e.g. 10:00 PM -> 02:00 AM)
    return nowMinutes >= openMinutes || nowMinutes < closeMinutes;
  }

  static bool isProductTrendingNow(
    Map<String, dynamic> item, {
    DateTime? now,
  }) {
    final trendingCategory = (item['trendingCategory'] ?? item['mealCategory'] ?? item['category'] ?? item['type'] ?? '')
        .toString()
        .trim();
    if (trendingCategory.isEmpty) return false;

    final openTime = (item['trendingStartTime'] ?? item['trendingOpenTime'] ?? '')
        .toString()
        .trim();
    final closeTime = (item['trendingEndTime'] ?? item['trendingCloseTime'] ?? '')
        .toString()
        .trim();
    if (openTime.isEmpty || closeTime.isEmpty) return false;

    return isWithinWindow(openTime: openTime, closeTime: closeTime, now: now);
  }

  static Map<String, dynamic>? _toMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  static Map<String, dynamic>? resolveCategorySchedule({
    required dynamic schedules,
    required dynamic category,
  }) {
    final normalizedCategory = normalizeCategory(category);
    if (normalizedCategory.isEmpty || schedules is! Map) return null;

    final map = Map<dynamic, dynamic>.from(schedules);
    if (map.isEmpty) return null;

    final direct = _toMap(map[normalizedCategory]);
    if (direct != null) return direct;

    for (final entry in map.entries) {
      final schedule = _toMap(entry.value);
      if (schedule == null) continue;

      final keyMatch = normalizeCategory(entry.key) == normalizedCategory;
      final categoryMatch =
          normalizeCategory(schedule['category']) == normalizedCategory;
      if (keyMatch || categoryMatch) return schedule;
    }

    return null;
  }

  static bool isCategoryAvailable({
    required dynamic schedules,
    required dynamic category,
    DateTime? now,
  }) {
    final schedule =
        resolveCategorySchedule(schedules: schedules, category: category);
    if (schedule == null) return true;

    final enabled = toBool(schedule['enabled'], fallback: true);
    if (!enabled) return true;

    final openTime = (schedule['openTime'] ?? '').toString().trim();
    final closeTime = (schedule['closeTime'] ?? '').toString().trim();
    if (openTime.isEmpty || closeTime.isEmpty) return true;

    return isWithinWindow(openTime: openTime, closeTime: closeTime, now: now);
  }
}
