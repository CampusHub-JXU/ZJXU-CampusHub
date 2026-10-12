import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';
import 'package:jxu_campus_hub/features/settings/calendar_legacy_cleanup_dialog.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';

import '../../helpers/fake_calendar_sync_native.dart';
import '../../helpers/test_setup.dart';

/// Issue #48 遗留清理 UI 的 widget 单测：只 mock 原生 MethodChannel 与
/// SharedPreferences，不触达真实系统日历 / 网络 / 真实账号数据。
///
/// 全部日历名 / opaqueId 均为**合成**规范 UUID，绝不使用真实课程或学号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const calendarChannel = MethodChannel('edu.zjxu.jxucampushub/calendar_sync');
  const perTestTimeout = Timeout(Duration(seconds: 30));

  const opaqueA = '11111111-1111-4111-8111-111111111111';
  const opaqueB = '22222222-2222-4222-8222-222222222222';

  late FakeCalendarSyncNative native;
  late bool coreQueuesArmed;
  Completer<void>? pendingGate;

  CalendarSyncOwnedEvent event(String opaqueId, int eventId) =>
      CalendarSyncOwnedEvent(opaqueId: opaqueId, eventId: eventId);

  setUp(() async {
    await resetTestEnvironment();
    coreQueuesArmed = false;
    pendingGate = null;
    native = FakeCalendarSyncNative();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(calendarChannel, native.handle);
  });

  tearDown(() {
    final gate = pendingGate;
    pendingGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    native.listOwnedGate = null;
    native.createGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(calendarChannel, null);
  });

  /// 把 core 单例的串行队列起点重建在**当前（fake-async）zone**内（见
  /// `calendar_sync_settings_test.dart` 的同名说明）。
  void armCoreQueuesInTestZone() {
    if (coreQueuesArmed) return;
    coreQueuesArmed = true;
    CalendarSyncControl.instance.debugReset();
    CalendarEventLedgerStore.instance.debugReset();
  }

  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    double width = 412,
    double textScale = 1.0,
    Brightness brightness = Brightness.light,
  }) async {
    armCoreQueuesInTestZone();
    const dpr = 3.0;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = Size(width * dpr, 900 * dpr);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          brightness: brightness,
        ),
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: child!,
        ),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> revealSyncRow(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('课表与后台'), 200);
    await tester.ensureVisible(find.text('课表与后台'));
    await tester.pumpAndSettle();
  }

  Future<void> scan(WidgetTester tester) async {
    await revealSyncRow(tester);
    await tester.tap(find.text('扫描遗留日程'));
    await tester.pumpAndSettle();
  }

  Finder inSheet(Finder matching) => find.descendant(
    of: find.byType(CalendarLegacyCleanupPreviewSheet),
    matching: matching,
  );

  testWidgets('关闭态：可见「扫描遗留日程」，空扫描不删除、不需要登录 / 权限', (tester) async {
    // 权限未授予、未登录也能用只读扫描入口。
    native.permissions = false;
    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    expect(find.text('扫描遗留日程'), findsOneWidget);
    expect(find.text('只读扫描带当前应用标记的遗留日程，不会删除任何日程'), findsOneWidget);

    await tester.tap(find.text('扫描遗留日程'));
    await tester.pumpAndSettle();

    expect(native.listOwnedCalls, 1);
    expect(native.deleteCalls, 0);
    expect(find.text('未发现带当前应用标记的遗留日程'), findsOneWidget);
    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(find.text('扫描遗留日程'), findsOneWidget);
  }, timeout: perTestTimeout);

  testWidgets('两处孤儿：预览分列数量、不展示原始 id，确认后才删除并回到关闭', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(
        calendarId: 77,
        displayName: '课程日历',
        writable: true,
      ),
    ];
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      77: <CalendarSyncOwnedEvent>[event(opaqueA, 1), event(opaqueB, 2)],
    };

    await pumpSettingsPage(tester);
    await scan(tester);

    expect(find.text('清理已确认的日程'), findsOneWidget);
    expect(inSheet(find.textContaining('发现 2 条带当前应用标记的遗留日程')), findsOneWidget);
    expect(inSheet(find.textContaining('其中 2 条未被本地记录确认')), findsOneWidget);
    expect(inSheet(find.text('课程日历')), findsOneWidget);
    expect(
      inSheet(find.textContaining('已记账 0 · 未确认 2 · 共 2 条')),
      findsOneWidget,
    );
    // 绝不泄露原始日历 id / opaqueId。
    expect(inSheet(find.textContaining('77')), findsNothing);
    expect(inSheet(find.textContaining(opaqueA)), findsNothing);
    // 扫描本身绝不删除。
    expect(native.deleteCalls, 0);

    await tester.tap(find.text('清理已确认的日程'));
    await tester.pumpAndSettle();

    expect(native.deleteCalls, 1);
    expect(find.text('已清理遗留日程'), findsOneWidget);
    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(find.text('扫描遗留日程'), findsOneWidget);
  }, timeout: perTestTimeout);

  testWidgets('取消 / 点击遮罩关闭预览：不删除，保持 cleanupPending', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(calendarId: 77, writable: true),
    ];
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      77: <CalendarSyncOwnedEvent>[event(opaqueA, 1)],
    };

    await pumpSettingsPage(tester);
    await scan(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(native.deleteCalls, 0);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.cleanupPending,
    );

    // 重新扫描后用遮罩关闭：同样不删除。
    await tester.ensureVisible(find.text('扫描遗留日程'));
    await tester.tap(find.text('扫描遗留日程'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();

    expect(native.deleteCalls, 0);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.cleanupPending,
    );
  }, timeout: perTestTimeout);

  testWidgets('只读 / 归属未知的日历不提供删除，只如实说明不能清理', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(
        calendarId: 5,
        displayName: '只读日历',
        writable: false,
      ),
      CalendarOwnedCalendarInfo(calendarId: 6, writable: null),
    ];
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      5: <CalendarSyncOwnedEvent>[event(opaqueA, 1)],
      6: <CalendarSyncOwnedEvent>[event(opaqueB, 2)],
    };
    // 归属未知（writable=null）会让整次扫描不完整。
    native.discoveryComplete = false;
    native.discoveryReason = CalendarOwnedDiscoveryReason.calendarUnavailable;

    await pumpSettingsPage(tester);
    await scan(tester);

    expect(find.text('扫描结果（不完整）'), findsOneWidget);
    expect(inSheet(find.text('只读日历')), findsOneWidget);
    expect(inSheet(find.text('只读日历，不能清理')), findsOneWidget);
    expect(inSheet(find.text('日历')), findsOneWidget);
    expect(inSheet(find.text('归属日历状态未确认，不能清理')), findsOneWidget);
    expect(find.text('清理已确认的日程'), findsNothing);
    expect(native.deleteCalls, 0);
  }, timeout: perTestTimeout);

  testWidgets('权限被拒：提供显式授权入口，授权后重新扫描', (tester) async {
    native.permissions = false;
    native.grantOnRequest = true;
    native.discoveryComplete = false;
    native.discoveryReason = CalendarOwnedDiscoveryReason.permissionDenied;

    await pumpSettingsPage(tester);
    await scan(tester);

    expect(find.text('授予日历权限'), findsOneWidget);
    expect(find.text('清理已确认的日程'), findsNothing);
    expect(find.textContaining('日历权限被拒绝'), findsOneWidget);

    await tester.tap(find.text('授予日历权限'));
    await tester.pumpAndSettle();

    expect(native.requestCalls, 1);
    expect(native.listOwnedCalls, 2);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  }, timeout: perTestTimeout);

  testWidgets('不完整扫描 0 条：不出现「未发现遗留」的假干净结论', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(
        calendarId: 9,
        displayName: '课程日历',
        writable: true,
      ),
    ];
    native.scanComplete = false;
    native.scanReason = CalendarOwnedDiscoveryReason.scanLimit;

    await pumpSettingsPage(tester);
    await scan(tester);

    expect(find.text('扫描结果（不完整）'), findsOneWidget);
    expect(inSheet(find.textContaining('但扫描不完整')), findsOneWidget);
    expect(find.text('未发现带当前应用标记的遗留日程'), findsNothing);
    expect(find.text('清理已确认的日程'), findsNothing);
    expect(find.text('重新扫描'), findsOneWidget);
    expect(native.deleteCalls, 0);
  }, timeout: perTestTimeout);

  testWidgets('不完整扫描有已确认候选：允许部分清理，结果不说「0 残留」', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(
        calendarId: 9,
        displayName: '课程日历',
        writable: true,
      ),
    ];
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      9: <CalendarSyncOwnedEvent>[event(opaqueA, 1)],
    };
    native.scanComplete = false;
    native.scanReason = CalendarOwnedDiscoveryReason.scanLimit;

    await pumpSettingsPage(tester);
    await scan(tester);

    expect(inSheet(find.textContaining('仅清理本次扫描确认的部分')), findsOneWidget);
    await tester.tap(find.text('清理已确认的日程'));
    await tester.pumpAndSettle();

    // 复扫仍不完整 → 绝不显示「已清理 / 0 残留」。
    expect(find.textContaining('清理未完成；仍有未能确认的范围'), findsWidgets);
    expect(find.text('已清理遗留日程'), findsNothing);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.cleanupPending,
    );
  }, timeout: perTestTimeout);

  testWidgets('预览过期（对象非当前扫描）：提示重新扫描且不删除', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(calendarId: 77, writable: true),
    ];
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      77: <CalendarSyncOwnedEvent>[event(opaqueA, 1)],
    };

    await pumpSettingsPage(tester);
    await scan(tester);

    // 期间直接发起一次新扫描，使弹层持有的旧预览失效。
    await CalendarSyncControl.instance.scanLegacyOwnedEvents();
    await tester.pump();

    await tester.tap(find.text('清理已确认的日程'));
    await tester.pumpAndSettle();

    expect(find.textContaining('扫描已过期，请重新扫描'), findsWidgets);
    expect(native.deleteCalls, 0);
  }, timeout: perTestTimeout);

  testWidgets('扫描在途时重复点击只发起一次原生扫描', (tester) async {
    final gate = Completer<void>();
    pendingGate = gate;
    native.listOwnedGate = gate.future;

    await pumpSettingsPage(tester);
    await revealSyncRow(tester);
    await tester.tap(find.text('扫描遗留日程'));
    await tester.pump();

    // 在途显示真实进度文案，且扫描入口被进度行替换。
    expect(find.text('正在扫描遗留日程…'), findsOneWidget);
    expect(find.text('扫描遗留日程'), findsNothing);
    await tester.tap(find.text('同步到系统日历'));
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    expect(native.listOwnedCalls, 1);
    expect(native.deleteCalls, 0);
  }, timeout: perTestTimeout);

  testWidgets('扫描在途离开页面：不抛异常、不 setState after dispose', (tester) async {
    final gate = Completer<void>();
    pendingGate = gate;
    native.listOwnedGate = gate.future;

    await pumpSettingsPage(tester);
    await revealSyncRow(tester);
    await tester.tap(find.text('扫描遗留日程'));
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  }, timeout: perTestTimeout);

  testWidgets('360 宽 / 2 倍字号 / 深色：不溢出，长日历名换行不截断，按钮 48 高', (tester) async {
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(
        calendarId: 1,
        displayName: '这是一个很长的课程日历名称用于验证在窄屏与大字号下会自动换行而不被截断',
        writable: true,
      ),
      CalendarOwnedCalendarInfo(
        calendarId: 2,
        displayName: '第二个日历',
        writable: true,
      ),
    ];
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      1: <CalendarSyncOwnedEvent>[event(opaqueA, 1)],
      2: <CalendarSyncOwnedEvent>[event(opaqueB, 2)],
    };

    await pumpSettingsPage(
      tester,
      width: 360,
      textScale: 2.0,
      brightness: Brightness.dark,
    );
    await scan(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('清理已确认的日程'), findsOneWidget);
    final size = tester.getSize(find.widgetWithText(TextButton, '清理已确认的日程'));
    expect(size.height, greaterThanOrEqualTo(48));
  }, timeout: perTestTimeout);
}
