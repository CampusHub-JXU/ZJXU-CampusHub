import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

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
    if (response is Exception) throw response;
    return response as String;
  }

  @override
  void debugReset() {
    responses.clear();
    calls.clear();
  }

  @override
  Future<void> invalidate() async {}
}

String _success(Map<String, Object?> data) {
  return jsonEncode({'code': '200', 'msg': 'SUC0000', 'data': data});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

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
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    await DormElectricityService.instance.saveRoomConfig(config);
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
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F00000',
        roomId: '10720',
      );
      await DormElectricityService.instance.saveRoomConfig(config);
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
    await DormElectricityService.instance.saveRoomConfig(
      const DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F00000',
        roomId: '10720',
      ),
    );
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
}
