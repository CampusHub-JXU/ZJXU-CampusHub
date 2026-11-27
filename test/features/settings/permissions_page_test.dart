import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';
import 'package:jxu_campus_hub/core/system_surface/system_settings_launcher.dart';
import 'package:jxu_campus_hub/features/settings/permissions_page.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

import '../../helpers/fake_calendar_sync_native.dart';
import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_local_notifications 的 Android 实现通道（通知权限状态查询）。
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');
  const calendarChannel = MethodChannel(CalendarSyncProtocol.channelName);

  late List<MethodCall> shortcutCalls;
  late bool shortcutSettingsOpened;
  late _FakeSystemSettingsGateway systemSettingsGateway;
  late SystemSettingsOpenResult systemSettingsResult;
  late bool notificationsEnabled;
  late bool notificationsQueryThrows;
  late SystemBackgroundStatus systemStatus;
  late FakeCalendarSyncNative calendarNative;

  setUpAll(() {
    // widget 测试默认平台为 android，但插件实现不经 GeneratedPluginRegistrant
    // 注册；手动注册后 areNotificationsEnabled 才走可 mock 的方法通道。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() {
    shortcutCalls = <MethodCall>[];
    shortcutSettingsOpened = true;
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
    systemSettingsGateway.statusProvider = () async => systemStatus;
    systemSettingsGateway.openResultProvider = () => systemSettingsResult;
    SystemSettingsLauncher.instance.setGatewayForTesting(systemSettingsGateway);

    calendarNative = FakeCalendarSyncNative();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shortcutChannel, (call) async {
      shortcutCalls.add(call);
      return call.method == 'openShortcutPermissionSettings'
          ? shortcutSettingsOpened
          : null;
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
    messenger.setMockMethodCallHandler(calendarChannel, calendarNative.handle);
  });

  tearDown(() {
    SystemSettingsLauncher.instance.setGatewayForTesting(null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shortcutChannel, null);
    messenger.setMockMethodCallHandler(notificationsChannel, null);
    messenger.setMockMethodCallHandler(calendarChannel, null);
  });

  Future<void> pumpPermissionsPage(
    WidgetTester tester, {
    CalendarSyncChannel? injectedCalendarChannel,
  }) async {
    await pumpPage(
      tester,
      PermissionsSettingsPage(calendarChannel: injectedCalendarChannel),
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

  testWidgets('页面标题与两个分组齐备，只读查询真实状态', (tester) async {
    await pumpPermissionsPage(tester);

    expect(find.text('权限与后台'), findsOneWidget);
    expect(find.text('应用权限'), findsOneWidget);
    expect(find.text('后台运行'), findsOneWidget);

    expect(_valueOf(tester, '通知权限'), '已开启');
    expect(_valueOf(tester, '日历读写权限'), '已允许');
    expect(find.text('桌面快捷方式权限'), findsOneWidget);
    expect(find.text('部分系统默认禁止创建，需手动允许'), findsOneWidget);

    await revealRow(tester, '系统应用信息');
    expect(_valueOf(tester, '精确闹钟'), '已允许');
    expect(_valueOf(tester, '电池优化'), '受系统限制');
    expect(_valueOf(tester, '自启动'), '无法检测');
    expect(_rowOf(tester, '电池优化').emphasizeValue, isTrue);
    expect(_rowOf(tester, '精确闹钟').emphasizeValue, isFalse);
    expect(_rowOf(tester, '通知权限').emphasizeValue, isFalse);
    expect(_rowOf(tester, '日历读写权限').emphasizeValue, isFalse);
  });

  testWidgets('通知权限已开启时仍可点击直达通知设置，返回后刷新真实状态', (tester) async {
    await pumpPermissionsPage(tester);

    expect(_valueOf(tester, '通知权限'), '已开启');
    await tapRow(tester, '通知权限');

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

    expect(_valueOf(tester, '通知权限'), '未开启');
    expect(_rowOf(tester, '通知权限').emphasizeValue, isTrue);
  });

  testWidgets('通知权限未开启时点击同样打开系统通知设置', (tester) async {
    notificationsEnabled = false;
    await pumpPermissionsPage(tester);

    expect(_valueOf(tester, '通知权限'), '未开启');
    expect(_rowOf(tester, '通知权限').emphasizeValue, isTrue);

    await tapRow(tester, '通知权限');

    expect(
      systemSettingsGateway.opens.single.target,
      SystemSettingsTarget.notifications,
    );
  });

  testWidgets('通知权限降级打开时明确说明实际页面', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.settings;
    await pumpPermissionsPage(tester);

    await tapRow(tester, '通知权限');

    expect(find.textContaining('未能直达通知设置'), findsOneWidget);
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);
  });

  testWidgets('通知权限查询失败时采用原生读到的真实状态，全失败显示未知', (tester) async {
    notificationsQueryThrows = true;
    systemStatus = const SystemBackgroundStatus(notificationsEnabled: false);
    await pumpPermissionsPage(tester);

    expect(_valueOf(tester, '通知权限'), '未开启');
    expect(_rowOf(tester, '通知权限').emphasizeValue, isTrue);

    systemStatus = const SystemBackgroundStatus(isXiaomiFamily: false);
    await sendLifecycleState(tester, 'AppLifecycleState.resumed');

    expect(_valueOf(tester, '通知权限'), '未知');
    expect(_rowOf(tester, '通知权限').emphasizeValue, isFalse);
  });

  testWidgets('日历读写权限未允许时强调并点击发起申请，允许后刷新状态', (tester) async {
    calendarNative.permissions = false;
    calendarNative.grantOnRequest = true;
    await pumpPermissionsPage(tester);

    expect(_valueOf(tester, '日历读写权限'), '未允许');
    expect(_rowOf(tester, '日历读写权限').emphasizeValue, isTrue);
    expect(_rowOf(tester, '日历读写权限').onTap, isNotNull);

    await tapRow(tester, '日历读写权限');

    expect(calendarNative.requestCalls, 1);
    expect(_valueOf(tester, '日历读写权限'), '已允许');
    expect(_rowOf(tester, '日历读写权限').emphasizeValue, isFalse);
    expect(_rowOf(tester, '日历读写权限').onTap, isNull);
  });

  testWidgets('日历读写权限申请被拒时保持未允许并可去应用详情页设置', (tester) async {
    calendarNative.permissions = false;
    calendarNative.grantOnRequest = false;
    await pumpPermissionsPage(tester);

    await tapRow(tester, '日历读写权限');

    expect(calendarNative.requestCalls, 1);
    expect(_valueOf(tester, '日历读写权限'), '未允许');
    expect(_rowOf(tester, '日历读写权限').emphasizeValue, isTrue);
    expect(find.textContaining('未获得日历读写权限'), findsOneWidget);

    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();
    expect(
      systemSettingsGateway.opens.single.target,
      SystemSettingsTarget.appDetails,
    );
  });

  testWidgets('日历读写权限通道查询异常时显示未知', (tester) async {
    await pumpPermissionsPage(
      tester,
      injectedCalendarChannel: _ThrowingCalendarChannel(),
    );

    expect(_valueOf(tester, '日历读写权限'), '未知');
    expect(_rowOf(tester, '日历读写权限').emphasizeValue, isFalse);
    expect(_rowOf(tester, '日历读写权限').onTap, isNull);
  });

  testWidgets('桌面快捷方式权限行点击调起设置并在失败时提示', (tester) async {
    await pumpPermissionsPage(tester);

    await tapRow(tester, '桌面快捷方式权限');
    expect(
      shortcutCalls.map((c) => c.method),
      contains('openShortcutPermissionSettings'),
    );
    expect(find.byType(SnackBar), findsNothing);

    shortcutSettingsOpened = false;
    await tapRow(tester, '桌面快捷方式权限');
    expect(find.text('未能打开系统设置，请手动前往系统应用管理'), findsOneWidget);
  });

  testWidgets('后台运行各行分别以对应 target 调起系统设置且不误报', (tester) async {
    await pumpPermissionsPage(tester);

    Future<void> expectNextOpen(
      String title,
      SystemSettingsTarget target,
    ) async {
      final before = systemSettingsGateway.opens.length;
      await tapRow(tester, title);
      expect(systemSettingsGateway.opens, hasLength(before + 1));
      expect(systemSettingsGateway.opens.last.target, target);
      expect(find.byType(SnackBar), findsNothing);
    }

    await expectNextOpen('精确闹钟', SystemSettingsTarget.exactAlarms);
    await expectNextOpen('电池优化', SystemSettingsTarget.batteryOptimization);
    await expectNextOpen('自启动', SystemSettingsTarget.autostart);
    await expectNextOpen('系统应用信息', SystemSettingsTarget.appDetails);
  });

  testWidgets('系统应用信息行请求 appDetails 时视为成功（与目标页一致）', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.appDetails;
    await pumpPermissionsPage(tester);

    await tapRow(tester, '系统应用信息');

    expect(
      systemSettingsGateway.opens.last.target,
      SystemSettingsTarget.appDetails,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('降级到应用详情页或设置首页、不可用时用 SnackBar 说明', (tester) async {
    systemSettingsResult = SystemSettingsOpenResult.appDetails;
    await pumpPermissionsPage(tester);

    await tapRow(tester, '精确闹钟');
    expect(find.textContaining('未能直达该设置项'), findsOneWidget);
    expect(find.textContaining('已打开应用详情页'), findsOneWidget);

    systemSettingsResult = SystemSettingsOpenResult.settings;
    await tapRow(tester, '电池优化');
    expect(find.textContaining('已打开系统设置首页'), findsOneWidget);

    systemSettingsResult = SystemSettingsOpenResult.unavailable;
    await tapRow(tester, '自启动');
    expect(find.textContaining('未能打开系统设置'), findsOneWidget);
  });

  testWidgets('Android 12 以下精确闹钟显示无需设置且不可点，非小米不显示自启动', (tester) async {
    systemStatus = const SystemBackgroundStatus(
      notificationsEnabled: true,
      ignoringBatteryOptimizations: true,
    );
    await pumpPermissionsPage(tester);
    await revealRow(tester, '精确闹钟');

    expect(_valueOf(tester, '精确闹钟'), '无需设置');
    expect(_rowOf(tester, '精确闹钟').onTap, isNull);
    expect(_valueOf(tester, '电池优化'), '无限制');
    expect(find.text('自启动'), findsNothing);
  });

  testWidgets('系统状态通道不可用时各项显示未知，不谎称已允许', (tester) async {
    systemStatus = SystemBackgroundStatus.unknown;
    await pumpPermissionsPage(tester);
    await revealRow(tester, '电池优化');

    expect(_valueOf(tester, '精确闹钟'), '未知');
    expect(_valueOf(tester, '电池优化'), '未知');
    expect(find.text('自启动'), findsNothing);
  });

  testWidgets('慢的旧查询返回不会覆盖新查询结果', (tester) async {
    final firstGate = Completer<SystemBackgroundStatus>();
    var call = 0;
    systemSettingsGateway.statusProvider = () {
      call++;
      if (call == 1) return firstGate.future;
      return Future.value(
        const SystemBackgroundStatus(
          notificationsEnabled: true,
          exactAlarmsAllowed: true,
          ignoringBatteryOptimizations: true,
        ),
      );
    };

    await pumpPage(tester, const PermissionsSettingsPage());
    expect(_valueOf(tester, '精确闹钟'), '检查中…');

    // 触发新一轮 resumed 查询（快速完成，所有权限均为已允许/无限制）。
    await sendLifecycleState(tester, 'AppLifecycleState.resumed');
    expect(_valueOf(tester, '精确闹钟'), '已允许');
    expect(_valueOf(tester, '电池优化'), '无限制');

    // 旧查询延迟返回「未允许/受限制」，不应覆盖新结果。
    firstGate.complete(
      const SystemBackgroundStatus(
        notificationsEnabled: false,
        exactAlarmsAllowed: false,
        ignoringBatteryOptimizations: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(_valueOf(tester, '精确闹钟'), '已允许');
    expect(_valueOf(tester, '电池优化'), '无限制');
  });

  testWidgets('可点击行暴露点击语义', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPermissionsPage(tester);
    await revealRow(tester, '精确闹钟');

    SemanticsNode? node = tester.getSemantics(find.text('精确闹钟'));
    while (node != null &&
        !node.getSemanticsData().hasAction(SemanticsAction.tap)) {
      node = node.parent;
    }
    expect(node, isNotNull, reason: '系统设置行应以按钮语义暴露点击动作');

    handle.dispose();
  });
}

PlainListRow _rowOf(WidgetTester tester, String title) => tester.widget(
  find.ancestor(of: find.text(title), matching: find.byType(PlainListRow)),
);

String? _valueOf(WidgetTester tester, String title) =>
    _rowOf(tester, title).value;

/// 记录式 SystemSettingsGateway 替身：open 记录目标，getStatus 回传可配置异步状态。
class _FakeSystemSettingsGateway implements SystemSettingsGateway {
  final opens = <({SystemSettingsTarget target, String? channelId})>[];
  int getStatusCalls = 0;

  Future<SystemBackgroundStatus> Function()? statusProvider;
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
    return await (statusProvider?.call() ??
        Future.value(const SystemBackgroundStatus()));
  }
}

class _ThrowingCalendarChannel implements CalendarSyncChannel {
  @override
  Future<bool> checkPermissions() => Future.error(StateError('boom'));

  @override
  Future<bool> requestPermissions() => Future.error(StateError('boom'));

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() =>
      throw UnimplementedError();

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) => throw UnimplementedError();

  @override
  Future<List<CalendarSyncWritableCalendar>> listWritableCalendars() =>
      throw UnimplementedError();

  @override
  Future<List<CalendarSyncOwnedEvent>> queryOwnedEvents({
    required int calendarId,
    List<String>? opaqueIds,
  }) => throw UnimplementedError();

  @override
  Future<CalendarSyncBatchResult> upsertEventBatch({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  }) => throw UnimplementedError();
}
