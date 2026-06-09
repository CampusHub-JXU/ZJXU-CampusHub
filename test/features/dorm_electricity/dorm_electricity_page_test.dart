import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_page.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('renders configured electricity detail without build exceptions', (
    tester,
  ) async {
    const config = DormRoomConfig(
      communityId: '1',
      buildingId: '2',
      floorId: '3',
      roomId: '4',
    );
    await DormElectricityService.instance.saveRoomConfig(config);

    final dio = Dio(BaseOptions(responseType: ResponseType.bytes));
    final adapter = MockHttpClientAdapter()
      ..register(
        'GET',
        '/DormCharge/BaseElect/queryResult/ele_id/1/community_id/1/building_id/2/floor_id/3/room_id/4',
        (_) async => ResponseBody.fromBytes(
          utf8.encode('<html><body>实际剩余电量（度）：66.60</body></html>'),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          },
        ),
      );
    dio.httpClientAdapter = adapter;
    DormElectricityService.instance.debugSetDio(dio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(tester.takeException(), isNull);
    expect(find.text('电量详情'), findsOneWidget);
    expect(find.text('66.60'), findsOneWidget);
    expect(find.text('度'), findsOneWidget);
    expect(find.text('充足'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
