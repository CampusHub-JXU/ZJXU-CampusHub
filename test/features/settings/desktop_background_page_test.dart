import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/settings/desktop_background_page.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_widget_bridge.dart';
import 'package:jxu_campus_hub/core/system_surface/system_settings_launcher.dart';
import 'package:jxu_campus_hub/core/system_surface/widget_refresh_state.dart';

import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_local_notifications 的 Android 实现通道（通知权限状态查询）。
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  late _FakeCampusWidgetGateway widgetGateway;
  late List<MethodCall> shortcutCalls;
  late _FakeSystemSettingsGateway systemSettingsGateway;
  late SystemSettingsOpenResult systemSettingsResult;
  late bool notificationsEnabled;
  late bool notificationsQueryThrows;
  late SystemBackgroundStatus systemStatus;
  WidgetRefreshRecord? refreshRecord;

  /// 1×1 透明 PNG：足够通过 Image.memory 解码路径。
  final previewPng = Uint8List.fromList(const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x62,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  setUpAll(() {
    // widget 测试默认平台为 android，但插件实现不经 GeneratedPluginRegistrant
    // 注册；手动注册后 areNotificationsEnabled 才走可 mock 的方法通道。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() {
    refreshRecord = null;
    shortcutCalls = <MethodCall>[];
    widgetGateway = _FakeCampusWidgetGateway();
    widgetGateway.status = CampusWidgetStatus.fromPlatformValue(
      <String, Object?>{
        'pinSupported': true,
        'installed': <String, Object?>{'small': 0, 'medium': 2, 'large': 0},
        'lastSnapshotAtMs': DateTime(
          2026,
          10,
          16,
          9,
          55,
        ).millisecondsSinceEpoch,
      },
    );
    systemSettingsGateway = _FakeSystemSettingsGateway();
    systemSettingsResult = SystemSettingsOpenResult.target;
    notificationsEnabled = true;
    notificationsQueryThrows = false;
    systemStatus = const SystemBackgroundStatus(
      notificationsEnabled: true,
      exactAlarmsAllowed: true,
      ignoringBatteryOptimizations: false,
      isXiaomiFamily: true,
    );
    systemSettingsGateway.statusProvider = () => systemStatus;
    systemSettingsGateway.openResultProvider = () => systemSettingsResult;
    SystemSettingsLauncher.instance.setGatewayForTesting(systemSettingsGateway);
    CampusWidgetBridge.instance.setGatewayForTesting(widgetGateway);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shortcutChannel, (call) async {
      shortcutCalls.add(call);
      return call.method == 'openShortcutPermissionSettings' ? true : null;
    });
    messenger.setMockMethodCallHandler(notificationsChannel, (call) async {
      if (call.method == 'areNotificationsEnabled') {
        if (notificationsQueryThrows) {
          throw PlatformException(code: 'channel_error');
        }
        return notificationsEnabled;
      }
      return null;
    });
  });

  tearDown(() {
    SystemSettingsLauncher.instance.setGatewayForTesting(null);
    CampusWidgetBridge.instance.setGatewayForTesting(null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shortcutChannel, null);
    messenger.setMockMethodCallHandler(notificationsChannel, null);
  });

  Future<void> pumpDesktopBackgroundPage(WidgetTester tester) async {
    await pumpPage(
      tester,
      DesktopBackgroundPage(
        now: () => DateTime(2026, 10, 16, 10, 20),
        refreshRecordLoader: () async => refreshRecord,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> revealRow(WidgetTester tester, String title) async {
    final row = find.text(title);
    await tester.scrollUntilVisible(row, 200);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String title) async {
    final row = find.text(title);
    await revealRow(tester, title);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// 经真实生命周期通道模拟「从系统设置返回」。
  Future<void> sendLifecycleState(WidgetTester tester, String state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemChannels.lifecycle.name,
          const StringCodec().encodeMessage(state),
          (_) {},
        );
    await tester.pumpAndSettle();
  }

  testWidgets('桌面组件三行分别以 small / medium / large 请求固定', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    expect(find.text('小 · 2×2 下一节课'), findsOneWidget);
    expect(find.text('中 · 4×2 今日课表'), findsOneWidget);
    expect(find.text('大 · 4×4 校园总览'), findsOneWidget);

    for (final (title, size) in const [
      ('小 · 2×2 下一节课', CampusWidgetSize.small),
      ('中 · 4×2 今日课表', CampusWidgetSize.medium),
      ('大 · 4×4 校园总览', CampusWidgetSize.large),
    ]) {
      await tapRow(tester, title);
      expect(widgetGateway.pinRequests.last, size);
      expect(find.text('已请求添加，请在桌面确认'), findsOneWidget);
    }
    expect(widgetGateway.pinRequests, hasLength(3));
  });

  testWidgets('桌面不支持一键添加时提示手动添加路径', (tester) async {
    widgetGateway.pinResult = CampusWidgetPinResult.unsupported;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '小 · 2×2 下一节课');

    expect(find.textContaining('当前桌面不支持一键添加'), findsOneWidget);
    expect(find.textContaining('小组件 → 嘉兴大学'), findsOneWidget);
  });

  testWidgets('固定被拒绝时提示并可跳转快捷方式权限设置', (tester) async {
    widgetGateway.pinResult = CampusWidgetPinResult.rejected;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '中 · 4×2 今日课表');

    expect(find.textContaining('桌面拒绝了添加请求'), findsOneWidget);
    expect(find.textContaining('允许「桌面快捷方式」'), findsOneWidget);
    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();
    expect(
      shortcutCalls.map((c) => c.method),
      contains('openShortcutPermissionSettings'),
    );
  });

  testWidgets('原生异常时提示添加失败，不抛出', (tester) async {
    widgetGateway.pinResult = CampusWidgetPinResult.error;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '大 · 4×4 校园总览');

    expect(find.textContaining('添加失败'), findsOneWidget);
  });

  testWidgets('后台运行各行分别以对应 target 调起系统设置且不误报', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    Future<void> expectNextOpen(
      String title,
      SystemSettingsTarget target,
    ) async {
      final before = systemSettingsGateway.opens.length;
      await tapRow(tester, title);
      expect(systemSettingsGateway.opens, hasLength(before + 1));
      expect(systemSettingsGateway.opens.last.target, target);
      // 命中目标页不弹提示；打开设置页不代表权限已授予。
      expect(find.byType(SnackBar), findsNothing);
    }

    // 与页面顺序一致，保证只向下滚动。
    await expectNextOpen('精确闹钟', SystemSettingsTarget.exactAlarms);
    await expectNextOpen('电池优化', SystemSettingsTarget.batteryOptimization);
    await expectNextOpen('自启动', SystemSettingsTarget.autostart);
    await expectNextOpen('系统应用信息', SystemSettingsTarget.appDetails);
  });

  testWidgets('系统应用信息行请求 appDetails 时视为成功（与目标页一致）', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.appDetails;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '系统应用信息');

    expect(
      systemSettingsGateway.opens.last.target,
      SystemSettingsTarget.appDetails,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('降级到应用详情页时用 SnackBar 说明实际打开的页面', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.appDetails;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '精确闹钟');

    expect(
      systemSettingsGateway.opens.last.target,
      SystemSettingsTarget.exactAlarms,
    );
    expect(find.textContaining('未能直达'), findsOneWidget);
    expect(find.textContaining('已打开应用详情页'), findsOneWidget);
  });

  testWidgets('降级到系统设置首页时用 SnackBar 说明实际打开的页面', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.settings;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '电池优化');

    expect(
      systemSettingsGateway.opens.last.target,
      SystemSettingsTarget.batteryOptimization,
    );
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);
  });

  testWidgets('通道不可用时提示手动前往，不静默失败', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.unavailable;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '自启动');

    expect(
      systemSettingsGateway.opens.last.target,
      SystemSettingsTarget.autostart,
    );
    expect(find.textContaining('未能打开系统设置'), findsOneWidget);
  });

  testWidgets('通知已开启时仍可点击直达通知设置，返回后刷新真实状态', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');
    expect(find.textContaining('已开启'), findsOneWidget);

    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();

    expect(systemSettingsGateway.opens, hasLength(1));
    expect(
      systemSettingsGateway.opens.single.target,
      SystemSettingsTarget.notifications,
    );
    // 打开通知设置页 ≠ 已授权，成功路径不弹「已开启」类提示。
    expect(find.byType(SnackBar), findsNothing);

    // 模拟返回 App 时权限实际被关闭：文案必须刷新，不沿用「已开启」。
    notificationsEnabled = false;
    await sendLifecycleState(tester, 'AppLifecycleState.resumed');

    expect(find.textContaining('未开启'), findsOneWidget);
    expect(find.textContaining('已开启'), findsNothing);
  });

  testWidgets('通知未开启时点击同样打开系统通知设置', (tester) async {
    notificationsEnabled = false;
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');
    expect(find.textContaining('未开启'), findsOneWidget);

    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();

    expect(
      systemSettingsGateway.opens.single.target,
      SystemSettingsTarget.notifications,
    );
  });

  testWidgets('通知降级打开时明确说明实际页面', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.settings;
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');
    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未能直达通知设置'), findsOneWidget);
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);
  });

  testWidgets('通知权限查询失败时显示状态未知，不谎称已开启', (tester) async {
    notificationsQueryThrows = true;
    systemStatus = const SystemBackgroundStatus(isXiaomiFamily: false);
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');

    await revealRow(tester, '通知');
    expect(_valueOf(tester, '通知'), '未知');
    expect(find.textContaining('已开启'), findsNothing);
    expect(find.text('检查中…'), findsNothing);
  });

  testWidgets('通知插件查询失败时采用原生读到的真实状态', (tester) async {
    notificationsQueryThrows = true;
    systemStatus = const SystemBackgroundStatus(notificationsEnabled: false);
    await pumpDesktopBackgroundPage(tester);

    expect(_valueOf(tester, '通知'), '未开启');
    expect(_rowOf(tester, '通知').emphasizeValue, isTrue);
  });

  testWidgets('后台运行行暴露可点击语义', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '精确闹钟');

    // 文案节点自身可能不带动作，向上找到承载点击语义的行节点。
    SemanticsNode? node = tester.getSemantics(find.text('精确闹钟'));
    while (node != null &&
        !node.getSemanticsData().hasAction(SemanticsAction.tap)) {
      node = node.parent;
    }
    expect(node, isNotNull, reason: '系统设置行应以按钮语义暴露点击动作');

    handle.dispose();
  });

  testWidgets('桌面组件行显示真实放置数量与上次同步时间', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    expect(_valueOf(tester, '小 · 2×2 下一节课'), '未放置');
    expect(_valueOf(tester, '中 · 4×2 今日课表'), '已放置 2 个');
    expect(_valueOf(tester, '上次同步'), '25 分钟前');
    // 后台刷新尚未运行过：不显示该行，不编造时间。
    expect(find.text('上次后台刷新'), findsNothing);
  });

  testWidgets('组件状态读不到时不显示「未放置」，同步显示尚未同步', (tester) async {
    widgetGateway.status = CampusWidgetStatus.unknown;
    await pumpDesktopBackgroundPage(tester);

    expect(find.text('未放置'), findsNothing);
    expect(_valueOf(tester, '上次同步'), '尚未同步');
  });

  testWidgets('后台运行各项显示真实状态，只强调未满足项', (tester) async {
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '系统应用信息');

    expect(_valueOf(tester, '通知'), '已开启');
    expect(_valueOf(tester, '精确闹钟'), '已允许');
    expect(_valueOf(tester, '电池优化'), '受系统限制');
    expect(_valueOf(tester, '自启动'), '无法检测');
    expect(_rowOf(tester, '电池优化').emphasizeValue, isTrue);
    expect(_rowOf(tester, '精确闹钟').emphasizeValue, isFalse);
    expect(_rowOf(tester, '通知').emphasizeValue, isFalse);
  });

  testWidgets('Android 12 以下精确闹钟显示无需设置且不可点', (tester) async {
    systemStatus = const SystemBackgroundStatus(
      notificationsEnabled: true,
      ignoringBatteryOptimizations: true,
    );
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '精确闹钟');

    expect(_valueOf(tester, '精确闹钟'), '无需设置');
    expect(_rowOf(tester, '精确闹钟').onTap, isNull);
    expect(_valueOf(tester, '电池优化'), '无限制');
    // 非小米系设备不显示自启动入口。
    expect(find.text('自启动'), findsNothing);
  });

  testWidgets('系统状态通道不可用时各项显示未知，不谎称已允许', (tester) async {
    systemStatus = SystemBackgroundStatus.unknown;
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '电池优化');

    expect(_valueOf(tester, '精确闹钟'), '未知');
    expect(_valueOf(tester, '电池优化'), '未知');
    expect(find.text('自启动'), findsNothing);
  });

  testWidgets('页面不再提供 ⓘ 说明按钮', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '系统应用信息');

    // 说明 popover 已下线：全页没有「关于xx」读屏按钮，行只保留标题+状态。
    expect(find.bySemanticsLabel(RegExp('^关于')), findsNothing);

    handle.dispose();
  });

  testWidgets('后台记录展示真实结果', (tester) async {
    refreshRecord = WidgetRefreshRecord(
      lastAttemptAt: DateTime(2026, 10, 16, 10, 15),
      lastOutcome: WidgetRefreshOutcome.partial,
    );
    await pumpDesktopBackgroundPage(tester);
    expect(find.text('上次后台刷新'), findsOneWidget);
    expect(find.textContaining('部分成功'), findsOneWidget);
  });

  testWidgets('原生预览位图按尺寸渲染，缺失时整块隐藏', (tester) async {
    widgetGateway.previews[CampusWidgetSize.medium] = previewPng;
    widgetGateway.previews[CampusWidgetSize.large] = previewPng;
    await pumpDesktopBackgroundPage(tester);
    expect(
      find.byKey(const Key('desktop_widget_preview_medium')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop_widget_preview_large')),
      findsOneWidget,
    );
    // small 未返回位图：预览区整块隐藏，不留占位。
    expect(find.byKey(const Key('desktop_widget_preview_small')), findsNothing);
  });
}

/// 记录式 SystemSettingsGateway 替身：open 记录目标，getStatus 回传可配置状态。
class _FakeSystemSettingsGateway implements SystemSettingsGateway {
  final opens = <({SystemSettingsTarget target, String? channelId})>[];
  int getStatusCalls = 0;

  SystemBackgroundStatus Function()? statusProvider;
  SystemSettingsOpenResult Function()? openResultProvider;

  @override
  Future<SystemSettingsOpenResult> open(
    SystemSettingsTarget target, {
    String? channelId,
  }) async {
    opens.add((target: target, channelId: channelId));
    return openResultProvider?.call() ?? SystemSettingsOpenResult.target;
  }

  @override
  Future<SystemBackgroundStatus> getStatus() async {
    getStatusCalls++;
    return statusProvider?.call() ?? const SystemBackgroundStatus();
  }
}

PlainListRow _rowOf(WidgetTester tester, String title) => tester.widget(
  find.ancestor(of: find.text(title), matching: find.byType(PlainListRow)),
);

String? _valueOf(WidgetTester tester, String title) =>
    _rowOf(tester, title).value;

/// 记录式 CampusWidgetGateway 替身：记录固定请求，返回可配置状态 / 预览。
class _FakeCampusWidgetGateway implements CampusWidgetGateway {
  final pinRequests = <CampusWidgetSize>[];
  final previews = <CampusWidgetSize, Uint8List>{};

  CampusWidgetPinResult pinResult = CampusWidgetPinResult.requested;
  CampusWidgetStatus status = CampusWidgetStatus.unknown;
  bool supported = true;

  @override
  Future<void> pushSnapshot(Map<String, Object?> projection) async {}

  @override
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) async {
    pinRequests.add(size);
    return pinResult;
  }

  @override
  Future<CampusWidgetStatus> getStatus() async => status;

  @override
  Future<Uint8List?> getPreview(
    CampusWidgetSize size, {
    required int widthPx,
  }) async => previews[size];

  @override
  Future<bool> isSupported() async => supported;
}
