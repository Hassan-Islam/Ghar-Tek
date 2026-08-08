import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppVersionService {
  static final AppVersionService _instance = AppVersionService._internal();
  final DatabaseReference _database = FirebaseDatabase.instance.ref();

  AppVersionService._internal();

  factory AppVersionService() {
    return _instance;
  }

  /// Get current app version from pubspec
  Future<String> getCurrentVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final build = packageInfo.buildNumber.trim();
      if (build.isEmpty) return packageInfo.version;
      // Include build number so comparison matches Firebase "x.y.z+build".
      return '${packageInfo.version}+$build';
    } catch (e) {
      return '0.0.0';
    }
  }

  /// Compare versions: returns true if updateVersion > currentVersion
  bool _isNewerVersion(String currentVersion, String updateVersion) {
    try {
      final current = _parseVersionParts(currentVersion);
      final update = _parseVersionParts(updateVersion);

      final maxLength = current.length > update.length ? current.length : update.length;
      for (int i = 0; i < maxLength; i++) {
        final currentPart = i < current.length ? current[i] : 0;
        final updatePart = i < update.length ? update[i] : 0;
        if (updatePart > currentPart) return true;
        if (updatePart < currentPart) return false;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  bool _isOlderVersion(String currentVersion, String minimumVersion) {
    return _isNewerVersion(currentVersion, minimumVersion);
  }

  List<int> _parseVersionParts(String version) {
    final raw = version.trim();
    final parts = raw.split('+');
    final base = parts.first
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final build = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    base.add(build);
    return base;
  }

  /// Check for app updates from Firebase
  /// Returns: {
  ///   'hasUpdate': bool,
  ///   'isForceUpdate': bool,
  ///   'latestVersion': String,
  ///   'updateMessage': String,
  ///   'playStoreUrl': String,
  /// }
  Future<Map<String, dynamic>> checkForUpdate() async {
    try {
      final currentVersion = await getCurrentVersion();
      
      // Fetch app config from Firebase
      final snapshot = await _database.child('app-config/version').get();
      
      if (!snapshot.exists) {
        return {
          'hasUpdate': false,
          'isForceUpdate': false,
          'latestVersion': currentVersion,
          'updateMessage': '',
          'playStoreUrl': '',
        };
      }

      final data = snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        return {
          'hasUpdate': false,
          'isForceUpdate': false,
          'latestVersion': currentVersion,
          'updateMessage': '',
          'playStoreUrl': '',
        };
      }

      final latestVersion = data['latest']?.toString() ?? currentVersion;
      final minimumVersion = data['minimum']?.toString() ?? '0.0.0';
      final isForceUpdate = _isOlderVersion(currentVersion, minimumVersion);
      final hasUpdate = _isNewerVersion(currentVersion, latestVersion);

      return {
        'hasUpdate': hasUpdate || isForceUpdate,
        'isForceUpdate': isForceUpdate,
        'latestVersion': latestVersion,
        'updateMessage': data['message']?.toString() ?? 'A new update is available',
        'playStoreUrl': data['playStoreUrl']?.toString() ?? 
                       'https://play.google.com/store/apps/details?id=com.ghartek.app',
      };
    } catch (e) {
      return {
        'hasUpdate': false,
        'isForceUpdate': false,
        'latestVersion': '',
        'updateMessage': '',
        'playStoreUrl': '',
      };
    }
  }

  /// Update Firebase config (use for admin/testing)
  Future<void> setVersionConfig({
    required String latest,
    required String minimum,
    required String message,
    String playStoreUrl = 'https://play.google.com/store/apps/details?id=com.ghartek.app',
  }) async {
    try {
      await _database.child('app-config/version').set({
        'latest': latest,
        'minimum': minimum,
        'message': message,
        'playStoreUrl': playStoreUrl,
        'lastUpdated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      rethrow;
    }
  }
}
