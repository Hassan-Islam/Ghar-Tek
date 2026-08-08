import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import '../services/analytics_service.dart';

class CityScopeService {
  static const String vehari = 'vehari';
  static const String islamabad = 'islamabad';
  static const String defaultCity = vehari;
  static const String _prefSelectedCity = 'selected_city';

  /// Only these two cities are supported — no dynamic city registry.
  static const List<String> allowedCities = <String>[vehari, islamabad];

  static bool _loaded = false;
  static String _cachedCity = defaultCity;
  static List<String> _supportedCities = <String>[vehari, islamabad];
  static Map<String, String> _cityLabels = <String, String>{
    vehari: 'Vehari',
    islamabad: 'Islamabad (QAU)',
  };

  static List<String> get supportedCities => List.unmodifiable(_supportedCities);

  static String get currentCity => _cachedCity;

  static bool isAllowedCity(String? city) {
    final key = normalizeCityKey(city);
    return key == vehari || key == islamabad;
  }

  static String normalizeCityKey(String? city) {
    final raw = (city ?? '').trim().toLowerCase();
    if (raw.isEmpty) return defaultCity;
    if (raw == islamabad || raw == 'isb' || raw == 'islamabad_city') {
      return islamabad;
    }
    if (raw == vehari) return vehari;
    // Reject custom / accidental cities (e.g. new_nankana_sahib).
    return defaultCity;
  }

  static String normalizeCity(String? city) {
    final key = normalizeCityKey(city);
    return key == islamabad ? islamabad : vehari;
  }

  static String cityLabel(String city) {
    final key = normalizeCity(city);
    return _cityLabels[key] ?? (key == islamabad ? 'Islamabad (QAU)' : 'Vehari');
  }

  /// Locks the app to Vehari + Islamabad only.
  static void loadFixedCities() {
    _supportedCities = List<String>.from(allowedCities);
    _cityLabels = <String, String>{
      vehari: 'Vehari',
      islamabad: 'Islamabad (QAU)',
    };
  }

  static void setSupportedCities(
    List<String> cities, {
    Map<String, String>? labels,
  }) {
    loadFixedCities();
    if (labels == null || labels.isEmpty) return;
    for (final key in allowedCities) {
      final label = labels[key]?.trim();
      if (label != null && label.isNotEmpty) {
        _cityLabels[key] = label;
      }
    }
  }

  /// Removes rogue cities from the old dynamic registry (e.g. new_nankana_sahib).
  static Future<void> pruneInvalidCitiesFromRegistry() async {
    try {
      final snap = await FirebaseDatabase.instance.ref('settings/cities').get();
      if (!snap.exists || snap.value is! Map) return;
      final data = Map<String, dynamic>.from(snap.value as Map);
      for (final key in data.keys) {
        final k = key.toString().trim().toLowerCase();
        if (k != vehari && k != islamabad) {
          await FirebaseDatabase.instance.ref('settings/cities/$key').remove();
        }
      }
    } catch (_) {}
  }

  static Future<void> ensureLoaded() async {
    loadFixedCities();
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefSelectedCity);
    final fixed = normalizeCity(raw);
    if (raw != null && raw.trim().toLowerCase() != fixed) {
      await prefs.setString(_prefSelectedCity, fixed);
    }
    _cachedCity = fixed;
    _loaded = true;
  }

  static Future<bool> hasSelectedCity() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_prefSelectedCity)) return false;
    final raw = prefs.getString(_prefSelectedCity);
    return isAllowedCity(raw);
  }

  static Future<String> getSelectedCity() async {
    await ensureLoaded();
    return _cachedCity;
  }

  static Future<void> setSelectedCity(String city) async {
    final normalized = normalizeCity(city);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSelectedCity, normalized);
    _cachedCity = normalized;
    _loaded = true;
    AnalyticsService.userLocation(normalized, 'N/A');
  }

  /// Riders/merchants/admins must read orders from their profile city, not a
  /// stale customer city left in SharedPreferences.
  static Future<String?> syncCityFromUserProfile(
    String uid, {
    String? role,
  }) async {
    if (uid.trim().isEmpty) return null;
    await ensureLoaded();
    try {
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();
      if (!snap.exists || snap.value is! Map) return null;
      final data = Map<String, dynamic>.from(snap.value as Map);
      final resolvedRole =
          (role ?? (data['role'] ?? 'customer')).toString().toLowerCase().trim();
      final rawCity = resolvedRole == 'admin'
          ? (data['adminCity'] ?? '').toString()
          : (data['userCity'] ?? '').toString();
      final trimmed = rawCity.trim();
      if (trimmed.isEmpty) return null;
      final city = normalizeCity(trimmed);
      if (city != _cachedCity) {
        await setSelectedCity(city);
      }
      return city;
    } catch (_) {
      return null;
    }
  }

  static String tenantPath(String path, {String? city}) {
    final selected = normalizeCity(city ?? _cachedCity);
    final clean = path.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
    return 'tenants/$selected/$clean';
  }
}
