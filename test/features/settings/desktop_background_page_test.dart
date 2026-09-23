import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/settings/desktop_background_page.dart';

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

  late List<MethodCall> systemSettingsCalls;
  late String systemSettingsResult;
  late bool notificationsEnabled;
  late bool notificationsQueryThrows;

  setUpAll(() {
    // widget 测试默认平台为 android，但插件实现不经 GeneratedPluginRegistrant
    // 注册；手动注册后 areNotificationsEnabled 才走可 mock 的方法通道。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() {
    systemSettingsCalls = <MethodCall>[];
    systemSettingsResult = 'target';
    notificationsEnabled = true;
    notificationsQueryThrows = false;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(systemSettingsChannel, (call) async {
      systemSettingsCalls.add(call);
      if (call.method != 'open') return null;
      return systemSettingsResult;
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
    messenger.setMockMethodCallHandler(notificationsChannel, null);
  });

  Future<void> pumpDesktopBackgroundPage(WidgetTester tester) async {
    await pumpPage(tester, const DesktopBackgroundPage());
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

  testWidgets('后台运行四行分别以对应 target 调起系统设置且不误报', (tester) async {
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
    await expectNextOpen('后台运行状态', 'appDetails');
    await expectNextOpen('精确闹钟', 'exactAlarms');
    await expectNextOpen('电池优化', 'batteryOptimization');
    await expectNextOpen('HyperOS / MIUI 自启动', 'autostart');
  });

  testWidgets('后台运行行请求 appDetails 时视为成功（与目标页一致）', (tester) async {
    systemSettingsResult = 'appDetails';
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '后台运行状态');

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

    await tapRow(tester, 'HyperOS / MIUI 自启动');

    expect(systemSettingsCalls.last.arguments, <String, Object?>{
      'target': 'autostart',
    });
    expect(find.textContaining('未能打开系统设置'), findsOneWidget);
  });

  testWidgets('通知已开启时仍可点击直达通知设置，返回后刷新真实状态', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知权限');
    expect(find.textContaining('已开启'), findsOneWidget);

    await tester.tap(find.text('通知权限'));
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

    await revealRow(tester, '通知权限');
    expect(find.textContaining('未开启'), findsOneWidget);

    await tester.tap(find.text('通知权限'));
    await tester.pumpAndSettle();

    expect(systemSettingsCalls.single.arguments, <String, Object?>{
      'target': 'notifications',
    });
  });

  testWidgets('通知降级打开时明确说明实际页面', (tester) async {
    systemSettingsResult = 'settings';
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知权限');
    await tester.tap(find.text('通知权限'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未能直达通知设置'), findsOneWidget);
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);
  });

  testWidgets('通知权限查询失败时显示状态未知，不谎称已开启', (tester) async {
    notificationsQueryThrows = true;
    await pumpDesktopBackgroundPage(tester);

    await revealRow(tester, '通知权限');

    expect(find.textContaining('状态未知'), findsOneWidget);
    expect(find.textContaining('已开启'), findsNothing);
    expect(find.text('检查中…'), findsNothing);
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
}
