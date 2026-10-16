import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/settings/desktop_background_page.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';
import 'package:jxu_campus_hub/core/system_surface/widget_refresh_state.dart';

import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 原生 lane 的系统设置通道契约：method 'open'，参数 {'target': <枚举名>}。
  const systemSettingsChannel = MethodChannel(
    'edu.zjxu.jxucampushub/system_settings',
  );
  // flutter_local_notifications 的 Android 实现通道（通知权限状态查询）。
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  const widgetChannel = MethodChannel('edu.zjxu.jxucampushub/widget');
  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  late List<MethodCall> widgetCalls;
  late List<MethodCall> shortcutCalls;
  late String widgetPinResult;
  late List<MethodCall> systemSettingsCalls;
  late String systemSettingsResult;
  late bool notificationsEnabled;
  late bool notificationsQueryThrows;
  late Object? widgetStatus;
  late Object? systemStatus;
  WidgetRefreshRecord? refreshRecord;

  setUpAll(() {
    // widget 测试默认平台为 android，但插件实现不经 GeneratedPluginRegistrant
    // 注册；手动注册后 areNotificationsEnabled 才走可 mock 的方法通道。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() {
    refreshRecord = null;
    widgetCalls = <MethodCall>[];
    shortcutCalls = <MethodCall>[];
    widgetPinResult = 'requested';
    systemSettingsCalls = <MethodCall>[];
    systemSettingsResult = 'target';
    notificationsEnabled = true;
    notificationsQueryThrows = false;
    widgetStatus = <String, Object?>{
      'pinSupported': true,
      'installed': <String, Object?>{'small': 0, 'medium': 2, 'large': 0},
      'lastSnapshotAtMs': DateTime(2026, 10, 16, 9, 55).millisecondsSinceEpoch,
    };
    systemStatus = <String, Object?>{
      'notificationsEnabled': true,
      'exactAlarmsAllowed': true,
      'ignoringBatteryOptimizations': false,
      'isXiaomiFamily': true,
    };

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(systemSettingsChannel, (call) async {
      if (call.method == 'getStatus') return systemStatus;
      systemSettingsCalls.add(call);
      if (call.method != 'open') return null;
      return systemSettingsResult;
    });
    messenger.setMockMethodCallHandler(widgetChannel, (call) async {
      if (call.method == 'getStatus') return widgetStatus;
      widgetCalls.add(call);
      return call.method == 'requestPin' ? widgetPinResult : null;
    });
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
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(systemSettingsChannel, null);
    messenger.setMockMethodCallHandler(widgetChannel, null);
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
      ('小 · 2×2 下一节课', 'small'),
      ('中 · 4×2 今日课表', 'medium'),
      ('大 · 4×4 校园总览', 'large'),
    ]) {
      await tapRow(tester, title);
      final call = widgetCalls.last;
      expect(call.method, 'requestPin');
      expect(call.arguments, <String, Object?>{'size': size});
      expect(find.text('已请求添加，请在桌面确认'), findsOneWidget);
    }
    expect(widgetCalls, hasLength(3));
  });

  testWidgets('桌面不支持一键添加时提示手动添加路径', (tester) async {
    widgetPinResult = 'unsupported';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '小 · 2×2 下一节课');

    expect(find.textContaining('当前桌面不支持一键添加'), findsOneWidget);
    expect(find.textContaining('小组件 → 嘉兴大学'), findsOneWidget);
  });

  testWidgets('固定被拒绝时提示并可跳转快捷方式权限设置', (tester) async {
    widgetPinResult = 'rejected';
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
    widgetPinResult = 'error';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '大 · 4×4 校园总览');

    expect(find.textContaining('添加失败'), findsOneWidget);
  });

  testWidgets('后台运行各行分别以对应 target 调起系统设置且不误报', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    Future<void> expectNextOpen(String title, String target) async {
      final before = systemSettingsCalls.length;
      await tapRow(tester, title);
      expect(systemSettingsCalls, hasLength(before + 1));
      final call = systemSettingsCalls.last;
      expect(call.method, 'open');
      expect(call.arguments, <String, Object?>{'target': target});
      // 命中目标页不弹提示；打开设置页不代表权限已授予。
      expect(find.byType(SnackBar), findsNothing);
    }

    // 与页面顺序一致，保证只向下滚动。
    await expectNextOpen('精确闹钟', 'exactAlarms');
    await expectNextOpen('电池优化', 'batteryOptimization');
    await expectNextOpen('自启动', 'autostart');
    await expectNextOpen('系统应用信息', 'appDetails');
  });

  testWidgets('系统应用信息行请求 appDetails 时视为成功（与目标页一致）', (tester) async {
    systemSettingsResult = 'appDetails';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '系统应用信息');

    expect(systemSettingsCalls.last.arguments, <String, Object?>{
      'target': 'appDetails',
    });
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('降级到应用详情页时用 SnackBar 说明实际打开的页面', (tester) async {
    systemSettingsResult = 'appDetails';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '精确闹钟');

    expect(systemSettingsCalls.last.arguments, <String, Object?>{
      'target': 'exactAlarms',
    });
    expect(find.textContaining('未能直达'), findsOneWidget);
    expect(find.textContaining('已打开应用详情页'), findsOneWidget);
  });

  testWidgets('降级到系统设置首页时用 SnackBar 说明实际打开的页面', (tester) async {
    systemSettingsResult = 'settings';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '电池优化');

    expect(systemSettingsCalls.last.arguments, <String, Object?>{
      'target': 'batteryOptimization',
    });
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);
  });

  testWidgets('通道不可用时提示手动前往，不静默失败', (tester) async {
    systemSettingsResult = 'unavailable';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '自启动');

    expect(systemSettingsCalls.last.arguments, <String, Object?>{
      'target': 'autostart',
    });
    expect(find.textContaining('未能打开系统设置'), findsOneWidget);
  });

  testWidgets('通知已开启时仍可点击直达通知设置，返回后刷新真实状态', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');
    expect(find.textContaining('已开启'), findsOneWidget);

    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();

    expect(systemSettingsCalls, hasLength(1));
    expect(systemSettingsCalls.single.method, 'open');
    expect(systemSettingsCalls.single.arguments, <String, Object?>{
      'target': 'notifications',
    });
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

    expect(systemSettingsCalls.single.arguments, <String, Object?>{
      'target': 'notifications',
    });
  });

  testWidgets('通知降级打开时明确说明实际页面', (tester) async {
    systemSettingsResult = 'settings';
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');
    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未能直达通知设置'), findsOneWidget);
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);
  });

  testWidgets('通知权限查询失败时显示状态未知，不谎称已开启', (tester) async {
    notificationsQueryThrows = true;
    systemStatus = <String, Object?>{'isXiaomiFamily': false};
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知');

    await revealRow(tester, '通知');
    expect(_valueOf(tester, '通知'), '未知');
    expect(find.textContaining('已开启'), findsNothing);
    expect(find.text('检查中…'), findsNothing);
  });

  testWidgets('通知插件查询失败时采用原生读到的真实状态', (tester) async {
    notificationsQueryThrows = true;
    systemStatus = <String, Object?>{'notificationsEnabled': false};
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
    widgetStatus = null;
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
    systemStatus = <String, Object?>{
      'notificationsEnabled': true,
      'exactAlarmsAllowed': null,
      'ignoringBatteryOptimizations': true,
      'isXiaomiFamily': false,
    };
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '精确闹钟');

    expect(_valueOf(tester, '精确闹钟'), '无需设置');
    expect(_rowOf(tester, '精确闹钟').onTap, isNull);
    expect(_valueOf(tester, '电池优化'), '无限制');
    // 非小米系设备不显示自启动入口。
    expect(find.text('自启动'), findsNothing);
  });

  testWidgets('系统状态通道不可用时各项显示未知，不谎称已允许', (tester) async {
    systemStatus = null;
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '电池优化');

    expect(_valueOf(tester, '精确闹钟'), '未知');
    expect(_valueOf(tester, '电池优化'), '未知');
    expect(find.text('自启动'), findsNothing);
  });

  testWidgets('点 ⓘ 弹出说明、不触发行动作，点外部关闭', (tester) async {
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '电池优化');

    // 说明不再作为副标题常驻。
    expect(find.textContaining('需要你手动把本应用设为'), findsNothing);

    await tester.tap(find.bySemanticsLabel('关于电池优化'));
    await tester.pumpAndSettle();

    expect(find.textContaining('需要你手动把本应用设为'), findsOneWidget);
    expect(systemSettingsCalls, isEmpty);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.textContaining('需要你手动把本应用设为'), findsNothing);
  });

  testWidgets('ⓘ 是独立的读屏按钮，不并入行的点按语义', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpDesktopBackgroundPage(tester);
    await revealRow(tester, '电池优化');

    final info = tester.getSemantics(find.bySemanticsLabel('关于电池优化'));
    expect(info.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(info.label, '关于电池优化');
    final row = tester.getSemantics(find.text('电池优化'));
    expect(row.label, isNot(contains('关于电池优化')));

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
}

PlainListRow _rowOf(WidgetTester tester, String title) => tester.widget(
  find.ancestor(of: find.text(title), matching: find.byType(PlainListRow)),
);

String? _valueOf(WidgetTester tester, String title) =>
    _rowOf(tester, title).value;
