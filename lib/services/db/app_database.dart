import 'dart:async';
import 'dart:math';

import 'app_db_client.dart';

/// Drop-in replacement for `package:firebase_database/firebase_database.dart`.
///
/// The public class names and method signatures deliberately match the
/// Firebase Realtime Database Dart API, so files only need to swap their
/// import. Data now lives in PostgreSQL behind the GharTek backend; Firebase
/// Auth (login) and FCM (push) are untouched.

String _normalize(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

String _join(String base, String child) {
  final b = _normalize(base);
  final c = _normalize(child);
  if (b.isEmpty) return c;
  if (c.isEmpty) return b;
  return '$b/$c';
}

String? _lastSegment(String path) {
  final p = _normalize(path);
  if (p.isEmpty) return null;
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

/// Server-side sentinels, matching Firebase's `ServerValue`.
class ServerValue {
  static const Map<String, String> timestamp = {'.sv': 'timestamp'};
  static Map<String, dynamic> increment(num delta) => {'.sv': {'increment': delta}};
}

class FirebaseDatabase {
  FirebaseDatabase._(this._dbName);

  final String _dbName;

  static final FirebaseDatabase _main = FirebaseDatabase._('main');
  static final FirebaseDatabase _ratings = FirebaseDatabase._('ratings');

  static FirebaseDatabase get instance => _main;

  /// Firebase used a secondary app named `ratingsApp` for its ratings DB.
  static FirebaseDatabase instanceFor({dynamic app}) {
    try {
      final name = app?.name;
      if (name == 'ratingsApp') return _ratings;
    } catch (_) {}
    return _main;
  }

  DatabaseReference ref([String? path]) =>
      DatabaseReference._(_dbName, path == null ? '' : _normalize(path));

  DatabaseReference refFromURL(String url) => ref();

  // Persistence was a local Firebase cache; no-op here (backend handles reads).
  void setPersistenceEnabled(bool enabled) {}
  void setPersistenceCacheSizeBytes(int bytes) {}
  void setLoggingEnabled(bool enabled) {}
  void goOnline() {}
  void goOffline() {}
}

/// A query over the children of a location (orderBy/limit/filters).
class Query {
  Query._(this._dbName, this._path, [Map<String, dynamic>? params])
      : _params = params ?? <String, dynamic>{};

  final String _dbName;
  final String _path;
  final Map<String, dynamic> _params;

  AppDbClient get _client => AppDbClient.instance;

  Map<String, dynamic> _with(Map<String, dynamic> extra) => {
        ..._params,
        ...extra,
      };

  Query orderByChild(String key) =>
      Query._(_dbName, _path, _with({'orderBy': 'child', 'childKey': key}));
  Query orderByKey() => Query._(_dbName, _path, _with({'orderBy': 'key'}));
  Query orderByValue() => Query._(_dbName, _path, _with({'orderBy': 'value'}));

  Query equalTo(Object? value, {String? key}) =>
      Query._(_dbName, _path, _with({'equalTo': value}));
  Query startAt(Object? value, {String? key}) =>
      Query._(_dbName, _path, _with({'startAt': value}));
  Query endAt(Object? value, {String? key}) =>
      Query._(_dbName, _path, _with({'endAt': value}));

  Query limitToFirst(int limit) =>
      Query._(_dbName, _path, _with({'limitToFirst': limit}));
  Query limitToLast(int limit) =>
      Query._(_dbName, _path, _with({'limitToLast': limit}));

  bool get _hasQuery => _params.isNotEmpty;

  Future<DataSnapshot> get() async {
    if (!_hasQuery) {
      final value = await _client.getValue(_dbName, _path);
      return DataSnapshot._(_lastSegment(_path), value);
    }
    final res = await _client.query(_dbName, _path, _params);
    final order = (res['order'] as List?)?.cast<String>() ?? const [];
    final values = (res['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ordered = _buildOrdered(values, order);
    return DataSnapshot._(_lastSegment(_path), ordered);
  }

  /// Loads a location without heavy child subtrees (menu/products) — much faster
  /// for shop listings and checkout validation.
  Future<DataSnapshot> getShallow() async {
    final value = await _client.getValue(_dbName, _path, shallow: true);
    return DataSnapshot._(_lastSegment(_path), value);
  }

  Stream<DatabaseEvent> get onValue => _stream('value');
  Stream<DatabaseEvent> get onChildAdded => _stream('child_added');
  Stream<DatabaseEvent> get onChildChanged => _stream('child_changed');
  Stream<DatabaseEvent> get onChildRemoved => _stream('child_removed');

  Stream<DatabaseEvent> _stream(String event) {
    return _client
        .subscribe(
          db: _dbName,
          path: _path,
          event: event,
          query: _hasQuery ? _params : null,
        )
        .map((e) {
      if (e.event == 'value') {
        final value = e.order != null && e.value is Map
            ? _buildOrdered(
                (e.value as Map).cast<String, dynamic>(), e.order!)
            : e.value;
        return DatabaseEvent._(DataSnapshot._(_lastSegment(_path), value));
      }
      return DatabaseEvent._(
        DataSnapshot._(e.key, e.value),
        previousChildKey: e.previousChildKey,
      );
    });
  }
}

class DatabaseReference extends Query {
  DatabaseReference._(String dbName, String path) : super._(dbName, path);

  String? get key => _lastSegment(_path);

  String get path => _path;

  DatabaseReference child(String path) =>
      DatabaseReference._(_dbName, _join(_path, path));

  DatabaseReference get parent {
    final p = _normalize(_path);
    final i = p.lastIndexOf('/');
    return DatabaseReference._(_dbName, i < 0 ? '' : p.substring(0, i));
  }

  DatabaseReference get root => DatabaseReference._(_dbName, '');

  DatabaseReference push() =>
      DatabaseReference._(_dbName, _join(_path, PushIdGenerator.generate()));

  Future<void> set(Object? value) => _client.setValue(_dbName, _path, value);

  Future<void> update(Map<String, Object?> value) =>
      _client.updateValue(_dbName, _path, value);

  Future<void> remove() => _client.removeValue(_dbName, _path);

  Future<void> setPriority(Object? priority) async {}

  Future<TransactionResult> runTransaction(
    Transaction Function(Object? currentData) handler, {
    bool applyLocally = true,
  }) async {
    Object? current = await _client.getValue(_dbName, _path);
    for (var attempt = 0; attempt < 25; attempt++) {
      final t = handler(current);
      if (t.aborted) {
        return TransactionResult._(false, DataSnapshot._(key, current));
      }
      final res =
          await _client.compareAndSet(_dbName, _path, current, t.value);
      if (res['committed'] == true) {
        return TransactionResult._(true, DataSnapshot._(key, t.value));
      }
      current = res['current'];
    }
    return TransactionResult._(false, DataSnapshot._(key, current));
  }

  OnDisconnect onDisconnect() => OnDisconnect._();
}

/// No-op onDisconnect handler (Firebase feature not needed by this app).
class OnDisconnect {
  OnDisconnect._();
  Future<void> set(Object? value) async {}
  Future<void> update(Map<String, Object?> value) async {}
  Future<void> remove() async {}
  Future<void> cancel() async {}
}

class DatabaseEvent {
  DatabaseEvent._(this.snapshot, {this.previousChildKey});
  final DataSnapshot snapshot;
  final String? previousChildKey;
}

class DataSnapshot {
  DataSnapshot._(this.key, this.value);

  final String? key;
  final Object? value;

  bool get exists => value != null;

  DataSnapshot child(String path) {
    Object? node = value;
    for (final seg in _normalize(path).split('/')) {
      if (seg.isEmpty) continue;
      if (node is Map) {
        node = (node)[seg];
      } else if (node is List) {
        final idx = int.tryParse(seg);
        node = (idx != null && idx >= 0 && idx < node.length) ? node[idx] : null;
      } else {
        node = null;
      }
    }
    return DataSnapshot._(_lastSegment(path), node);
  }

  bool hasChild(String path) => child(path).exists;

  Iterable<DataSnapshot> get children {
    final v = value;
    if (v is Map) {
      return v.entries
          .map((e) => DataSnapshot._(e.key.toString(), e.value));
    }
    if (v is List) {
      return List.generate(
          v.length, (i) => DataSnapshot._(i.toString(), v[i]));
    }
    return const <DataSnapshot>[];
  }
}

class Transaction {
  Transaction._(this.value, this.aborted);
  final Object? value;
  final bool aborted;

  static Transaction success(Object? value) => Transaction._(value, false);
  static Transaction abort() => Transaction._(null, true);
}

class TransactionResult {
  TransactionResult._(this.committed, this.snapshot);
  final bool committed;
  final DataSnapshot snapshot;
}

/// Rebuild an insertion-ordered map from a query's ordered key list.
Map<String, dynamic> _buildOrdered(
    Map<String, dynamic> values, List<String> order) {
  final out = <String, dynamic>{};
  for (final k in order) {
    if (values.containsKey(k)) out[k] = values[k];
  }
  // Include any stragglers not present in order (defensive).
  for (final e in values.entries) {
    out.putIfAbsent(e.key, () => e.value);
  }
  return out;
}

/// Firebase-style 20-char push ids: time-ordered and unique.
class PushIdGenerator {
  static const _chars =
      '-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz';
  static final _random = Random();
  static int _lastPushTime = 0;
  static final List<int> _lastRandChars = List<int>.filled(12, 0);

  static String generate() {
    var now = DateTime.now().millisecondsSinceEpoch;
    final duplicateTime = now == _lastPushTime;
    _lastPushTime = now;

    final timeStampChars = List<String>.filled(8, '');
    for (var i = 7; i >= 0; i--) {
      timeStampChars[i] = _chars[now % 64];
      now = now ~/ 64;
    }
    var id = timeStampChars.join();

    if (!duplicateTime) {
      for (var i = 0; i < 12; i++) {
        _lastRandChars[i] = _random.nextInt(64);
      }
    } else {
      var i = 11;
      for (; i >= 0 && _lastRandChars[i] == 63; i--) {
        _lastRandChars[i] = 0;
      }
      if (i >= 0) _lastRandChars[i]++;
    }
    for (var i = 0; i < 12; i++) {
      id += _chars[_lastRandChars[i]];
    }
    return id;
  }
}
