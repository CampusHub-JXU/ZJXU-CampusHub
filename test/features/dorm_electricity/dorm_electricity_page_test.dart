import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_page.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/core/wechat/wechat_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_setup.dart';

class _FakeEpayElectricityGateway implements Epay100Gateway {
  int callCount = 0;

  /// 设置后，下一次 [call] 会挂起直到该 completer 完成，用于观察刷新中的 UI 状态。
  Completer<void>? gate;

  /// 设置后，[call] 抛统一认证会话不可用，用于验证错误横幅与登录入口。
  bool failWithAuth = false;

  /// 设置后，[call] 抛网关网络错误（非认证失效），用于验证保留缓存值。
  bool failWithNetwork = false;

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
    if (failWithNetwork) {
      throw const EpayGatewayException('网络连接失败');
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

/// 身份隔离测试用网关：按**调用时快照**的余额回包（挂起期间改值不影响已
/// 发出的调用），并支持挂起下一笔调用以制造确定性交错。
class _IdentityGateway implements Epay100Gateway {
  _IdentityGateway({this.balance = '66.60'});

  String balance;

  /// 设置后，下一笔（且仅下一笔）[call] 挂起直到该 completer 完成。
  Completer<void>? gate;

  int callCount = 0;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    callCount++;
    final callBalance = balance;
    final pending = gate;
    gate = null;
    if (pending != null) {
      await pending.future;
    }
    return jsonEncode({
      'code': '200',
      'msg': 'SUC0000',
      'data': {
        'balance_list': [
          {'id': data['L4_room_id'], 'name': 'room', 'balance': callBalance},
        ],
      },
    });
  }

  @override
  void debugReset() {
    callCount = 0;
    gate = null;
  }

  @override
  Future<void> invalidate() async {}
}

/// 记录式 WechatGateway 替身：openUrl / openApp 结果可配置。
class _FakeWechatGateway implements WechatGateway {
  _FakeWechatGateway({
    this.openUrlResult = const WechatLaunchResult(
      status: WechatLaunchStatus.launched,
      sanitizedUrl: '',
    ),
  });

  WechatLaunchResult openUrlResult;
  WechatLaunchResult openAppResult = const WechatLaunchResult(
    status: WechatLaunchStatus.launched,
    sanitizedUrl: '',
  );

  final urls = <String>[];
  int openAppCalls = 0;

  @override
  Future<WechatLaunchResult> openUrl(String sanitizedUrl) async {
    urls.add(sanitizedUrl);
    return openUrlResult;
  }

  @override
  Future<WechatLaunchResult> openApp() async {
    openAppCalls++;
    return openAppResult;
  }
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

  // flutter_local_notifications 的 Android 实现通道：低电量通知必须可观测，
  // 正 / 负向都断言真实发出的通知数。
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  late List<MethodCall> notificationCalls;

  setUpAll(() {
    // widget 测试默认平台为 android，但插件实现不经 GeneratedPluginRegistrant
    // 注册；手动注册后通知才走可 mock 的方法通道。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() async {
    await resetTestEnvironment();
    notificationCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, (call) async {
          notificationCalls.add(call);
          // initialize 期望返回 bool；其余通道方法接受 null。
          return call.method == 'initialize' ? true : null;
        });
  });

  tearDown(() {
    WechatLauncher.instance.setGatewayForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
  });

  List<MethodCall> notificationShows() =>
      notificationCalls.where((call) => call.method == 'show').toList();

  /// 模拟在别处发生的统一认证身份变化（同 campus_card 测试：先改 session
  /// 再广播，页面与服务的监听器都会收到）。
  void switchSession({required bool active, String? account}) {
    UnifiedAuthService.instance.debugSetSession(
      active: active,
      account: account,
    );
    UnifiedAuthService.instance.notifyListeners();
  }

  Future<void> pumpDormPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  testWidgets('renders configured electricity detail from epay100 gateway', (
    tester,
  ) async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
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
    expect(find.text('剩余电量'), findsOneWidget);
    expect(find.text('66.60'), findsOneWidget);
    expect(find.text('度'), findsOneWidget);
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
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    await DormElectricityService.instance.saveRoomConfig(config);
    DormElectricityService.instance.debugSetGateway(
      _FakeEpayElectricityGateway(),
    );

    WechatLauncher.instance.setGatewayForTesting(
      _FakeWechatGateway(
        openUrlResult: const WechatLaunchResult(
          status: WechatLaunchStatus.launchFailed,
          sanitizedUrl: '',
        ),
      ),
    );
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

    await tester.ensureVisible(find.text('充值'));
    await tester.tap(find.text('充值'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(clipboard, ['嘉大微生活']);
    expect(find.text('未能拉起微信，「嘉大微生活」已复制，请在微信「搜一搜」粘贴搜索'), findsOneWidget);
    expect(find.textContaining('已安装微信'), findsNothing);
    expect(find.widgetWithText(SnackBarAction, '复制关键词'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(SnackBarAction, '复制关键词'));
    await tester.tap(find.widgetWithText(SnackBarAction, '复制关键词'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(clipboard, ['嘉大微生活', '嘉大微生活']);
    expect(find.text('关键词已复制'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('status-line refresh icon refetches without blanking content', (
    tester,
  ) async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
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
    // 通栏刷新按钮已移除：刷新收进状态行尾的小图标；充值是三格里的主动作。
    expect(find.text('刷新电量'), findsNothing);
    expect(find.byTooltip('刷新电量'), findsOneWidget);
    expect(find.text('充值'), findsOneWidget);
    expect(find.text('低电提醒'), findsOneWidget);
    expect(find.text('寝室'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '去微信充值'), findsNothing);

    gateway.gate = Completer<void>();
    await tester.tap(find.byTooltip('刷新电量'));
    await tester.pump();
    await tester.pump();

    // 刷新过程中保留详情内容，只点亮状态行，不整页转圈。
    expect(find.textContaining('正在刷新'), findsOneWidget);
    expect(find.text('剩余电量'), findsOneWidget);
    expect(find.text('66.60'), findsOneWidget);

    gateway.gate!.complete();
    gateway.gate = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(gateway.callCount, 2);
    expect(find.textContaining('正在刷新'), findsNothing);
    expect(find.text('66.60'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('读数显示原始余额，低电提醒 / 寝室瓦片与 ⋮ 都能进寝室设置', (tester) async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    await DormElectricityService.instance.saveRoomConfig(config);
    final gateway = _FakeEpayElectricityGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const DormElectricityPage()),
        GoRoute(
          path: '/settings',
          name: 'dorm-electricity-settings',
          builder: (_, _) => const Scaffold(body: Text('寝室设置占位页')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.lightTheme, routerConfig: router),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.text('66.60'), findsOneWidget);
    expect(find.textContaining('满电 100 度'), findsNothing);
    expect(find.text('微信'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);
    // AppBar 只剩 ⋮：原「选择寝室」直达图标已并入第三格瓦片。
    expect(find.byTooltip('选择寝室'), findsNothing);

    Future<void> expectOpensSettings(Future<void> Function() open) async {
      await open();
      await tester.pumpAndSettle();
      expect(find.text('寝室设置占位页'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('剩余电量'), findsOneWidget);
    }

    await expectOpensSettings(() => tester.tap(find.text('低电提醒')));
    await expectOpensSettings(() => tester.tap(find.text('寝室')));
    await expectOpensSettings(() async {
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('刷新电量'), findsOneWidget);
      await tester.tap(find.text('选择寝室'));
    });
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
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
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
    expect(find.widgetWithText(TextButton, '登录'), findsOneWidget);
    expect(find.text('请先登录统一认证后重试'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'recharge button follows the theme seed instead of a fixed color',
    (tester) async {
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F00000',
        roomId: '10720',
      );
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
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
              .ancestor(of: find.text('充值'), matching: find.byType(Material))
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

  // ── 缓存优先首帧 ────────────────────────────────────────────────────────

  testWidgets('有缓存进页：首帧即显示缓存读数，无整页 spinner，新鲜缓存不触网', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _FakeEpayElectricityGateway();
    DormElectricityService.instance.debugSetGateway(gateway);
    DormElectricityService.instance.debugSetCachedElectricity(
      42.5,
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    // 只 pump 一帧：配置 / 网络都还没回来。
    expect(find.text('42.50'), findsOneWidget);
    expect(find.text('尚未配置寝室'), findsNothing);
    expect(find.text('正在获取电量…'), findsNothing);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('42.50'), findsOneWidget);
    expect(gateway.callCount, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无缓存首帧：读数为 --、状态行在取数、充值按钮立即可点、不闪空态', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _FakeEpayElectricityGateway()..gate = Completer<void>();
    DormElectricityService.instance.debugSetGateway(gateway);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    // 配置未知 / 未回来时绝不先闪「尚未配置寝室」。
    expect(find.text('尚未配置寝室'), findsNothing);
    expect(find.text('--'), findsOneWidget);
    expect(find.text('正在获取电量…'), findsOneWidget);
    final recharge = tester.widget<InkWell>(
      find.ancestor(of: find.text('充值'), matching: find.byType(InkWell)).first,
    );
    expect(recharge.onTap, isNotNull);

    gateway.gate!.complete();
    gateway.gate = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('66.60'), findsOneWidget);
    expect(find.text('正在获取电量…'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('刷新失败保留缓存读数，状态行标失败并出现 SnackBar', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _FakeEpayElectricityGateway()..failWithNetwork = true;
    DormElectricityService.instance.debugSetGateway(gateway);
    // 过期缓存：进页即后台强刷。
    DormElectricityService.instance.debugSetCachedElectricity(
      42.5,
      updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );

    await pumpDormPage(tester);

    expect(gateway.callCount, 1);
    expect(find.text('42.50'), findsOneWidget);
    expect(find.textContaining('· 刷新失败'), findsOneWidget);
    expect(find.text('电量刷新失败'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ── 身份切换 / 迟到结果 ──────────────────────────────────────────────────

  testWidgets('切换账号立即清空旧账号电量，新账号未配置时不展示旧值', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _IdentityGateway(balance: '66.60');
    DormElectricityService.instance.debugSetGateway(gateway);

    await pumpDormPage(tester);
    expect(find.text('66.60'), findsOneWidget);
    expect(gateway.callCount, 1);

    // B 登录（B 没有寝室配置）：认证变化必须立即清掉 A 的本地视图，
    // 不允许出现 A 电量的过渡帧。
    switchSession(active: true, account: 'B');
    await tester.pump();

    expect(find.text('66.60'), findsNothing);

    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('尚未配置寝室'), findsOneWidget);
    expect(find.text('剩余电量'), findsNothing);
    expect(find.text('66.60'), findsNothing);
    // B 没有配置：页面不再触网，更不会读 A 的余额。
    expect(gateway.callCount, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A 在途查询换号后被拒绝：不覆盖 B 已展示的电量', (tester) async {
    // A 拥有配置且页面查询已发出（挂起）。
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _IdentityGateway(balance: '66.60');
    final aPending = Completer<void>();
    gateway.gate = aPending;
    DormElectricityService.instance.debugSetGateway(gateway);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(gateway.callCount, 1);
    expect(find.text('66.60'), findsNothing);

    // 换号到 B：页面立即作废 A 的电量视图（房间配置是单份 owner 数据，
    // B 此刻还没有自己的配置）。
    switchSession(active: true, account: 'B');
    await tester.pump();
    expect(find.text('66.60'), findsNothing);
    await DormElectricityService.instance.saveRoomConfig(_configB);

    // B 同账号重登推进 revision，页面为 B 重新查询并展示 B 的电量。
    gateway.balance = '7.50';
    switchSession(active: false, account: null);
    switchSession(active: true, account: 'B');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(gateway.callCount, 2);
    expect(find.text('7.50'), findsOneWidget);

    // A 的挂起请求现在才返回：必须被拒绝，绝不覆盖 B 已展示的值。
    aPending.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.text('7.50'), findsOneWidget);
    expect(find.text('66.60'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同账号重登推进 revision：旧请求的挂起结果被丢弃', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);

    final gateway = _IdentityGateway(balance: '66.60');
    final oldPending = Completer<void>();
    gateway.gate = oldPending;
    DormElectricityService.instance.debugSetGateway(gateway);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(gateway.callCount, 1);

    // 同账号重登（登出 + 再登录）：账号仍是 A，但 sessionRevision 已推进，
    // 旧请求的迟到结果必须整体丢弃。
    gateway.balance = '12.34';
    switchSession(active: false, account: null);
    await tester.pump();
    expect(find.text('66.60'), findsNothing);
    expect(find.text('尚未配置寝室'), findsOneWidget);

    switchSession(active: true, account: 'A');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(gateway.callCount, 2);
    expect(find.text('12.34'), findsOneWidget);

    oldPending.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.text('12.34'), findsOneWidget);
    expect(find.text('66.60'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无主遗留配置（无 owner 标记）按未配置处理且不查询', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dorm_epay_area_id', _configA.areaId);
    await prefs.setString('dorm_epay_building_id', _configA.buildingId);
    await prefs.setString('dorm_epay_floor_id', _configA.floorId);
    await prefs.setString('dorm_epay_room_id', _configA.roomId);
    await prefs.setDouble('dorm_cached_electricity', 88.8);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setBool('dorm_alert_enabled', true);
    await prefs.setDouble('dorm_alert_threshold', 5);

    switchSession(active: true, account: '20260001');
    final gateway = _IdentityGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    await pumpDormPage(tester);

    // fail closed：不展示、不查询、不回退无主缓存。
    expect(find.text('尚未配置寝室'), findsOneWidget);
    expect(find.text('88.80'), findsNothing);
    expect(find.text('剩余电量'), findsNothing);
    expect(gateway.callCount, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('在别处登出立即清空电量并回落既有空态，不自动弹登录、不再触网', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _IdentityGateway(balance: '66.60');
    DormElectricityService.instance.debugSetGateway(gateway);

    await pumpDormPage(tester);
    expect(find.text('66.60'), findsOneWidget);

    switchSession(active: false, account: null);
    await tester.pump();
    expect(find.text('66.60'), findsNothing);

    await tester.pump(const Duration(milliseconds: 900));
    // 既有空态（不新增登录闸页 / 不自动弹登录弹窗）。
    expect(find.text('尚未配置寝室'), findsOneWidget);
    expect(find.text('登录一卡通'), findsNothing);
    expect(find.text('电费获取失败，登录一卡通后重试'), findsNothing);
    // 登出后不再触网。
    expect(gateway.callCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('刷新在途时换号：旧刷新不得把 A 的值或点亮态留在 B', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    final gateway = _IdentityGateway(balance: '66.60');
    DormElectricityService.instance.debugSetGateway(gateway);

    await pumpDormPage(tester);
    expect(find.text('66.60'), findsOneWidget);

    // 手动刷新挂起（不覆盖内容，只点亮状态行）。
    final aPending = Completer<void>();
    gateway.gate = aPending;
    await tester.tap(find.byTooltip('刷新电量'));
    await tester.pump();
    expect(find.textContaining('正在刷新'), findsOneWidget);
    expect(find.text('66.60'), findsOneWidget);

    // 换号到 B（无配置）：A 的刷新视图与点亮态立即作废。
    switchSession(active: true, account: 'B');
    await tester.pump();
    expect(find.text('66.60'), findsNothing);

    aPending.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.text('尚未配置寝室'), findsOneWidget);
    expect(find.text('66.60'), findsNothing);
    expect(find.textContaining('正在刷新'), findsNothing);
    expect(gateway.callCount, 2);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ── 低电量通知身份守卫 ──────────────────────────────────────────────────

  testWidgets('低电量预警按身份下发一次通知（正向对照）', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(20);
    DormElectricityService.instance.debugSetGateway(
      _IdentityGateway(balance: '5.00'),
    );

    await pumpDormPage(tester);
    await tester.pump();

    expect(find.text('5'), findsOneWidget);
    expect(find.text('不足'), findsOneWidget);

    final shows = notificationShows();
    expect(shows, hasLength(1));
    final arguments = shows.single.arguments as Map<Object?, Object?>;
    expect(arguments['id'], 100);
    expect(arguments['title'], '寝室电费不足');
    expect(arguments['body'], '剩余电量 5 度，低于 20 度阈值，请及时充值');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A 的查询在换号后返回：绝不在 B 身份下发 A 的低电量通知', (tester) async {
    switchSession(active: true, account: 'A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(20);

    final gateway = _IdentityGateway(balance: '5.00');
    final aPending = Completer<void>();
    gateway.gate = aPending;
    DormElectricityService.instance.debugSetGateway(gateway);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DormElectricityPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(gateway.callCount, 1);

    // 换号到 B（B 没有任何配置）：A 的加载 / 预警检查全部作废。
    switchSession(active: true, account: 'B');
    await tester.pump();
    expect(find.text('5'), findsNothing);

    aPending.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(notificationShows(), isEmpty);
    expect(find.text('5'), findsNothing);
    expect(find.text('尚未配置寝室'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
