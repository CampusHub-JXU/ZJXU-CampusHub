import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_page.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';

import '../../helpers/test_setup.dart';

class _FakeEpayElectricityGateway implements EpayElectricityGateway {
  int callCount = 0;

  /// 设置后，下一次 [call] 会挂起直到该 completer 完成，用于观察刷新中的 UI 状态。
  Completer<void>? gate;

  /// 设置后，[call] 抛统一认证会话不可用，用于验证错误横幅与登录入口。
  bool failWithAuth = false;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    callCount++;
    final pending = gate;
    if (pending != null) {
      await pending.future;
    }
    if (failWithAuth) {
      throw const EpaySessionUnavailableException('请先登录统一认证后重试');
    }
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

  testWidgets('recharge failure auto-copies link and copy action copies url', (
    tester,
  ) async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    await DormElectricityService.instance.saveRoomConfig(config);
    DormElectricityService.instance.debugSetGateway(
      _FakeEpayElectricityGateway(),
    );

    const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async => false);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(wechatChannel, null);
    });
    final clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    await tester.ensureVisible(find.text('去微信充值'));
    await tester.tap(find.text('去微信充值'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(clipboard, [DormElectricityService.rechargeUrl]);
    expect(find.text('未能打开页面，充值链接已复制，请到微信中打开'), findsOneWidget);
    expect(find.textContaining('已安装微信'), findsNothing);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(clipboard, [
      DormElectricityService.rechargeUrl,
      DormElectricityService.rechargeUrl,
    ]);
    expect(find.text('链接已复制'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('prominent refresh button refetches without blanking content', (
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

    expect(gateway.callCount, 1);
    expect(find.text('刷新电量'), findsOneWidget);
    // 微信充值降级为小号次级入口，但仍在页面上。
    expect(find.text('去微信充值'), findsOneWidget);

    await tester.ensureVisible(find.text('刷新电量'));
    gateway.gate = Completer<void>();
    await tester.tap(find.text('刷新电量'));
    await tester.pump();
    await tester.pump();

    // 刷新过程中保留详情内容，只切换按钮态，不整页转圈。
    expect(find.text('正在刷新'), findsOneWidget);
    expect(find.text('电量详情'), findsOneWidget);

    gateway.gate!.complete();
    gateway.gate = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(gateway.callCount, 2);
    expect(find.text('刷新电量'), findsOneWidget);
    expect(find.text('66.60'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('auth error banner keeps a muted tone and a short login action', (
    tester,
  ) async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    await DormElectricityService.instance.saveRoomConfig(config);
    DormElectricityService.instance.debugSetGateway(
      _FakeEpayElectricityGateway()..failWithAuth = true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // 错误横幅正文收敛为一句「电费获取失败，登录一卡通后重试」，动作交给短按钮。
    expect(find.text('电费获取失败，登录一卡通后重试'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    expect(find.text('请先登录统一认证后重试'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'refresh button follows the theme seed instead of a fixed color',
    (tester) async {
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F00000',
        roomId: '10720',
      );
      await DormElectricityService.instance.saveRoomConfig(config);
      DormElectricityService.instance.debugSetGateway(
        _FakeEpayElectricityGateway(),
      );

      Future<Color?> buttonColorFor(Color seed) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppThemeBuilder.light(seed),
            home: const DormElectricityPage(),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.widgetWithText(FilledButton, '刷新电量'),
                matching: find.byType(Material),
              )
              .first,
        );
        return material.color;
      }

      final red = await buttonColorFor(const Color(0xFFB3261E));
      final green = await buttonColorFor(const Color(0xFF2E7D32));

      // 按钮底色必须来自当前主题 seed，而不是写死的品牌色。
      expect(red, isNotNull);
      expect(green, isNotNull);
      expect(red, isNot(green));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
