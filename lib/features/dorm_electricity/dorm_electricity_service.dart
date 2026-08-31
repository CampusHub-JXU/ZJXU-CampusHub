import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logging/app_logger.dart';
import 'epay_electricity_gateway.dart';

/// 宿舍电费服务异常：携带可直接展示给用户的 [message]。
class DormServiceException implements Exception {
  final String message;

  const DormServiceException(this.message);

  @override
  String toString() => message;
}

/// 园区（校区）——epay100 电控体系第一级。
class DormArea {
  final String id;
  final String name;

  const DormArea({required this.id, required this.name});
}

/// 楼幢——第二级，隶属园区。
class DormBuilding {
  final String areaId;
  final String areaName;
  final String buildingId;
  final String buildingName;

  const DormBuilding({
    required this.areaId,
    required this.areaName,
    required this.buildingId,
    required this.buildingName,
  });
}

/// 楼层——第三级（多数楼幢只有一个「默认楼层」）。
class DormFloor {
  final String areaId;
  final String buildingId;
  final String floorId;
  final String floorName;

  const DormFloor({
    required this.areaId,
    required this.buildingId,
    required this.floorId,
    required this.floorName,
  });
}

/// 房间——第四级。
class DormRoom {
  final String areaId;
  final String buildingId;
  final String floorId;
  final String roomId;
  final String floorName;
  final String roomName;

  const DormRoom({
    required this.areaId,
    required this.buildingId,
    required this.floorId,
    required this.roomId,
    required this.floorName,
    required this.roomName,
  });
}

/// 已保存的寝室配置（epay100 电控四级 id）。
class DormRoomConfig {
  final String areaId;
  final String buildingId;
  final String floorId;
  final String roomId;

  const DormRoomConfig({
    required this.areaId,
    required this.buildingId,
    required this.floorId,
    required this.roomId,
  });
}

/// 宿舍电费服务：数据源为 epay100 新版电控（老 jdhq.wap 系统已于 2026-08
/// 下线）。RPC 经 [EpayElectricityGateway] 在隐藏 WebView 页面上下文发出，
/// 会话不可用时抛 [EpaySessionUnavailableException]，由本层转译为
/// [_lastError] 并回退缓存。
class DormElectricityService {
  DormElectricityService._();
  static final DormElectricityService instance = DormElectricityService._();

  static const _keyAreaId = 'dorm_epay_area_id';
  static const _keyBuildingId = 'dorm_epay_building_id';
  static const _keyFloorId = 'dorm_epay_floor_id';
  static const _keyRoomId = 'dorm_epay_room_id';
  // 老系统（jdhq.wap）遗留键，迁移时清除。
  static const _legacyKeys = [
    'dorm_community_id',
    'dorm_building_id',
    'dorm_floor_id',
    'dorm_room_id',
  ];
  static const _keyElectricity = 'dorm_cached_electricity';
  static const _keyElectricityUpdatedAt = 'dorm_cached_electricity_updated_at';
  static const _keyAlertEnabled = 'dorm_alert_enabled';
  static const _keyAlertThreshold = 'dorm_alert_threshold';
  static const _keyAlertLastNotifiedDate = 'dorm_alert_last_notified_date';
  static const refreshWindow = Duration(minutes: 30);

  /// 电控适配器（麦狐统一前置 API）。网关会话里也可动态读取，
  /// 这里作为缺省值兜底。
  static const defaultAdapterId = '6279260700100006';

  /// 从房间名解析楼层标签：`HX4-105` → `1楼`，`HX4-1005` → `10楼`。
  ///
  /// 约定 `-` 后数字串的末两位为房间序号、其余为楼层号；解析不出
  ///（无数字段 / 序号不足两位）返回 null，该房间不参与楼层筛选分组。
  static String? parseFloorLabel(String roomName) {
    final match = RegExp(r'-(\d{3,})号?$').firstMatch(roomName.trim());
    final digits = match?.group(1);
    if (digits == null || digits.length < 3) return null;
    final floor = int.tryParse(digits.substring(0, digits.length - 2));
    final seq = int.tryParse(digits.substring(digits.length - 2));
    if (floor == null || seq == null) return null;
    return '$floor楼';
  }

  @visibleForTesting
  EpayElectricityGateway gateway = EpayElectricityGateway.instance;

  SharedPreferences? _prefs;
  bool _cacheRestored = false;
  Future<double?>? _fetchElectricityFuture;

  double? _cachedElectricity;
  DateTime? _lastUpdated;
  double? get cachedElectricity => _cachedElectricity;
  DateTime? get lastUpdated => _lastUpdated;
  bool get hasFreshCache {
    final updatedAt = _lastUpdated;
    if (_cachedElectricity == null || updatedAt == null) return false;
    return DateTime.now().difference(updatedAt) <= refreshWindow;
  }

  String? _lastError;
  String? get lastError => _lastError;
  bool _requiresAuthentication = false;
  bool get requiresAuthentication => _requiresAuthentication;

  @visibleForTesting
  void debugSetGateway(EpayElectricityGateway value) => gateway = value;

  Future<void> invalidateGatewaySession() => gateway.invalidate();

  Future<void> restoreCache({bool force = false}) async {
    if (_cacheRestored && !force) return;
    final prefs = await _ensurePrefs();
    // 老系统 id 空间与 epay100 不兼容，一次性清除遗留配置。
    var removedLegacyConfig = false;
    for (final key in _legacyKeys) {
      if (prefs.containsKey(key)) {
        await prefs.remove(key);
        removedLegacyConfig = true;
      }
    }
    if (removedLegacyConfig) {
      await prefs.remove(_keyElectricity);
      await prefs.remove(_keyElectricityUpdatedAt);
      await prefs.remove(_keyAlertLastNotifiedDate);
    }
    _cachedElectricity = prefs.getDouble(_keyElectricity);
    final updatedAtMillis = prefs.getInt(_keyElectricityUpdatedAt);
    if (updatedAtMillis != null) {
      _lastUpdated = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
    }
    _cacheRestored = true;
  }

  Future<bool> hasRoomConfig() async {
    final config = await loadRoomConfig();
    return config != null;
  }

  Future<DormRoomConfig?> loadRoomConfig() async {
    final prefs = await _ensurePrefs();
    final areaId = prefs.getString(_keyAreaId);
    final buildingId = prefs.getString(_keyBuildingId);
    final floorId = prefs.getString(_keyFloorId);
    final roomId = prefs.getString(_keyRoomId);
    if (areaId == null ||
        buildingId == null ||
        floorId == null ||
        roomId == null) {
      return null;
    }
    return DormRoomConfig(
      areaId: areaId,
      buildingId: buildingId,
      floorId: floorId,
      roomId: roomId,
    );
  }

  Future<void> saveRoomConfig(DormRoomConfig config) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_keyAreaId, config.areaId);
    await prefs.setString(_keyBuildingId, config.buildingId);
    await prefs.setString(_keyFloorId, config.floorId);
    await prefs.setString(_keyRoomId, config.roomId);
    // 余额必须和房间配置绑定；保存后强制下一次查询新房间，绝不能回退到
    // 上一个寝室的缓存值。
    await prefs.remove(_keyElectricity);
    await prefs.remove(_keyElectricityUpdatedAt);
    await prefs.remove(_keyAlertLastNotifiedDate);
    _cachedElectricity = null;
    _lastUpdated = null;
    _lastError = null;
  }

  Future<void> clearRoomConfig() async {
    final prefs = await _ensurePrefs();
    for (final key in [_keyAreaId, _keyBuildingId, _keyFloorId, _keyRoomId]) {
      await prefs.remove(key);
    }
    await prefs.remove(_keyElectricity);
    await prefs.remove(_keyElectricityUpdatedAt);
    _cachedElectricity = null;
    _lastUpdated = null;
    _lastError = null;
  }

  // ── 低电量预警 ──

  Future<bool> getAlertEnabled() async {
    final prefs = await _ensurePrefs();
    return prefs.getBool(_keyAlertEnabled) ?? false;
  }

  Future<void> setAlertEnabled(bool value) async {
    final prefs = await _ensurePrefs();
    await prefs.setBool(_keyAlertEnabled, value);
  }

  static const double defaultAlertThreshold = 20;

  Future<double> getAlertThreshold() async {
    final prefs = await _ensurePrefs();
    return prefs.getDouble(_keyAlertThreshold) ?? defaultAlertThreshold;
  }

  Future<void> setAlertThreshold(double value) async {
    final prefs = await _ensurePrefs();
    await prefs.setDouble(_keyAlertThreshold, value);
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> checkAndAlert({
    required void Function({required double value, required double threshold})
    onAlert,
  }) async {
    final enabled = await getAlertEnabled();
    if (!enabled) return;

    final hasConfig = await hasRoomConfig();
    if (!hasConfig) return;

    final electricity = await fetchElectricity();
    if (electricity == null) return;

    final threshold = await getAlertThreshold();
    if (electricity >= threshold) {
      final prefs = await _ensurePrefs();
      await prefs.remove(_keyAlertLastNotifiedDate);
      return;
    }

    final prefs = await _ensurePrefs();
    final lastNotified = prefs.getString(_keyAlertLastNotifiedDate);
    final today = _todayString();
    if (lastNotified == today) return;

    onAlert(value: electricity, threshold: threshold);
    await prefs.setString(_keyAlertLastNotifiedDate, today);
  }

  // ── RPC：四级目录 + 余额 ─────────────────────────────────────────────────

  /// 园区（校区）列表。
  Future<List<DormArea>> fetchAreas() async {
    final body = await _call('app.electric.getAreaList', {
      'adapter_id': defaultAdapterId,
    });
    final data = _decodeDataMap(body, '园区');
    final list = (data['area_list'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(
          (a) => DormArea(
            id: a['id'].toString(),
            name: a['value'] as String? ?? a['name'] as String? ?? '',
          ),
        )
        .toList();
  }

  /// 指定园区下的楼幢列表。
  Future<List<DormBuilding>> fetchBuildings(DormArea area) async {
    final body = await _call('app.electric.getBuildingList', {
      'adapter_id': defaultAdapterId,
      'L1_area_id': area.id,
    });
    final data = _decodeDataMap(body, '楼幢');
    final list = (data['building_list'] as List<dynamic>? ?? const []);
    return list.whereType<Map<String, dynamic>>().map((b) {
      return DormBuilding(
        areaId: area.id,
        areaName: area.name,
        buildingId: b['id'].toString(),
        buildingName: b['name'] as String? ?? '',
      );
    }).toList();
  }

  /// 指定楼幢下的全部房间（逐楼层展开；多数楼幢只有「默认楼层」）。
  Future<List<DormRoom>> fetchRooms({
    required String areaId,
    required String buildingId,
  }) async {
    final floorsBody = await _call('app.electric.getFloorList', {
      'adapter_id': defaultAdapterId,
      'L1_area_id': areaId,
      'L2_building_id': buildingId,
    });
    final floorsData = _decodeDataMap(floorsBody, '楼层');
    final floors = (floorsData['floor_list'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (f) => DormFloor(
            areaId: areaId,
            buildingId: buildingId,
            floorId: f['id'].toString(),
            floorName: f['name'] as String? ?? '',
          ),
        )
        .toList();

    final rooms = <DormRoom>[];
    for (final floor in floors) {
      final roomsBody = await _call('app.electric.getRoomList', {
        'adapter_id': defaultAdapterId,
        'L1_area_id': areaId,
        'L2_building_id': buildingId,
        'L3_floor_id': floor.floorId,
      });
      final roomsData = _decodeDataMap(roomsBody, '房间');
      final list = (roomsData['room_list'] as List<dynamic>? ?? const []);
      rooms.addAll(
        list.whereType<Map<String, dynamic>>().map(
          (r) => DormRoom(
            areaId: areaId,
            buildingId: buildingId,
            floorId: floor.floorId,
            roomId: r['id'].toString(),
            floorName: floor.floorName,
            roomName: r['name'] as String? ?? '',
          ),
        ),
      );
    }
    return rooms;
  }

  /// 查询剩余电量（度）。失败时回退缓存并设置 [_lastError]。
  Future<double?> fetchElectricity({bool forceRefresh = false}) async {
    if (!forceRefresh && hasFreshCache) {
      _lastError = null;
      _requiresAuthentication = false;
      return _cachedElectricity;
    }

    final existing = _fetchElectricityFuture;
    if (existing != null) return existing;

    final future = _fetchElectricityInner(forceRefresh: forceRefresh);
    _fetchElectricityFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_fetchElectricityFuture, future)) {
        _fetchElectricityFuture = null;
      }
    }
  }

  Future<double?> _fetchElectricityInner({bool forceRefresh = false}) async {
    try {
      await restoreCache();

      final config = await loadRoomConfig();
      if (config == null) {
        _lastError = null;
        _requiresAuthentication = false;
        return null;
      }

      final body = await _call('app.electric.getRoomBalance', {
        'adapter_id': defaultAdapterId,
        'L1_area_id': config.areaId,
        'L2_building_id': config.buildingId,
        'L3_floor_id': config.floorId,
        'L4_room_id': config.roomId,
      });
      final data = _decodeDataMap(body, '余额');
      final list = (data['balance_list'] as List<dynamic>? ?? const []);
      String? balanceText;
      for (final b in list.whereType<Map<String, dynamic>>()) {
        if (b['id'].toString() == config.roomId) {
          balanceText = b['balance']?.toString();
          break;
        }
      }
      final value = balanceText == null ? null : double.tryParse(balanceText);
      if (value == null) {
        _lastError = '数据解析失败';
        return _cachedElectricity;
      }
      _cachedElectricity = value;
      _lastUpdated = DateTime.now();
      await _persistCache();
      _lastError = null;
      _requiresAuthentication = false;
      AppLogger.instance.network(LogLevel.info, '电费解析成功: $value 度');
      return value;
    } on EpaySessionUnavailableException catch (e) {
      AppLogger.instance.network(LogLevel.warn, '电费会话不可用: ${e.message}');
      _lastError = e.message;
      _requiresAuthentication = true;
      return _cachedElectricity;
    } on EpayGatewayException catch (e) {
      AppLogger.instance.network(LogLevel.warn, '电费网关请求失败: ${e.message}');
      _lastError = e.message;
      _requiresAuthentication = false;
      return _cachedElectricity;
    } on DormServiceException catch (e) {
      _lastError = e.message;
      _requiresAuthentication = false;
      return _cachedElectricity;
    } catch (e) {
      AppLogger.instance.network(LogLevel.error, '电费查询异常: $e');
      _lastError = '未知错误';
      _requiresAuthentication = false;
      return _cachedElectricity;
    }
  }

  String formatElectricity(double? value) {
    if (value == null) return '--';
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<String> _call(String method, Map<String, String> data) {
    return gateway.call(method, data);
  }

  /// 解析 RPC 响应信封 `{"code":"200","msg":"SUC0000","data":{...}}`。
  Map<String, dynamic> _decodeDataMap(String body, String label) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw DormServiceException('电费$label数据无法识别');
    }
    if (json is! Map<String, dynamic>) {
      throw DormServiceException('电费$label数据格式异常');
    }
    if (json['code']?.toString() != '200') {
      final message = json['msg']?.toString();
      throw DormServiceException(
        message == null || message.isEmpty ? '电费$label请求失败' : message,
      );
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw DormServiceException('电费$label数据为空');
    }
    return data;
  }

  Future<SharedPreferences> _ensurePrefs() async {
    final prefs = _prefs;
    if (prefs != null) return prefs;
    final created = await SharedPreferences.getInstance();
    _prefs = created;
    return created;
  }

  Future<void> _persistCache() async {
    final prefs = await _ensurePrefs();
    final value = _cachedElectricity;
    final updatedAt = _lastUpdated;
    if (value == null || updatedAt == null) return;
    await prefs.setDouble(_keyElectricity, value);
    await prefs.setInt(
      _keyElectricityUpdatedAt,
      updatedAt.millisecondsSinceEpoch,
    );
  }

  @visibleForTesting
  void debugSetCachedElectricity(double? value, {DateTime? updatedAt}) {
    _cachedElectricity = value;
    _lastUpdated = updatedAt;
    _cacheRestored = true;
  }

  @visibleForTesting
  void debugReset() {
    gateway = EpayElectricityGateway.instance;
    _prefs = null;
    _cacheRestored = false;
    _cachedElectricity = null;
    _lastUpdated = null;
    _lastError = null;
    _requiresAuthentication = false;
    _fetchElectricityFuture = null;
  }
}
