import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import '../city_scope_service.dart';
import 'app_db_client.dart';

/// Wires the database client to Firebase Auth and probes the PostgreSQL backend.
/// Falls back to Firebase RTDB automatically when the backend is unreachable.
Future<void> configureAppDatabase() async {
  AppDbClient.instance.tokenProvider = () async {
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  };
  await AppDbClient.instance.initialize();
  unawaited(CityScopeService.pruneInvalidCitiesFromRegistry());
}
