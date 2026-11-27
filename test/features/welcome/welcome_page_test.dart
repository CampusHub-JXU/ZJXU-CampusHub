import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_widget_bridge.dart';
import 'package:jxu_campus_hub/core/system_surface/system_settings_launcher.dart';
import 'package:jxu_campus_hub/features/welcome/welcome_page.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  tearDown(() {
    WelcomeFlow.debugReset();
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    GlobalKey<ScaffoldMessengerState>? messengerKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messengerKey,
        home: const Scaffold(body: Center(child: Text('宿主页面'))),
      ),
    );
    await tester.pump();
  }

  Future<bool> completedFlag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(welcomeCompletedPrefsKey) ?? false;
  }

  testWidgets('未完成的用户在 shouldShow 处返回 true', (tester) async {
    expect(await WelcomeFlow.shouldShow(), isTrue);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(welcomeCompletedPrefsKey, true);
    expect(await WelcomeFlow.shouldShow(), isFalse);
  });

  testWidgets('单页清单结构完整展示三组配置与主操作按钮', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('欢迎使用嘉兴大学'), findsOneWidget);
    expect(find.text('CampusHub'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('核心权限'), findsOneWidget);
    expect(find.text('通知提醒'), findsOneWidget);
    expect(find.text('日历同步权限'), findsOneWidget);
    expect(find.text('后台保活'), findsOneWidget);
    expect(find.text('桌面组件与快捷功能'), findsOneWidget);
    expect(find.text('添加桌面课表组件'), findsOneWidget);
    expect(find.text('账号与进阶'), findsOneWidget);
    expect(find.text('校园账号登录'), findsOneWidget);
    expect(find.text('AI 助手配置'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);

    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(await completedFlag(), isTrue);
  });

  testWidgets('跳过同样写完成标记', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(await completedFlag(), isTrue);
  });

  testWidgets('在途时再次 show 不重复 push', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
  });

  testWidgets('系统返回键关闭也写完成标记', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    await Navigator.of(context).maybePop();
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(await completedFlag(), isTrue);
  });

  testWidgets('通知权限：就地请求成功立即刷新；被拒则跳系统设置并在 resumed 自动刷新', (tester) async {
    var notificationsEnabled = false;
    var grantOnRequest = true;
    final openedTargets = <SystemSettingsTarget>[];

    await tester.pumpWidget(
      MaterialApp(
        home: WelcomePage(
          checkNotificationsEnabled: () async => notificationsEnabled,
          requestNotificationPermission: () async {
            if (grantOnRequest) notificationsEnabled = true;
            return grantOnRequest;
          },
          calendarChannel: _FakeCalendarSyncChannel(),
          readBackgroundStatus: () async => SystemBackgroundStatus.unknown,
          openSystemSettings: (target) async {
            openedTargets.add(target);
            return SystemSettingsOpenResult.target;
          },
          isCampusLoggedIn: () => false,
          isAcademicLoggedIn: () => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_notification_status')))
          .data,
      '未开启',
    );

    // 场景 1：就地授权成功。
    await tester.tap(find.text('通知提醒'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_notification_status')))
          .data,
      '已开启',
    );
    expect(openedTargets, isEmpty);

    // 场景 2：重新挂载未开启状态且系统拒绝弹窗 -> 跳转系统通知设置 -> resumed 刷新。
    notificationsEnabled = false;
    grantOnRequest = false;
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomePage(
          key: const ValueKey('second_pass'),
          checkNotificationsEnabled: () async => notificationsEnabled,
          requestNotificationPermission: () async => false,
          calendarChannel: _FakeCalendarSyncChannel(),
          readBackgroundStatus: () async => SystemBackgroundStatus.unknown,
          openSystemSettings: (target) async {
            openedTargets.add(target);
            return SystemSettingsOpenResult.target;
          },
          isCampusLoggedIn: () => false,
          isAcademicLoggedIn: () => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('通知提醒'));
    await tester.pumpAndSettle();

    expect(openedTargets, [SystemSettingsTarget.notifications]);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_notification_status')))
          .data,
      '未开启',
    );

    // 用户在系统设置开启后返回应用（resumed）。
    notificationsEnabled = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_notification_status')))
          .data,
      '已开启',
    );
  });

  testWidgets('日历权限：就地请求并立即刷新为已允许', (tester) async {
    final calendar = _FakeCalendarSyncChannel();

    await tester.pumpWidget(
      MaterialApp(
        home: WelcomePage(
          checkNotificationsEnabled: () async => false,
          calendarChannel: calendar,
          readBackgroundStatus: () async => SystemBackgroundStatus.unknown,
          isCampusLoggedIn: () => false,
          isAcademicLoggedIn: () => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_calendar_status')))
          .data,
      '未开启',
    );

    await tester.tap(find.text('日历同步权限'));
    await tester.pumpAndSettle();

    expect(calendar.requestCount, 1);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_calendar_status')))
          .data,
      '已允许',
    );
  });

  testWidgets('后台保活：展示限制状态、跳转电池优化并在 resumed 自动刷新', (tester) async {
    var ignoringBattery = false;
    final openedTargets = <SystemSettingsTarget>[];

    await tester.pumpWidget(
      MaterialApp(
        home: WelcomePage(
          checkNotificationsEnabled: () async => false,
          calendarChannel: _FakeCalendarSyncChannel(),
          readBackgroundStatus: () async => SystemBackgroundStatus(
            available: true,
            ignoringBatteryOptimizations: ignoringBattery,
          ),
          openSystemSettings: (target) async {
            openedTargets.add(target);
            return SystemSettingsOpenResult.target;
          },
          isCampusLoggedIn: () => false,
          isAcademicLoggedIn: () => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('welcome_battery_status'))).data,
      '受系统限制',
    );

    await tester.tap(find.text('后台保活'));
    await tester.pumpAndSettle();

    expect(openedTargets, [SystemSettingsTarget.batteryOptimization]);

    ignoringBattery = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('welcome_battery_status'))).data,
      '无限制',
    );
  });

  testWidgets('添加桌面课表组件不离开页面并如实 toast 反馈', (tester) async {
    var pinResult = CampusWidgetPinResult.requested;
    CampusWidgetSize? requestedSize;

    await tester.pumpWidget(
      MaterialApp(
        home: WelcomePage(
          checkNotificationsEnabled: () async => false,
          calendarChannel: _FakeCalendarSyncChannel(),
          readBackgroundStatus: () async => SystemBackgroundStatus.unknown,
          requestWidgetPin: (size) async {
            requestedSize = size;
            return pinResult;
          },
          isCampusLoggedIn: () => false,
          isAcademicLoggedIn: () => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加桌面课表组件'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(requestedSize, CampusWidgetSize.medium);
    expect(find.text('已请求添加，请在桌面确认'), findsOneWidget);

    pinResult = CampusWidgetPinResult.unsupported;
    await tester.tap(find.text('添加桌面课表组件'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('不支持一键添加，请长按桌面手动添加'), findsOneWidget);
  });

  testWidgets('校园账号登录与 AI 助手配置入口正常回调并写完成标记', (tester) async {
    await pumpHost(tester);

    var loginCalled = false;
    final context = tester.element(find.text('宿主页面'));
    unawaited(
      WelcomeFlow.show(
        context,
        onLoginShortcut: (_) => loginCalled = true,
        onAiShortcut: (navigator) => unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('AI 模型与接口')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('welcome_account_status'))).data,
      '未登录',
    );

    await tester.scrollUntilVisible(find.text('校园账号登录'), 120);
    await tester.tap(find.text('校园账号登录'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(loginCalled, isTrue);
    expect(await completedFlag(), isTrue);

    // 重新打开验证 AI 入口。
    WelcomeFlow.debugReset();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(welcomeCompletedPrefsKey);

    unawaited(
      WelcomeFlow.show(
        context,
        onAiShortcut: (navigator) => unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('AI 模型与接口')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('AI 助手配置'), 120);
    await tester.tap(find.text('AI 助手配置'));
    await tester.pumpAndSettle();

    expect(find.text('AI 模型与接口'), findsOneWidget);
    expect(await completedFlag(), isTrue);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(find.text('宿主页面'), findsOneWidget);
  });

  testWidgets('通道异常时降级不崩溃', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WelcomePage(
          checkNotificationsEnabled: () async =>
              throw StateError('plugin missing'),
          requestNotificationPermission: () async =>
              throw StateError('plugin missing'),
          calendarChannel: _ThrowingCalendarSyncChannel(),
          readBackgroundStatus: () async => throw StateError('jni missing'),
          openSystemSettings: (_) async => throw StateError('jni missing'),
          requestWidgetPin: (_) async => throw StateError('jni missing'),
          isCampusLoggedIn: () => true,
          isAcademicLoggedIn: () => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_notification_status')))
          .data,
      '未开启',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('welcome_calendar_status')))
          .data,
      '未开启',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('welcome_battery_status'))).data,
      '未知',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('welcome_account_status'))).data,
      '已登录',
    );

    await tester.tap(find.text('添加桌面课表组件'));
    await tester.pumpAndSettle();
    expect(find.text('添加失败，请长按桌面手动添加'), findsOneWidget);
  });

  testWidgets('根 ScaffoldMessenger 的 SnackBar 不复制到迎新页', (tester) async {
    final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();
    await pumpHost(tester, messengerKey: rootMessengerKey);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    rootMessengerKey.currentState!.showSnackBar(
      const SnackBar(content: Text('根提示消息')),
    );
    await tester.pump();

    // 迎新页独立 ScaffoldMessenger 不接管根提示，仅底层宿主 Scaffold 持有一份。
    expect(find.text('根提示消息'), findsNothing);
    expect(find.text('根提示消息', skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();

    expect(find.text('根提示消息'), findsOneWidget);
  });

  testWidgets('360dp 窄屏与 textScale 2.0 下无布局溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          textScaler: TextScaler.linear(2.0),
        ),
        child: MaterialApp(
          home: WelcomePage(
            checkNotificationsEnabled: () async => false,
            calendarChannel: _FakeCalendarSyncChannel(),
            readBackgroundStatus: () async => const SystemBackgroundStatus(
              available: true,
              ignoringBatteryOptimizations: false,
            ),
            isCampusLoggedIn: () => false,
            isAcademicLoggedIn: () => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('欢迎使用嘉兴大学'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
  });
}

class _FakeCalendarSyncChannel implements CalendarSyncChannel {
  bool granted = false;
  int requestCount = 0;

  @override
  Future<bool> checkPermissions() async => granted;

  @override
  Future<bool> requestPermissions() async {
    requestCount += 1;
    granted = true;
    return true;
  }

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() =>
      throw UnimplementedError();

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

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) => throw UnimplementedError();
}

class _ThrowingCalendarSyncChannel implements CalendarSyncChannel {
  @override
  Future<bool> checkPermissions() async => throw StateError('missing');

  @override
  Future<bool> requestPermissions() async => throw StateError('missing');

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() =>
      throw UnimplementedError();

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

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) => throw UnimplementedError();
}
