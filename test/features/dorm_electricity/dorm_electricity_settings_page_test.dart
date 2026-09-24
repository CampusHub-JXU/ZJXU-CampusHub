import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/cache/json_cache_store.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_background.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_settings_page.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';

import '../../helpers/test_setup.dart';

/// 目录 RPC 假网关：只服务寝室配置页用到的园区/楼幢/楼层/房间目录，统计网关
/// 调用与隐藏会话作废次数，可注入认证失效 / 网络未知失败 / 挂起中的迟到响应。
class _FakeCatalogGateway implements EpayElectricityGateway {
  int callCount = 0;
  int invalidateCount = 0;

  /// 非 null 时，[call] 抛出该异常。
  Object? failure;

  /// 非 null 时，该方法的下一次调用挂起至 [completeHold]（[holdReached] 为 true）。
  String? holdMethod;
  Completer<void>? _holdGate;

  /// [completeHold] 后的迟到结果：String → 作为响应返回；异常 → 抛出；
  /// null → 走默认响应。
  Object? holdOutcome;

  bool get holdReached => _holdGate != null;

  void completeHold() {
    _holdGate?.complete();
  }

  @override
  Future<String> call(String method, Map<String, String> data) async {
    callCount++;
    if (holdMethod != null && method == holdMethod) {
      holdMethod = null;
      final gate = Completer<void>();
      _holdGate = gate;
      await gate.future;
      _holdGate = null;
      final outcome = holdOutcome;
      if (outcome is String) return outcome;
      if (outcome != null) throw outcome;
    }
    final error = failure;
    if (error != null) throw error;
    switch (method) {
      case 'app.electric.getAreaList':
        return jsonEncode({
          'code': '200',
          'msg': 'SUC0000',
          'data': {
            'area_list': [
              {'id': '3', 'value': '梁林校区'},
            ],
          },
        });
      case 'app.electric.getBuildingList':
        return jsonEncode({
          'code': '200',
          'msg': 'SUC0000',
          'data': {
            'building_list': [
              {'id': '114', 'name': 'HX4'},
            ],
          },
        });
      case 'app.electric.getFloorList':
        return jsonEncode({
          'code': '200',
          'msg': 'SUC0000',
          'data': {
            'floor_list': [
              {'id': 'F1', 'name': '默认楼层'},
            ],
          },
        });
      case 'app.electric.getRoomList':
        return jsonEncode({
          'code': '200',
          'msg': 'SUC0000',
          'data': {
            'room_list': [
              {'id': '10720', 'name': 'HX4-111'},
            ],
          },
        });
      default:
        fail('寝室配置入口不应调用 $method');
    }
  }

  /// 为 true 时，下一次 [invalidate] 挂起直至 [completeInvalidateHold]，
  /// 用于确定性验证「旧身份迟到的会话作废」竞态。
  bool holdNextInvalidate = false;
  Completer<void>? _invalidateGate;

  bool get invalidateHoldReached => _invalidateGate != null;

  void completeInvalidateHold() {
    _invalidateGate?.complete();
  }

  @override
  Future<void> invalidate() async {
    invalidateCount++;
    if (holdNextInvalidate) {
      holdNextInvalidate = false;
      final gate = Completer<void>();
      _invalidateGate = gate;
      await gate.future;
      _invalidateGate = null;
    }
  }

  @override
  void debugReset() {
    callCount = 0;
    invalidateCount = 0;
    failure = null;
    holdMethod = null;
    holdOutcome = null;
    _holdGate?.complete();
    _holdGate = null;
    holdNextInvalidate = false;
    _invalidateGate?.complete();
    _invalidateGate = null;
  }
}

/// 后台调度替身：只计数「调度 / 取消」的原生副作用，验证旧会话的迟到回调
/// 绝不为新会话调度后台任务（接口契约见 [DormBackgroundScheduler]）。
class _CountingScheduler implements DormBackgroundScheduler {
  int scheduleCalls = 0;
  int cancelCalls = 0;

  @override
  Future<void> registerPeriodicTask() async {
    scheduleCalls++;
  }

  @override
  Future<void> scheduleDailyAlarm() async {
    scheduleCalls++;
  }

  @override
  Future<void> cancelPeriodicTask() async {
    cancelCalls++;
  }

  @override
  Future<void> cancelDailyAlarm() async {
    cancelCalls++;
  }

  @override
  Future<void> showLowElectricityNotification({
    required int id,
    required double value,
    required double threshold,
  }) async {}
}

Widget _app() => MaterialApp(
  theme: AppTheme.lightTheme,
  home: const DormElectricitySettingsPage(),
);

/// 逐帧推进直到 [finder] 出现（登录弹窗含 240ms 转场，需若干帧才构建完成）。
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 12,
}) async {
  for (var i = 0; i < maxPumps && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 推进目录拉取链路直至自然结束（或 [until] 成立）。
///
/// widget 测试跑在 FakeAsync 区，`JsonCacheStore` 的文件 I/O future 不会完成
/// （同 `docs/agents/testing.md` 中 CookieJar FileStorage 的已知问题），
/// `pumpAndSettle` 会被加载转圈拖到超时。这里用 `runAsync` 真实事件窗口放行
/// 磁盘读写，再用假时时钟推进（目录 RPC 失败重试的 600ms 延迟也靠它触发）。
Future<void> _settleCatalog(
  WidgetTester tester, {
  int rounds = 24,
  bool Function()? until,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (until != null && until()) return;
    await tester.runAsync<void>(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCatalogGateway gateway;
  late _CountingScheduler scheduler;
  var loaderCalls = 0;

  setUp(() async {
    await resetTestEnvironment();
    gateway = _FakeCatalogGateway();
    DormElectricityService.instance.debugSetGateway(gateway);
    // 后台调度替身 + 私有写入钩子逐用例重置：调度计数从零开始。
    DormElectricityService.instance.debugPrivateWriteHook = null;
    scheduler = _CountingScheduler();
    DormElectricityBackground.instance.scheduler = scheduler;
    loaderCalls = 0;
    UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
      loaderCalls++;
      return null;
    };
    // 目录缓存走 JSON 文件分桶（JsonCacheStore）：每个用例独立临时目录 +
    // 清空内存镜像，避免上个用例的缓存让本用例跳过网关调用。
    final tempDir = Directory.systemTemp.createTempSync('dorm_settings_test');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    JsonCacheStore.instance.debugReset();
    JsonCacheStore.instance.debugDirectoryProvider = () async => tempDir;
  });

  testWidgets(
    'logged-out entry shows the login gate immediately without spinner or gateway calls',
    (tester) async {
      await tester.pumpWidget(_app());

      // 首帧即整页登录闸门：无转圈、无错误态，且绝不打 epay100 网关。
      expect(find.byType(AuthRequiredView), findsOneWidget);
      expect(find.text('需要登录一卡通后继续'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(AppErrorView), findsNothing);
      expect(gateway.callCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'auto login modal is one-shot and the gate button reopens it after dismiss',
    (tester) async {
      await tester.pumpWidget(_app());
      await _pumpUntilFound(tester, find.byType(LoginShell));

      // 进入页面后一次性自动弹出统一认证登录弹窗，闸门保留在弹窗之下。
      expect(find.byType(LoginShell), findsOneWidget);
      expect(find.byType(AuthRequiredView), findsOneWidget);

      // dismiss（关闭按钮）后保留整页登录闸门。
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginShell), findsNothing);
      expect(find.byType(AuthRequiredView), findsOneWidget);

      // 不再自动重复弹出（无自动弹窗循环）。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(LoginShell), findsNothing);

      // 闸门按钮手动重试 → 再次弹出登录弹窗。
      await tester.tap(find.widgetWithText(FilledButton, '登录一卡通'));
      await _pumpUntilFound(tester, find.byType(LoginShell));
      expect(find.byType(LoginShell), findsOneWidget);

      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginShell), findsNothing);
      // 全程未登录：网关始终没有被调用。
      expect(gateway.callCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'login success from the modal auto-loads the catalog without another tap',
    (tester) async {
      await tester.pumpWidget(_app());
      await _pumpUntilFound(tester, find.byType(LoginShell));
      // 身份未水合时谨慎冷恢复（登录弹窗自身的会话探测也会补读一次）。
      expect(loaderCalls, greaterThanOrEqualTo(1));
      expect(gateway.callCount, 0); // 未登录不打网关

      // 模拟在登录弹窗中登录成功（建立身份 + 弹窗返回 true）。
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      Navigator.of(
        tester.element(find.byType(LoginShell)),
        rootNavigator: true,
      ).pop(true);
      await _settleCatalog(tester);

      // 登录成功立即自动拉取楼幢目录并恢复表单，无需再点任何按钮。
      expect(find.byType(LoginShell), findsNothing);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 只作废 epay100 隐藏会话，随后经既有网关拉目录。
      expect(gateway.invalidateCount, greaterThanOrEqualTo(1));
      expect(gateway.callCount, greaterThanOrEqualTo(1));
      // 园区/楼幢与楼层/房间号选择器已就位（label 中的空格与字形易碎，
      // 按关键片段匹配），两处占位均为「请选择」。
      expect(find.textContaining('园区'), findsOneWidget);
      expect(find.textContaining('房间号'), findsOneWidget);
      expect(find.text('请选择'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unknown gateway failure keeps a retryable error and never forces logout',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      gateway.failure = const EpayGatewayException('一卡通网关网络异常，请稍后重试');

      await tester.pumpWidget(_app());
      await _settleCatalog(tester);

      // 未知网络/网关错误：保留可重试错误态，不进登录闸门、不自动弹登录。
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('一卡通网关网络异常，请稍后重试'), findsOneWidget);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(LoginShell), findsNothing);

      // 全局统一认证会话保持原样（不误判为认证过期、不强制登出）。
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      // 身份已水合（已登录进入），不再做冷恢复。
      expect(loaderCalls, 0);

      // 重试仍然可用。
      final before = gateway.callCount;
      await tester.tap(find.text('重试'));
      await _settleCatalog(tester);
      expect(gateway.callCount, greaterThan(before));
      expect(find.byType(AppErrorView), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'explicit epay session failure while unified auth stays active keeps '
    'reason and retry, not a login gate',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      gateway.failure = const EpaySessionUnavailableException('统一认证已失效，请重新登录');

      await tester.pumpWidget(_app());
      await _settleCatalog(tester);

      // 统一认证仍有效：登录弹窗会被本地登录态「自动登录成功」再重试 epay、
      // 无限循环，因此绝不能出现登录闸门/登录弹窗；只给原始原因 + 重试。
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('统一认证已失效，请重新登录'), findsOneWidget);
      expect(find.byType(AuthRequiredView), findsNothing);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(LoginShell), findsNothing);
      // 全局统一认证会话保持原样（不误判为认证过期、不强制登出/重登）。
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);

      // 重试可用：epay 恢复后直接进表单，无需任何登录动作。
      gateway.failure = null;
      await tester.tap(find.text('重试'));
      await _settleCatalog(tester);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.textContaining('园区'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'explicit session failure with unified auth actually logged out still '
    'shows the login gate',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      gateway.holdMethod = 'app.electric.getAreaList';
      gateway.holdOutcome = const EpaySessionUnavailableException(
        '统一认证已失效，请重新登录',
      );

      await tester.pumpWidget(_app());
      await _settleCatalog(tester, until: () => gateway.holdReached);
      expect(gateway.holdReached, isTrue);

      // 请求在途期间本地统一认证确实失效（生产路径的失效通知随后到达：
      // 静默状态变化下迟到结果一律 fail closed，不写任何 UI）。
      UnifiedAuthService.instance.debugSetSession(active: false);
      UnifiedAuthService.instance.notifyListeners();
      gateway.completeHold();
      await _settleCatalog(tester);

      // 统一认证确实未登录：登录闸门保留，且不自动反复弹登录弹窗。
      expect(find.byType(AuthRequiredView), findsOneWidget);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(LoginShell), findsNothing);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    "account switch with a pending request never blames account B for "
    "account A's auth failure",
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      gateway.holdMethod = 'app.electric.getAreaList';
      gateway.holdOutcome = const EpaySessionUnavailableException(
        '统一认证已失效，请重新登录',
      );

      await tester.pumpWidget(_app());
      await _settleCatalog(tester, until: () => gateway.holdReached);
      expect(gateway.holdReached, isTrue);

      // A 的请求还在途中就切换到 B（两者都处于已登录状态）。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      UnifiedAuthService.instance.notifyListeners();
      await _settleCatalog(tester);

      // A 的迟到认证失效结论到达：绝不能把 B 登出或判定为需登录。
      gateway.completeHold();
      await _settleCatalog(tester);

      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(UnifiedAuthService.instance.currentAccount, 'B');
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(LoginShell), findsNothing);
      // 该次目录拉取按「原始原因 + 重试」错误态呈现（B 仍是登录态）。
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('统一认证已失效，请重新登录'), findsOneWidget);

      // 重试后 B 正常拿到目录。
      await tester.tap(find.text('重试'));
      await _settleCatalog(tester);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.textContaining('园区'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    "account switch discards the old identity's late room result and selection",
    (tester) async {
      // A 保存过寝室配置（F1 / 777 → A-999），拉到房间列表时挂起。
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F1',
        roomId: '777',
      );
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      await DormElectricityService.instance.saveRoomConfig(config);
      gateway.holdMethod = 'app.electric.getRoomList';
      gateway.holdOutcome = jsonEncode({
        'code': '200',
        'msg': 'SUC0000',
        'data': {
          'room_list': [
            {'id': '777', 'name': 'A-999'},
          ],
        },
      });

      await tester.pumpWidget(_app());
      await _settleCatalog(tester, until: () => gateway.holdReached);
      expect(gateway.holdReached, isTrue);

      // 切到 B：先清掉共享寝室配置（B 不恢复任何选择），再换身份。
      await DormElectricityService.instance.clearRoomConfig();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      UnifiedAuthService.instance.notifyListeners();
      await _settleCatalog(tester);
      expect(find.text('请选择'), findsNWidgets(2)); // B 的干净表单

      // A 的迟到房间响应到达：不得把 A 的房间/选择套到 B 的界面。
      gateway.completeHold();
      await _settleCatalog(tester);
      expect(find.textContaining('A-999'), findsNothing);
      expect(find.text('请选择'), findsNWidgets(2));
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(AppErrorView), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    "account A's delayed session invalidation cannot corrupt B's screen "
    'or refetch the catalog',
    (tester) async {
      // A 保存过寝室配置（10720 → HX4-111）；A 的换号重载卡在「作废旧会话」上。
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F1',
        roomId: '10720',
      );
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      // 私有变更队列要求同一 zone 串行（跨 zone 会死锁，见 DormPrivateWrites
      // 的 zone 契约）：全部写入保持在 FakeAsync 测试 zone 内。
      await DormElectricityService.instance.saveRoomConfig(config);
      UnifiedAuthService.instance.debugSetSession(active: false);
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        loaderCalls++;
        return 'A';
      };
      gateway.holdNextInvalidate = true;

      await tester.pumpWidget(_app());
      await _settleCatalog(tester, until: () => gateway.invalidateHoldReached);
      expect(gateway.invalidateHoldReached, isTrue); // A 的作废在途

      // 作废未归就切到 B（B 自己保存寝室，归属独立）。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      await DormElectricityService.instance.saveRoomConfig(config);
      UnifiedAuthService.instance.notifyListeners();
      await _settleCatalog(tester);
      expect(find.textContaining('HX4-111'), findsOneWidget); // B 的表单已就绪

      // B 打开预警（B 有自己的配置 → 开关可用）。
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('预警阈值'), findsOneWidget);
      final callsBeforeLate = gateway.callCount;

      // 冷却目录缓存并把网关改成「命中即挂起」：迟到作废若清掉 B 的界面 /
      // 复活转圈 / 重复拉目录会立刻现形；正常情况下本阶段零网关调用。
      final coldDir = Directory.systemTemp.createTempSync('dorm_settings_cold');
      addTearDown(() {
        try {
          coldDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      DormElectricityService.instance.debugReset();
      DormElectricityService.instance.debugSetGateway(gateway);
      JsonCacheStore.instance.debugReset();
      JsonCacheStore.instance.debugDirectoryProvider = () async => coldDir;
      gateway.holdMethod = 'app.electric.getAreaList';

      gateway.completeInvalidateHold();
      await _settleCatalog(tester, rounds: 8);

      // A 的迟到作废被丢弃：B 的界面原样保留，没有转圈复活、没有重复目录请求。
      expect(gateway.holdReached, isFalse);
      expect(gateway.callCount, callsBeforeLate);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('预警阈值'), findsOneWidget);
      expect(find.textContaining('HX4-111'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(AppErrorView), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    "account A's delayed alert settings cannot switch B's opt-in on",
    (tester) async {
      // A 已保存配置并开启预警；A 的设置读取挂起在「写回界面之前」。
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F1',
        roomId: '10720',
      );
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      // 私有变更队列要求同一 zone 串行（跨 zone 会死锁，见 DormPrivateWrites
      // 的 zone 契约）：全部写入保持在 FakeAsync 测试 zone 内。
      await DormElectricityService.instance.saveRoomConfig(config);
      await DormElectricityService.instance.setAlertEnabled(true);

      final adoptGate = Completer<void>();
      var adoptArmed = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: DormElectricitySettingsPage(
            debugBeforeAlertSettingsAdopt: () {
              if (!adoptArmed) return Future<void>.value();
              adoptArmed = false;
              return adoptGate.future;
            },
          ),
        ),
      );
      await _settleCatalog(tester);
      // A 的表单已就绪；A 读到的「开启」还挂在 adopt 点后，尚未写回界面。
      expect(find.textContaining('HX4-111'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      // 切到 B：B 自己保存配置（归属独立，预警 opt-in 重置为关闭）。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      await DormElectricityService.instance.saveRoomConfig(config);
      UnifiedAuthService.instance.notifyListeners();
      await _settleCatalog(tester);
      expect(find.textContaining('HX4-111'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      // 放行 A 的迟到设置写回：A 读到的是「开启」，绝不能把 B 的开关打开。
      adoptGate.complete();
      await _settleCatalog(tester);
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.value, isFalse); // B 仍保持关闭
      expect(sw.onChanged, isNotNull); // B 有自己的配置，开关可用
      expect(find.text('预警阈值'), findsNothing);
      expect(find.textContaining('HX4-111'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'alert opt-in stays disabled and unswitched until a room config is saved',
    (tester) async {
      // 当前身份没有保存过寝室配置（服务层对无归属的预警写入是 no-op）。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

      await tester.pumpWidget(_app());
      await _settleCatalog(tester);
      expect(find.text('请选择'), findsNWidgets(2));

      // 开关禁用且保持关闭，并提示先保存寝室；阈值行不出现。
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.onChanged, isNull);
      expect(sw.value, isFalse);
      expect(find.text('保存寝室后可开启低电量预警'), findsOneWidget);
      expect(find.text('当剩余电量低于设定阈值时发送提醒'), findsNothing);
      expect(find.text('预警阈值'), findsNothing);

      // 点击禁用开关不得假装开启（写入侧 no-op，界面也不显示已启用）。
      await tester.tap(find.byType(Switch), warnIfMissed: false);
      await tester.pump();
      final sw2 = tester.widget<Switch>(find.byType(Switch));
      expect(sw2.onChanged, isNull);
      expect(sw2.value, isFalse);
      expect(find.text('预警阈值'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    "a silent account switch (no notify) never lets the old identity's late "
    'catalog load repopulate the form',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      gateway.holdMethod = 'app.electric.getAreaList';

      await tester.pumpWidget(_app());
      await _settleCatalog(tester, until: () => gateway.holdReached);
      expect(gateway.holdReached, isTrue);

      // 请求在途期间静默换号（sessionRevision 已推进但尚无监听器通知）。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      gateway.completeHold();
      await _settleCatalog(tester);

      // fail closed：A 的迟到目录绝不填充表单，也不出现反馈/闸门/错误态。
      expect(find.textContaining('园区'), findsNothing);
      expect(find.text('请选择'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(AppErrorView), findsNothing);

      // 延迟到达的通知正常恢复：为新身份重新拉取并展示表单。
      UnifiedAuthService.instance.notifyListeners();
      await _settleCatalog(tester);
      expect(find.text('请选择'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a silent same-account re-login (revision bump, no notify) never applies '
    'late alert settings or schedules background work',
    (tester) async {
      // A 已保存配置并开启预警：迟到读取会携带「开启」。
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F1',
        roomId: '10720',
      );
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      await DormElectricityService.instance.saveRoomConfig(config);
      await DormElectricityService.instance.setAlertEnabled(true);

      final adoptGate = Completer<void>();
      var adoptArmed = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: DormElectricitySettingsPage(
            debugBeforeAlertSettingsAdopt: () {
              if (!adoptArmed) return Future<void>.value();
              adoptArmed = false;
              return adoptGate.future;
            },
          ),
        ),
      );
      await _settleCatalog(tester);
      expect(find.textContaining('HX4-111'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      // 同账号重登（登出再登）：sessionRevision 已推进，但尚无监听器通知。
      UnifiedAuthService.instance.debugSetSession(active: false);
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

      // A 读到的「开启」迟到写回：不得落到重登后的会话界面。
      adoptGate.complete();
      await _settleCatalog(tester);
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.value, isFalse); // 迟到 opt-in 被丢弃
      expect(sw.onChanged, isNotNull);
      expect(find.text('预警阈值'), findsNothing);

      // 通知前用户操作走旧绑定：写入不反馈，也绝不同步后台任务。
      await tester.tap(find.byType(Switch));
      await _settleCatalog(tester);
      expect(scheduler.scheduleCalls, 0);
      expect(scheduler.cancelCalls, 0);
      expect(find.byType(SnackBar), findsNothing);

      // 通知到达后恢复正常：重绑并重载当前会话的设置。
      UnifiedAuthService.instance.notifyListeners();
      await _settleCatalog(tester);
      expect(find.textContaining('HX4-111'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      // 计数器非空验证：新会话的开关切换真实调度 / 取消后台任务。
      await tester.tap(find.byType(Switch)); // 关
      await _settleCatalog(tester);
      await tester.tap(find.byType(Switch)); // 开
      await _settleCatalog(tester);
      expect(scheduler.cancelCalls, greaterThanOrEqualTo(2));
      expect(scheduler.scheduleCalls, greaterThanOrEqualTo(2));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a silent identity change mid-save shows no success or failure feedback '
    'and never pops the page',
    (tester) async {
      // A 已保存配置（10720 → HX4-111）：表单恢复后保存按钮直接可用。
      const config = DormRoomConfig(
        areaId: '3',
        buildingId: '114',
        floorId: 'F1',
        roomId: '10720',
      );
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      await DormElectricityService.instance.saveRoomConfig(config);

      // 挂起保存的第一笔私有写入（服务层测试钩子，确定性交错）。
      final writeGate = Completer<void>();
      var writeArmed = true;
      DormElectricityService.instance.debugPrivateWriteHook =
          (operation, key, write) async {
            if (operation == 'saveRoomConfig' && writeArmed) {
              writeArmed = false;
              await writeGate.future;
            }
            await write();
          };

      await tester.pumpWidget(_app());
      await _settleCatalog(tester);
      expect(find.textContaining('HX4-111'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await _settleCatalog(tester, until: () => !writeArmed);
      expect(writeArmed, isFalse); // 保存已挂起在写入中

      // 保存在途期间静默换号（尚无监听器通知）。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      writeGate.complete();
      await _settleCatalog(tester);

      // 迟到的保存结果（服务层回滚抛错或成功）都不得反馈到新会话：
      // 无 snackbar、不导航，页面保持原样。
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('寝室配置成功'), findsNothing);
      expect(find.textContaining('保存寝室配置失败'), findsNothing);
      expect(find.byType(DormElectricitySettingsPage), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cold identity restore auto-loads the catalog without login prompt '
    'or webview cookie sync',
    (tester) async {
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        loaderCalls++;
        return '20260001';
      };

      await tester.pumpWidget(_app());
      await _settleCatalog(tester);

      // 谨慎冷恢复（syncWebViewCookies: false）恰好一次 → 直接拉目录，
      // 不再要求点击、不弹登录。
      expect(loaderCalls, 1);
      expect(UnifiedAuthService.instance.debugWebViewCookieSyncCalls, 0);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.byType(LoginShell), findsNothing);
      expect(gateway.callCount, greaterThanOrEqualTo(1));
      expect(find.text('请选择'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
