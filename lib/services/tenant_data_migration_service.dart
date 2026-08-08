import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'city_scope_service.dart';

class TenantMigrationResult {
  final bool skipped;
  final int copiedTopLevelKeys;
  final List<String> touchedPaths;
  final bool hadErrors;

  const TenantMigrationResult({
    required this.skipped,
    required this.copiedTopLevelKeys,
    required this.touchedPaths,
    required this.hadErrors,
  });
}

class TenantDataMigrationService {
  static const String _prefLegacyMigratedPrefix = 'legacy_to_tenant_migrated_v1_';
  static const String _prefLegacyGlobalShopsCleanedPrefix =
      'legacy_global_shops_cleaned_v1_';
  // Safety-first: never auto-delete legacy data paths during normal app usage.
  // Keep this false in production builds to avoid accidental data loss.
  static const bool _allowDestructiveLegacyCleanup = false;
  static const Set<String> _skipMergeIfTenantExists = {
    'shops',
    'shop-orders',
    'custom-orders',
    'notifications',
  };

  static const List<String> _legacyPaths = [
    'settings',
    'shops',
    'shop-orders',
    'custom-orders',
    'khata',
    'merchant_profiles',
    'meta/orderCounters',
    'notifications',
  ];

  static Future<TenantMigrationResult> migrateLegacyDataForCity({
    required String city,
    bool force = false,
  }) async {
    final normalizedCity = CityScopeService.normalizeCity(city);
    final prefs = await SharedPreferences.getInstance();
    final prefKey = '$_prefLegacyMigratedPrefix$normalizedCity';

    if (!force && (prefs.getBool(prefKey) ?? false)) {
      return const TenantMigrationResult(
        skipped: true,
        copiedTopLevelKeys: 0,
        touchedPaths: <String>[],
        hadErrors: false,
      );
    }

    final root = FirebaseDatabase.instance.ref();
    int copied = 0;
    final touched = <String>[];
    bool hadErrors = false;

    for (final path in _legacyPaths) {
      try {
        final globalRef = root.child(path);
        final tenantRef = root.child(CityScopeService.tenantPath(path, city: normalizedCity));

        final globalSnap = await globalRef.get();
        if (!globalSnap.exists) {
          continue;
        }

        final tenantSnap = await tenantRef.get();
        if (!tenantSnap.exists) {
          await tenantRef.set(globalSnap.value);
          copied += _countTopLevel(globalSnap.value);
          touched.add(path);
          continue;
        }

        // Do not backfill deleted/curated records once tenant data already exists.
        // This prevents removed shops from reappearing from legacy global paths.
        if (_skipMergeIfTenantExists.contains(path)) {
          continue;
        }

        final merged = await _mergeMissingEntries(
          tenantRef: tenantRef,
          globalValue: globalSnap.value,
          tenantValue: tenantSnap.value,
        );

        if (merged > 0) {
          copied += merged;
          touched.add(path);
        }
      } catch (_) {
        hadErrors = true;
      }
    }

    if (!hadErrors) {
      await prefs.setBool(prefKey, true);
    }

    return TenantMigrationResult(
      skipped: false,
      copiedTopLevelKeys: copied,
      touchedPaths: touched,
      hadErrors: hadErrors,
    );
  }

  static int _countTopLevel(dynamic value) {
    if (value is Map) return value.length;
    return 1;
  }

  static Future<int> cleanupLegacyGlobalShopsForCity({
    required String city,
    bool force = false,
  }) async {
    if (!_allowDestructiveLegacyCleanup) {
      return 0;
    }

    final normalizedCity = CityScopeService.normalizeCity(city);
    final prefs = await SharedPreferences.getInstance();
    final cleanupPrefKey = '$_prefLegacyGlobalShopsCleanedPrefix$normalizedCity';

    if (!force && (prefs.getBool(cleanupPrefKey) ?? false)) {
      return 0;
    }

    final migrationPrefKey = '$_prefLegacyMigratedPrefix$normalizedCity';
    final alreadyMigrated = prefs.getBool(migrationPrefKey) ?? false;

    final root = FirebaseDatabase.instance.ref();
    final tenantShopsSnap =
        await root.child(CityScopeService.tenantPath('shops', city: normalizedCity)).get();

    // Safety gate: do not delete legacy city shops until tenant migration is known to have happened.
    if (!alreadyMigrated && !tenantShopsSnap.exists) {
      return 0;
    }

    final globalShopsRef = root.child('shops');
    final globalShopsSnap = await globalShopsRef.get();

    if (!globalShopsSnap.exists || globalShopsSnap.value is! Map) {
      await prefs.setBool(cleanupPrefKey, true);
      return 0;
    }

    final globalShops = Map<dynamic, dynamic>.from(globalShopsSnap.value as Map);
    int removed = 0;

    for (final entry in globalShops.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final shopMap = Map<dynamic, dynamic>.from(value);
      final shopCity = CityScopeService.normalizeCity(shopMap['city']?.toString());
      if (shopCity != normalizedCity) {
        continue;
      }

      await globalShopsRef.child(entry.key.toString()).remove();
      removed += 1;
    }

    await prefs.setBool(cleanupPrefKey, true);
    return removed;
  }

  static Future<int> _mergeMissingEntries({
    required DatabaseReference tenantRef,
    required dynamic globalValue,
    required dynamic tenantValue,
  }) async {
    if (globalValue is! Map) {
      return 0;
    }

    final globalMap = Map<dynamic, dynamic>.from(globalValue);
    final tenantMap = tenantValue is Map
        ? Map<dynamic, dynamic>.from(tenantValue)
        : <dynamic, dynamic>{};

    int copied = 0;

    for (final entry in globalMap.entries) {
      final key = entry.key.toString();

      if (!tenantMap.containsKey(entry.key)) {
        await tenantRef.child(key).set(entry.value);
        copied += 1;
        continue;
      }

      final g = entry.value;
      final t = tenantMap[entry.key];
      if (g is Map && t is Map) {
        copied += await _mergeMissingEntries(
          tenantRef: tenantRef.child(key),
          globalValue: g,
          tenantValue: t,
        );
      }
    }

    return copied;
  }
}
