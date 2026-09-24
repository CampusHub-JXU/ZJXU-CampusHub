import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/cache/json_cache_store.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';

import '../../helpers/test_setup.dart';

class _GatewayCall {
  const _GatewayCall(this.method, this.data);

  final String method;
  final Map<String, String> data;
}

class _FakeEpayElectricityGateway implements EpayElectricityGateway {
  final Map<String, List<Object>> responses = {};
  final List<_GatewayCall> calls = [];

  /// 非 null 时，该方法的下一次调用先取走队首响应再挂起，直到 [releaseHold]。
  String? holdMethod;
  Completer<void>? _holdGate;

  bool get holdReached => _holdGate != null;

  void releaseHold() => _holdGate?.complete();

  void enqueue(String method, Object response) {
    responses.putIfAbsent(method, () => []).add(response);
  }

  @override
  Future<String> call(String method, Map<String, String> data) async {
    calls.add(_GatewayCall(method, Map<String, String>.from(data)));
    final queue = responses[method];
    if (queue == null || queue.isEmpty) {
      throw StateError('No fake response for $method');
    }
    final response = queue.removeAt(0);
    if (holdMethod != null && method == holdMethod) {
      holdMethod = null;
      final gate = Completer<void>();
      _holdGate = gate;
      await gate.future;
      _holdGate = null;
    }
    if (response is Exception) throw response;
    return response as String;
  }

  @override
  void debugReset() {
    responses.clear();
    calls.clear();
    holdMethod = null;
    _holdGate = null;
  }

  @override
  Future<void> invalidate() async {}
}

String _success(Map<String, Object?> data) {
  return jsonEncode({'code': '200', 'msg': 'SUC0000', 'data': data});
}

/// 轮询等待异步链路推进（测试无 FakeAsync，用真实微任务 + 极短延迟）。
Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: '等待条件超时');
}

const _configA = DormRoomConfig(
  areaId: '3',
  buildingId: '114',
  floorId: 'F00000',
  roomId: '10720',
);

const _configB = DormRoomConfig(
  areaId: '5',
  buildingId: '220',
  floorId: 'F2',
  roomId: '22018',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? cacheDirectory;

  setUp(() async {
    await resetTestEnvironment();
    JsonCacheStore.instance.debugReset();
    cacheDirectory = await Directory.systemTemp.createTemp(
      'dorm_catalog_cache_test',
    );
    JsonCacheStore.instance.debugDirectoryProvider = () async =>
        cacheDirectory!;
  });

  tearDown(() async {
    await JsonCacheStore.instance.debugClear();
    JsonCacheStore.instance.debugReset();
    cacheDirectory?.deleteSync(recursive: true);
    cacheDirectory = null;
  });

  void loginAs(String account) {
    UnifiedAuthService.instance.debugSetSession(active: true, account: account);
  }

  test('fetchAreas maps epay100 area payload and sends adapter id', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getAreaList',
        _success({
          'area_list': [
            {'id': 3, 'name': '梁林校区'},
            {'id': '5', 'value': '平湖校区'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final areas = await DormElectricityService.instance.fetchAreas();

    expect(areas, hasLength(2));
    expect(areas.first.id, '3');
    expect(areas.first.name, '梁林校区');
    expect(areas.last.id, '5');
    expect(areas.last.name, '平湖校区');
    expect(gateway.calls.single.method, 'app.electric.getAreaList');
    expect(gateway.calls.single.data, {
      'adapter_id': DormElectricityService.defaultAdapterId,
    });
  });

  test('fetchAreas reuses the persisted catalog response', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getAreaList',
        _success({
          'area_list': [
            {'id': '3', 'name': '梁林校区'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final first = await DormElectricityService.instance.fetchAreas();
    final second = await DormElectricityService.instance.fetchAreas();

    expect(first.single.name, '梁林校区');
    expect(second.single.name, '梁林校区');
    expect(gateway.calls, hasLength(1));
  });

  test('fetchBuildings maps buildings for the selected area', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getBuildingList',
        _success({
          'building_list': [
            {'id': 114, 'name': '和兴苑4号楼'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);
    const area = DormArea(id: '3', name: '梁林校区');

    final buildings = await DormElectricityService.instance.fetchBuildings(
      area,
    );

    expect(buildings, hasLength(1));
    expect(buildings.single.areaId, '3');
    expect(buildings.single.areaName, '梁林校区');
    expect(buildings.single.buildingId, '114');
    expect(buildings.single.buildingName, '和兴苑4号楼');
    expect(gateway.calls.single.data['L1_area_id'], '3');
  });

  test('fetchBuildings retries once after a gateway timeout', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getBuildingList',
        const EpayGatewayException('一卡通网关响应超时，请稍后重试'),
      )
      ..enqueue(
        'app.electric.getBuildingList',
        _success({
          'building_list': [
            {'id': 114, 'name': '和兴苑4号楼'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);
    const area = DormArea(id: '3', name: '梁林校区');

    final buildings = await DormElectricityService.instance.fetchBuildings(
      area,
    );

    expect(buildings.single.buildingId, '114');
    expect(gateway.calls, hasLength(2));
  });

  test('fetchBuildings does not retry a binding-required error', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getBuildingList',
        const EpayBindingRequiredException(),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    await expectLater(
      DormElectricityService.instance.fetchBuildings(
        const DormArea(id: '3', name: '梁林校区'),
      ),
      throwsA(isA<EpayBindingRequiredException>()),
    );
    expect(gateway.calls, hasLength(1));
  });

  test(
    'fetchBuildings keeps different area parameters in separate caches',
    () async {
      final gateway = _FakeEpayElectricityGateway()
        ..enqueue(
          'app.electric.getBuildingList',
          _success({
            'building_list': [
              {'id': '114', 'name': '和兴苑4号楼'},
            ],
          }),
        )
        ..enqueue(
          'app.electric.getBuildingList',
          _success({
            'building_list': [
              {'id': '201', 'name': '平湖1号楼'},
            ],
          }),
        );
      DormElectricityService.instance.debugSetGateway(gateway);

      final lianglin = await DormElectricityService.instance.fetchBuildings(
        const DormArea(id: '3', name: '梁林校区'),
      );
      final pinghu = await DormElectricityService.instance.fetchBuildings(
        const DormArea(id: '5', name: '平湖校区'),
      );
      final lianglinAgain = await DormElectricityService.instance
          .fetchBuildings(const DormArea(id: '3', name: '梁林校区'));

      expect(lianglin.single.buildingId, '114');
      expect(pinghu.single.buildingId, '201');
      expect(lianglinAgain.single.buildingId, '114');
      expect(gateway.calls, hasLength(2));
    },
  );

  test('fetchRooms expands floors and preserves hierarchy ids', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getFloorList',
        _success({
          'floor_list': [
            {'id': 'F1', 'name': '一层'},
            {'id': 'F2', 'name': '二层'},
          ],
        }),
      )
      ..enqueue(
        'app.electric.getRoomList',
        _success({
          'room_list': [
            {'id': 10700, 'name': 'HX4-101'},
          ],
        }),
      )
      ..enqueue(
        'app.electric.getRoomList',
        _success({
          'room_list': [
            {'id': 10800, 'name': 'HX4-201'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final rooms = await DormElectricityService.instance.fetchRooms(
      areaId: '3',
      buildingId: '114',
    );

    expect(rooms, hasLength(2));
    expect(rooms.first.areaId, '3');
    expect(rooms.first.buildingId, '114');
    expect(rooms.first.floorId, 'F1');
    expect(rooms.first.floorName, '一层');
    expect(rooms.first.roomId, '10700');
    expect(rooms.last.floorId, 'F2');
    expect(rooms.last.roomId, '10800');
    expect(gateway.calls, hasLength(3));
    expect(gateway.calls[1].data['L3_floor_id'], 'F1');
    expect(gateway.calls[2].data['L3_floor_id'], 'F2');
  });

  test('fetchElectricity parses room balance and persists cache', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getRoomBalance',
        _success({
          'balance_list': [
            {'id': '10720', 'name': 'HX4-111', 'balance': '42.50'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final value = await DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );

    expect(value, 42.5);
    expect(DormElectricityService.instance.cachedElectricity, 42.5);
    expect(DormElectricityService.instance.lastUpdated, isNotNull);
    expect(DormElectricityService.instance.lastError, isNull);
    expect(gateway.calls.single.data['L4_room_id'], '10720');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('dorm_cached_electricity'), 42.5);
    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'A');
  });

  test('fetchAreas throws a friendly error for malformed RPC data', () async {
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue('app.electric.getAreaList', '<html>maintenance</html>');
    DormElectricityService.instance.debugSetGateway(gateway);

    await expectLater(
      DormElectricityService.instance.fetchAreas(),
      throwsA(
        isA<DormServiceException>().having(
          (e) => e.message,
          'message',
          contains('无法识别'),
        ),
      ),
    );
  });

  test(
    'session error returns stale cache and exposes login guidance',
    () async {
      loginAs('A');
      await DormElectricityService.instance.saveRoomConfig(_configA);
      DormElectricityService.instance.debugSetCachedElectricity(
        18.25,
        updatedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final gateway = _FakeEpayElectricityGateway()
        ..enqueue(
          'app.electric.getRoomBalance',
          const EpaySessionUnavailableException('请先登录统一认证'),
        );
      DormElectricityService.instance.debugSetGateway(gateway);

      final value = await DormElectricityService.instance.fetchElectricity(
        forceRefresh: true,
      );

      expect(value, 18.25);
      expect(DormElectricityService.instance.lastError, '请先登录统一认证');
    },
  );

  test('gateway business error returns cache without login wording', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    DormElectricityService.instance.debugSetCachedElectricity(
      21.75,
      updatedAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    final gateway = _FakeEpayElectricityGateway()
      ..enqueue(
        'app.electric.getRoomBalance',
        const EpayGatewayException('电费网关错误: 系统维护中'),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final value = await DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );

    expect(value, 21.75);
    expect(DormElectricityService.instance.lastError, '电费网关错误: 系统维护中');
    expect(DormElectricityService.instance.lastError, isNot(contains('登录')));
  });

  test('late RPC from account A cannot overwrite account B session', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _FakeEpayElectricityGateway()
      ..holdMethod = 'app.electric.getRoomBalance'
      ..enqueue(
        'app.electric.getRoomBalance',
        _success({
          'balance_list': [
            {'id': '10720', 'name': 'HX4-111', 'balance': '77.70'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final aFuture = DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );
    await _waitUntil(() => gateway.holdReached);

    // A 的请求还在途中就切换到 B，并由 B 显式重选寝室。
    loginAs('B');
    await DormElectricityService.instance.saveRoomConfig(_configB);
    DormElectricityService.instance.debugSetCachedElectricity(
      5.5,
      updatedAt: DateTime.now(),
    );

    gateway.releaseHold();
    expect(await aFuture, isNull);

    final prefs = await SharedPreferences.getInstance();
    // A 的迟到结果既不改 B 的内存缓存，也不落盘、不写通知总线。
    expect(DormElectricityService.instance.cachedElectricity, 5.5);
    expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
    expect(DormElectricityService.instance.lastError, isNull);
    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');
  });

  test('B does not reuse the in-flight fetch future of account A', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _FakeEpayElectricityGateway()
      ..holdMethod = 'app.electric.getRoomBalance'
      ..enqueue(
        'app.electric.getRoomBalance',
        _success({
          'balance_list': [
            {'id': '10720', 'name': 'HX4-111', 'balance': '77.70'},
          ],
        }),
      )
      ..enqueue(
        'app.electric.getRoomBalance',
        _success({
          'balance_list': [
            {'id': '22018', 'name': 'PH-101', 'balance': '42.50'},
          ],
        }),
      );
    DormElectricityService.instance.debugSetGateway(gateway);

    final aFuture = DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );
    await _waitUntil(() => gateway.holdReached);

    loginAs('B');
    await DormElectricityService.instance.saveRoomConfig(_configB);
    final bFuture = DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );
    // 复用 A 的 future 就不会有第二次网关调用。
    await _waitUntil(() => gateway.calls.length == 2);

    gateway.releaseHold();
    expect(await aFuture, isNull);
    expect(await bFuture, 42.5);
    expect(DormElectricityService.instance.cachedElectricity, 42.5);
    expect(DormElectricityService.instance.lastError, isNull);
  });

  test(
    'same-account re-login drops the old revision inflight result',
    () async {
      loginAs('A');
      await DormElectricityService.instance.saveRoomConfig(_configA);
      final gateway = _FakeEpayElectricityGateway()
        ..holdMethod = 'app.electric.getRoomBalance'
        ..enqueue(
          'app.electric.getRoomBalance',
          _success({
            'balance_list': [
              {'id': '10720', 'name': 'HX4-111', 'balance': '77.70'},
            ],
          }),
        );
      DormElectricityService.instance.debugSetGateway(gateway);

      final first = DormElectricityService.instance.fetchElectricity(
        forceRefresh: true,
      );
      await _waitUntil(() => gateway.holdReached);

      // 同账号重登：revision 推进，旧 revision 的在途结果必须丢弃。
      UnifiedAuthService.instance.debugSetSession(active: false);
      loginAs('A');

      gateway.releaseHold();
      expect(await first, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(DormElectricityService.instance.cachedElectricity, isNull);
      expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
      expect(DormElectricityService.instance.lastError, isNull);
    },
  );

  test('fetchElectricity never queries when logged out', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    UnifiedAuthService.instance.debugSetSession(active: false);
    final gateway = _FakeEpayElectricityGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    final value = await DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );

    expect(value, isNull);
    expect(gateway.calls, isEmpty);
  });
}
