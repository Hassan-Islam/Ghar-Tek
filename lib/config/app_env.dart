import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Reads secrets and config from the gitignored `.env` file.
/// Copy `.env.example` to `.env` and fill in your values before running.
class AppEnv {
  static String _require(String key) {
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) {
      throw StateError(
        'Missing required env var: $key. Copy .env.example to .env and fill in values.',
      );
    }
    return value;
  }

  static String _optional(String key, String fallback) {
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) return fallback;
    return value;
  }

  // Primary Firebase (pak-delivers)
  static String get firebaseApiKey => _require('FIREBASE_API_KEY');
  static String get firebaseProjectId => _require('FIREBASE_PROJECT_ID');
  static String get firebaseMessagingSenderId =>
      _require('FIREBASE_MESSAGING_SENDER_ID');
  static String get firebaseAuthDomain => _require('FIREBASE_AUTH_DOMAIN');
  static String get firebaseDatabaseUrl => _require('FIREBASE_DATABASE_URL');
  static String get firebaseStorageBucket =>
      _require('FIREBASE_STORAGE_BUCKET');
  static String get firebaseWebAppId => _require('FIREBASE_WEB_APP_ID');
  static String get firebaseAndroidAppId =>
      _require('FIREBASE_ANDROID_APP_ID');
  static String get firebaseIosAppId => _require('FIREBASE_IOS_APP_ID');
  static String get firebaseIosClientId =>
      _require('FIREBASE_IOS_CLIENT_ID');
  static String get firebaseMeasurementId =>
      _optional('FIREBASE_MEASUREMENT_ID', 'G-MEASUREMENT_ID');

  // Secondary Firebase app (ratings – ghartek-c3399)
  static String get ratingsFirebaseApiKey =>
      _require('RATINGS_FIREBASE_API_KEY');
  static String get ratingsFirebaseAppId =>
      _require('RATINGS_FIREBASE_APP_ID');
  static String get ratingsFirebaseMessagingSenderId =>
      _require('RATINGS_FIREBASE_MESSAGING_SENDER_ID');
  static String get ratingsFirebaseProjectId =>
      _require('RATINGS_FIREBASE_PROJECT_ID');
  static String get ratingsFirebaseDatabaseUrl =>
      _require('RATINGS_FIREBASE_DATABASE_URL');

  // Analytics
  static String get mixpanelToken => _require('MIXPANEL_TOKEN');
}
