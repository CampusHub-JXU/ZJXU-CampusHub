import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_page.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';

import '../../helpers/test_setup.dart';

class _FakeEpayElectricityGateway implements EpayElectricityGateway {
  int callCount = 0;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    callCount++;
    expect(method, 'app.electric.getRoomBalance');
    expect(data['L1_area_id'], '3');
    expect(data['L2_building_id'], '114');
    expect(data['L3_floor_id'], 'F00000');
    expect(data['L4_room_id'], '10720');
    return jsonEncode({
      'code': '200',
      'msg': 'SUC0000',
      'data': {
        'balance_list': [
          {'id': '10720', 'name': 'HX4-111', 'balance': '66.60'},
        ],
      },
    });
  }

  @override
  void debugReset() {
    callCount = 0;
  }

  @override
  Future<void> invalidate() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('renders configured electricity detail from epay100 gateway', (
    tester,
  ) async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    await DormElectricityService.instance.saveRoomConfig(config);
    final gateway = _FakeEpayElectricityGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(tester.takeException(), isNull);
    expect(gateway.callCount, 1);
    expect(find.text('电量详情'), findsOneWidget);
    expect(find.text('66.60'), findsOneWidget);
    expect(find.text('度'), findsOneWidget);
    expect(find.text('剩余'), findsOneWidget);
    expect(find.text('充足'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
