import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'city_scope_service.dart';

/// In-memory cache for shop metadata (no menus). Speeds up checkout and shops tab.
class ShopsCacheService {
  ShopsCacheService._();
  static final ShopsCacheService instance = ShopsCacheService._();

  static const Duration _ttl = Duration(minutes: 3);

  Map<dynamic, dynamic>? _shops;
  Map<String, dynamic>? _appControl;
  DateTime? _shopsAt;
  DateTime? _appControlAt;
  Future<Map<dynamic, dynamic>>? _shopsInflight;
  Future<Map<String, dynamic>>? _appControlInflight;

  bool get hasShops => _shops != null;

  Future<Map<dynamic, dynamic>> getShopsMap({bool forceRefresh = false}) {
    if (!forceRefresh &&
        _shops != null &&
        _shopsAt != null &&
        DateTime.now().difference(_shopsAt!) < _ttl) {
      return Future.value(_shops!);
    }
    _shopsInflight ??= _fetchShops().whenComplete(() => _shopsInflight = null);
    return _shopsInflight!;
  }

  Future<Map<String, dynamic>> getAppControl({bool forceRefresh = false}) {
    if (!forceRefresh &&
        _appControl != null &&
        _appControlAt != null &&
        DateTime.now().difference(_appControlAt!) < _ttl) {
      return Future.value(_appControl!);
    }
    _appControlInflight ??=
        _fetchAppControl().whenComplete(() => _appControlInflight = null);
    return _appControlInflight!;
  }

  Future<Map<dynamic, dynamic>> _fetchShops() async {
    await CityScopeService.ensureLoaded();
    final snap = await FirebaseDatabase.instance
        .ref(CityScopeService.tenantPath('shops'))
        .getShallow();
    final map = snap.exists && snap.value is Map
        ? Map<dynamic, dynamic>.from(snap.value as Map)
        : <dynamic, dynamic>{};
    _shops = map;
    _shopsAt = DateTime.now();
    return map;
  }

  Future<Map<String, dynamic>> _fetchAppControl() async {
    await CityScopeService.ensureLoaded();
    final snap = await FirebaseDatabase.instance
        .ref(CityScopeService.tenantPath('settings/app-control'))
        .get();
    final map = snap.exists && snap.value is Map
        ? Map<String, dynamic>.from(snap.value as Map)
        : <String, dynamic>{};
    _appControl = map;
    _appControlAt = DateTime.now();
    return map;
  }

  void warmUp() {
    getShopsMap();
    getAppControl();
  }

  void invalidate() {
    _shops = null;
    _appControl = null;
    _shopsAt = null;
    _appControlAt = null;
  }
}
