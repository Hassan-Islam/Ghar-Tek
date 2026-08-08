import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart' as fb;

/// Direct Firebase Realtime Database access. Used as a fallback when the local
/// PostgreSQL backend is unreachable (e.g. phone cannot reach the dev server,
/// or data has not been imported yet).
class FirebaseRtdbBackend {
  fb.FirebaseDatabase _dbFor(String dbName) {
    if (dbName == 'ratings') {
      try {
        return fb.FirebaseDatabase.instanceFor(app: Firebase.app('ratingsApp'));
      } catch (_) {
        return fb.FirebaseDatabase.instance;
      }
    }
    return fb.FirebaseDatabase.instance;
  }

  fb.DatabaseReference _ref(String dbName, String path) {
    final clean = path.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    return clean.isEmpty ? _dbFor(dbName).ref() : _dbFor(dbName).ref(clean);
  }

  Future<Object?> getValue(String dbName, String path) async {
    final snap = await _ref(dbName, path).get();
    return snap.exists ? snap.value : null;
  }

  Future<void> setValue(String dbName, String path, Object? value) =>
      _ref(dbName, path).set(value);

  Future<void> updateValue(
          String dbName, String path, Map<String, Object?> value) =>
      _ref(dbName, path).update(value);

  Future<void> removeValue(String dbName, String path) =>
      _ref(dbName, path).remove();

  Future<Map<String, dynamic>> query(
    String dbName,
    String path,
    Map<String, dynamic> q,
  ) async {
    fb.Query query = _ref(dbName, path);
    final orderBy = q['orderBy']?.toString() ?? 'key';
    if (orderBy == 'child') {
      final childKey = q['childKey']?.toString() ?? '';
      query = query.orderByChild(childKey);
    } else if (orderBy == 'value') {
      query = query.orderByValue();
    } else {
      query = query.orderByKey();
    }
    if (q.containsKey('equalTo')) query = query.equalTo(q['equalTo']);
    if (q.containsKey('startAt')) query = query.startAt(q['startAt']);
    if (q.containsKey('endAt')) query = query.endAt(q['endAt']);
    if (q.containsKey('limitToFirst')) {
      query = query.limitToFirst(q['limitToFirst'] as int);
    }
    if (q.containsKey('limitToLast')) {
      query = query.limitToLast(q['limitToLast'] as int);
    }
    final snap = await query.get();
    if (!snap.exists || snap.value == null) {
      return {'order': <String>[], 'values': <String, dynamic>{}};
    }
    final map = Map<String, dynamic>.from(snap.value as Map);
    return {'order': map.keys.toList(), 'values': map};
  }

  Future<Map<String, dynamic>> compareAndSet(
    String dbName,
    String path,
    Object? expected,
    Object? value,
  ) async {
    final ref = _ref(dbName, path);
    final result = await ref.runTransaction((current) {
      if (_canonical(current) != _canonical(expected)) {
        return fb.Transaction.abort();
      }
      return fb.Transaction.success(value);
    });
    return {
      'committed': result.committed,
      'current': result.snapshot.value,
    };
  }

  String _canonical(Object? v) {
    if (v == null) return 'null';
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '$k:${_canonical(v[k])}').join(',')}}';
    }
    if (v is List) return '[${v.map(_canonical).join(',')}]';
    return v.toString();
  }

  Stream<DbBackendEvent> subscribe({
    required String dbName,
    required String path,
    required String event,
    Map<String, dynamic>? query,
  }) {
    fb.Query q = _ref(dbName, path);
    if (query != null && query.isNotEmpty) {
      final orderBy = query['orderBy']?.toString() ?? 'key';
      if (orderBy == 'child') {
        q = q.orderByChild(query['childKey']?.toString() ?? '');
      } else if (orderBy == 'value') {
        q = q.orderByValue();
      } else {
        q = q.orderByKey();
      }
      if (query.containsKey('equalTo')) q = q.equalTo(query['equalTo']);
      if (query.containsKey('startAt')) q = q.startAt(query['startAt']);
      if (query.containsKey('endAt')) q = q.endAt(query['endAt']);
      if (query.containsKey('limitToFirst')) {
        q = q.limitToFirst(query['limitToFirst'] as int);
      }
      if (query.containsKey('limitToLast')) {
        q = q.limitToLast(query['limitToLast'] as int);
      }
    }

    late final Stream<fb.DatabaseEvent> stream;
    switch (event) {
      case 'child_added':
        stream = q.onChildAdded;
        break;
      case 'child_changed':
        stream = q.onChildChanged;
        break;
      case 'child_removed':
        stream = q.onChildRemoved;
        break;
      default:
        stream = q.onValue;
    }

    return stream.map((e) {
      if (event == 'value') {
        return DbBackendEvent(
          event: 'value',
          value: e.snapshot.exists ? e.snapshot.value : null,
        );
      }
      return DbBackendEvent(
        event: event,
        key: e.snapshot.key,
        value: e.snapshot.value,
        previousChildKey: e.previousChildKey,
      );
    });
  }
}

class DbBackendEvent {
  DbBackendEvent({
    required this.event,
    this.key,
    this.value,
    this.order,
    this.previousChildKey,
  });
  final String event;
  final String? key;
  final Object? value;
  final List<String>? order;
  final String? previousChildKey;
}
