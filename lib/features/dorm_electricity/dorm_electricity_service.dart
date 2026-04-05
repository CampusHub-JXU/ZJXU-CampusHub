import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/network_settings.dart';
import '../../core/network/proxy_mode.dart';

class DormRoomConfig {
  final String communityId;
  final String buildingId;
  final String floorId;
  final String roomId;

  const DormRoomConfig({
    required this.communityId,
    required this.buildingId,
    required this.floorId,
    required this.roomId,
  });
}

class DormBuilding {
  final String communityId;
  final String buildingId;
  final String communityName;
  final String buildingName;

  const DormBuilding({
    required this.communityId,
    required this.buildingId,
    required this.communityName,
    required this.buildingName,
  });
}

class DormRoom {
  final String floorId;
  final String roomId;
  final String floorName;
  final String roomName;

  const DormRoom({
    required this.floorId,
    required this.roomId,
    required this.floorName,
    required this.roomName,
  });
}

class DormElectricityService {
  DormElectricityService._();
  static final DormElectricityService instance = DormElectricityService._();

  static const _keyCommunityId = 'dorm_community_id';
  static const _keyBuildingId = 'dorm_building_id';
  static const _keyFloorId = 'dorm_floor_id';
  static const _keyRoomId = 'dorm_room_id';

  late final Dio _dio = _createDio();

  double? _cachedElectricity;
  double? get cachedElectricity => _cachedElectricity;

  String? _lastError;
  String? get lastError => _lastError;

  void applyProxyMode() {
    applyProxyModeToDio(
      _dio,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
  }

  Future<bool> hasRoomConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_keyCommunityId) &&
        prefs.containsKey(_keyBuildingId) &&
        prefs.containsKey(_keyFloorId) &&
        prefs.containsKey(_keyRoomId);
  }

  Future<DormRoomConfig?> loadRoomConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final communityId = prefs.getString(_keyCommunityId);
    final buildingId = prefs.getString(_keyBuildingId);
    final floorId = prefs.getString(_keyFloorId);
    final roomId = prefs.getString(_keyRoomId);
    if (communityId == null ||
        buildingId == null ||
        floorId == null ||
        roomId == null) {
      return null;
    }
    return DormRoomConfig(
      communityId: communityId,
      buildingId: buildingId,
      floorId: floorId,
      roomId: roomId,
    );
  }

  Future<void> saveRoomConfig(DormRoomConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCommunityId, config.communityId);
    await prefs.setString(_keyBuildingId, config.buildingId);
    await prefs.setString(_keyFloorId, config.floorId);
    await prefs.setString(_keyRoomId, config.roomId);
  }

  Future<void> clearRoomConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCommunityId);
    await prefs.remove(_keyBuildingId);
    await prefs.remove(_keyFloorId);
    await prefs.remove(_keyRoomId);
    _cachedElectricity = null;
  }

  String _buildQueryUrl(DormRoomConfig config) {
    return 'http://jdhq.wap.zjxu.edu.cn/DormCharge/BaseElect/queryResult'
        '/ele_id/1'
        '/community_id/${config.communityId}'
        '/building_id/${config.buildingId}'
        '/floor_id/${config.floorId}'
        '/room_id/${config.roomId}';
  }

  Future<double?> fetchElectricity() async {
    try {
      final config = await loadRoomConfig();
      if (config == null) return null;

      final url = _buildQueryUrl(config);
      final resp = await _dio.get<List<int>>(url);
      if (resp.data == null) return _cachedElectricity;

      final html = utf8.decode(resp.data!, allowMalformed: true);
      final doc = html_parser.parse(html);
      final text = doc.body?.text ?? '';

      final match = RegExp(
        r'实际剩余电量\s*[（(]度[)）]\s*[:：]\s*([0-9]+(?:\.[0-9]+)?)',
      ).firstMatch(text);

      if (match != null) {
        final value = double.tryParse(match.group(1)!);
        if (value != null) {
          _cachedElectricity = value;
          _lastError = null;
          return value;
        }
      }
      _lastError = null;
      return _cachedElectricity;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        _lastError = '网络超时';
        return _cachedElectricity;
      }
      if (e.type == DioExceptionType.connectionError) {
        _lastError = '网络不可达';
        return null;
      }
      _lastError = '未知错误';
      return _cachedElectricity;
    } catch (e) {
      _lastError = '未知错误';
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

  /// 获取园区+楼幢列表（两级嵌套，无需认证）
  Future<List<DormBuilding>> fetchBuildings() async {
    final resp = await _dio.post<List<int>>(
      'http://jdhq.wap.zjxu.edu.cn/dormcharge/base_elect/getParkBuild/ele_id/1',
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    final json =
        jsonDecode(utf8.decode(resp.data!, allowMalformed: true))
            as Map<String, dynamic>;
    final data = json['data'] as List<dynamic>;
    final result = <DormBuilding>[];
    for (final community in data) {
      final communityId = community['id'].toString();
      final communityName = community['value'] as String;
      for (final building in community['childs'] as List<dynamic>) {
        result.add(
          DormBuilding(
            communityId: communityId,
            buildingId: building['id'].toString(),
            communityName: communityName,
            buildingName: building['value'] as String,
          ),
        );
      }
    }
    return result;
  }

  /// 获取楼层+房间列表（两级嵌套，无需认证）
  Future<List<DormRoom>> fetchRooms(String buildingId) async {
    final resp = await _dio.post<List<int>>(
      'http://jdhq.wap.zjxu.edu.cn/dormcharge/base_elect/getFloorRoom/ele_id/1',
      data: 'building_id=$buildingId',
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    final json =
        jsonDecode(utf8.decode(resp.data!, allowMalformed: true))
            as Map<String, dynamic>;
    final data = json['data'] as List<dynamic>;
    final result = <DormRoom>[];
    for (final floor in data) {
      final floorId = floor['id'].toString();
      final floorName = floor['value'] as String;
      for (final room in floor['childs'] as List<dynamic>) {
        result.add(
          DormRoom(
            floorId: floorId,
            roomId: room['id'].toString(),
            floorName: floorName,
            roomName: room['value'] as String,
          ),
        );
      }
    }
    return result;
  }

  Dio _createDio() {
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'X-Requested-With': 'XMLHttpRequest',
        },
        responseType: ResponseType.bytes,
      ),
    );
    applyProxyModeToDio(
      client,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
    return client;
  }
}
