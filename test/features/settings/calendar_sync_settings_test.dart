import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';

import '../../helpers/fake_calendar_sync_native.dart';
import '../../helpers/test_setup.dart';

/// 课表日历设置（Android）的 widget 单测：只 mock 原生 MethodChannel 与
/// SharedPreferences，不触达真实系统日历与网络；断言基于「页面交互 →
/// core 控制状态 / 通道调用记录」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const calendarChannel = MethodChannel('edu.zjxu.jxucampushub/calendar_sync');

  /// 单用例硬上限：core 串行队列或原生 mock 一旦挂起，应当在 30 秒内以
  /// TimeoutException 显式失败，而不是拖满 flutter_test 默认的 10 分钟。
  const perTestTimeout = Timeout(Duration(seconds: 30));

  late FakeCalendarSyncNative native;

  /// 见 [armCoreQueuesInTestZone]：每个用例只需武装一次。
  late bool coreQueuesArmed;

  /// 在途 native gate（`createOrGetLocalCalendar` 阻塞点）。用例提前失败时也要在
  /// tearDown 释放，避免未完成的 Future/微任务链跨用例泄漏。
  Completer<void>? pendingCreateGate;

  setUp(() async {
    await resetTestEnvironment();
    coreQueuesArmed = false;
    pendingCreateGate = null;
    native = FakeCalendarSyncNative();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(calendarChannel, native.handle);
  });

  tearDown(() {
    final gate = pendingCreateGate;
    pendingCreateGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
    native.createGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(calendarChannel, null);
  });

  /// 把 core 单例的串行队列起点重建在**当前（fake-async）zone**内。
  ///
  /// `resetTestEnvironment()` 在 `setUp` 中调用，而 `setUp` 运行在真实 zone：
  /// 那时 `debugReset()` 重建的 `_queueTail = Future<void>.value()` 属于真实
  /// zone。widget 测试体内第一次 `_serialize` 会对这个真实 zone 的 Future 调
  /// `.then`，监听回调被排进真实 zone 的微任务队列；此后整条 `_serialize` 链
  /// 的续体落在 fake-async 微任务队列里，而 fake 队列只在 `pump()` 时被 drain，
  /// 于是「测试体直接 `await` 这条链」会一直挂到用例超时，UI 里发起的
  /// `enable`/`disableAndCleanup` 也推不动。
  ///
  /// 在测试体内重新 `debugReset()`（只清内存态、不动磁盘）即可让队列起点落在
  /// fake zone，整条链恢复为可在单次 `pump()` 内 drain 的微任务链。
  ///
  /// 顺带保证用例隔离：`debugReset()` 会**丢弃**上一例可能未收束的 `_queueTail`
  /// 与内存态，因此前一个用例失败留下的在途链不会阻塞后一例。
  void armCoreQueuesInTestZone() {
    if (coreQueuesArmed) return;
    coreQueuesArmed = true;
    CalendarSyncControl.instance.debugReset();
    CalendarEventLedgerStore.instance.debugReset();
  }

  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    armCoreQueuesInTestZone();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 滚动到「课表日历」分组：先滚到小节标题，再把**标题**对齐到视口顶部，
  /// 让标题与开关卡片整体可见。
  ///
  /// 不要对开关行做 `ensureVisible`：它会把开关行顶到视口顶部，标题随即滚出
  /// 可视范围并被 ListView 回收（`find.text('课表与后台')` 会变成 0）。
  Future<void> revealSyncRow(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('课表与后台'), 200);
    await tester.ensureVisible(find.text('课表与后台'));
    await tester.pumpAndSettle();
  }

  Finder syncSwitch() => find.descendant(
    of: find.ancestor(of: find.text('同步到系统日历'), matching: find.byType(Row)),
    matching: find.byType(Switch),
  );

  bool syncSwitchValue(WidgetTester tester) =>
      tester.widget<Switch>(syncSwitch()).value;

  // 页面 pump 完成后再登录：`_CurrentTermTile` 只在 initState 解析学期，
  // 未登录时立即回退日期推算，避免测试触发真实教务请求。
  void logIn(String studentId) {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: studentId);
  }

  /// `debugSetSession` 不通知监听者（真实登录路径会）；paused 副标题依赖教务
  /// 身份，这里补发与真实登录 / 登出一致的变更通知。
  void logInAndNotify(String studentId) {
    logIn(studentId);
    // ignore: invalid_use_of_protected_member
    ZhengfangAuth.instance.notifyListeners();
  }

  Future<void> seedEnabled({
    String ownerKey = '20230001',
    int calendarId = 42,
  }) async {
    armCoreQueuesInTestZone();
    final result = await CalendarSyncControl.instance.enable(
      ownerKey: ownerKey,
      calendarId: calendarId,
    );
    expect(result.enabled, isTrue);
  }

  Future<void> seedLedgerEntry({int eventId = 7}) async {
    armCoreQueuesInTestZone();
    const opaqueId = '00000001-0000-4000-8000-000000000000';
    final batch = await CalendarEventLedgerStore.instance.beginPendingBatch(
      ownerKey: '20230001',
      calendarId: 42,
      plans: const <CalendarSyncEventPlan>[
        CalendarSyncEventPlan(opaqueId: opaqueId, businessKey: 'course-1'),
      ],
    );
    final commit = await CalendarEventLedgerStore.instance.commitBatch(
      ownerKey: '20230001',
      generation: batch.generation,
      eventIds: <String, int>{opaqueId: eventId},
    );
    expect(commit.accepted, isTrue);
  }

  /// SnackBar 默认 4 秒后消失；等待它退场避免遮挡后续点击。
  ///
  /// 注意：`pump(5s)` 只推进计时器、不推进动画帧。若 SnackBar 的入场动画还没跑
  /// 完（例如只在单次 `pump()` 里显示），4 秒计时器根本不会启动，SnackBar 会一直
  /// 留在屏幕上，后续 snack 只会排队而不显示。先 settle 掉入场动画（启动计时器），
  /// 再快进超过 4 秒并 settle 掉退场动画。
  Future<void> waitForSnackBar(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('Android 默认关闭，不触发任何原生日历调用', (tester) async {
    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    expect(find.text('课表与后台'), findsOneWidget);
    expect(find.text('同步到系统日历'), findsOneWidget);
    expect(syncSwitchValue(tester), isFalse);
    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(native.calls, isEmpty);
  }, timeout: perTestTimeout);

  testWidgets('iOS 不展示课表日历分组，也不调用原生', (tester) async {
    await pumpSettingsPage(tester, platform: TargetPlatform.iOS);

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('同步到系统日历'), findsNothing);
    expect(native.calls, isEmpty);
  }, timeout: perTestTimeout);

  testWidgets('未登录教务时拒绝开启，且不调用原生', (tester) async {
    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    await tester.tap(find.text('同步到系统日历'));
    await tester.pump();

    expect(find.text('请先登录教务系统，再开启课表日历同步'), findsOneWidget);
    expect(find.text('开启课表日历同步'), findsNothing);
    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(native.calls, isEmpty);
  }, timeout: perTestTimeout);

  testWidgets('权限拒绝时安全失败，不创建日历也不写入', (tester) async {
    native.permissions = false;
    native.grantOnRequest = false;
    await pumpSettingsPage(tester);
    logIn('20230001');
    await revealSyncRow(tester);

    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用专属本地日历'));
    await tester.pumpAndSettle();

    expect(find.text('未获得日历读写权限，同步未开启'), findsOneWidget);
    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(native.createCalendarCalls, 0);
    expect(syncSwitchValue(tester), isFalse);
  }, timeout: perTestTimeout);

  testWidgets('开启时可选专属本地日历，成功后绑定当前账号', (tester) async {
    await pumpSettingsPage(tester);
    logIn('20230001');
    await revealSyncRow(tester);

    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();

    expect(find.text('开启课表日历同步'), findsOneWidget);
    // 对话框如实说明：专属本地日历可能不被系统日历应用显示、手动编辑会被覆盖。
    expect(find.textContaining('系统日历应用可能不显示'), findsOneWidget);
    expect(find.textContaining('下一次课表同步会覆盖'), findsOneWidget);

    await tester.tap(find.text('使用专属本地日历'));
    await tester.pumpAndSettle();

    final control = CalendarSyncControl.instance;
    expect(control.state, CalendarSyncControlState.enabled);
    expect(control.ownerKey, '20230001');
    expect(control.calendarId, 42);
    expect(native.createCalendarCalls, 1);
    expect(find.text('课表日历同步已开启，前台校验课表后同步'), findsOneWidget);
    expect(syncSwitchValue(tester), isTrue);
  }, timeout: perTestTimeout);

  testWidgets('开启时可选已有可写日历，先申请权限再列出', (tester) async {
    native.permissions = false;
    native.grantOnRequest = true;
    native.calendars = const <CalendarSyncWritableCalendar>[
      CalendarSyncWritableCalendar(
        id: 7,
        displayName: '工作日程',
        accountName: 'test@example.com',
      ),
    ];
    await pumpSettingsPage(tester);
    logIn('20230001');
    await revealSyncRow(tester);

    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择其他日历'));
    await tester.pumpAndSettle();

    expect(native.requestCalls, 1);
    expect(native.listCalls, 1);
    expect(find.text('工作日程'), findsOneWidget);

    await tester.tap(find.text('工作日程'));
    await tester.pumpAndSettle();

    final control = CalendarSyncControl.instance;
    expect(control.state, CalendarSyncControlState.enabled);
    expect(control.ownerKey, '20230001');
    expect(control.calendarId, 7);
    expect(native.createCalendarCalls, 0);
  }, timeout: perTestTimeout);

  testWidgets('可写日历为空或用户取消时安全返回，不开启同步', (tester) async {
    await pumpSettingsPage(tester);
    logIn('20230001');
    await revealSyncRow(tester);

    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择其他日历'));
    await tester.pumpAndSettle();

    expect(find.text('没有可写入的系统日历'), findsOneWidget);
    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    await waitForSnackBar(tester);

    native.calendars = const <CalendarSyncWritableCalendar>[
      CalendarSyncWritableCalendar(id: 7, displayName: '工作日程'),
    ];
    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择其他日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(native.createCalendarCalls, 0);
  }, timeout: perTestTimeout);

  testWidgets('登出/换号后 paused 不自动同步，重新开启绑定当前账号', (tester) async {
    await seedEnabled(ownerKey: '20230001');
    final paused = await CalendarSyncControl.instance.pauseIfOwnerMismatch(
      ownerKey: '20230002',
      revision: 2,
    );
    expect(paused, CalendarSyncControlState.paused);

    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    // 真正换号：当前有另一个已验证教务账号，才提示账号不一致。
    logInAndNotify('20230002');
    await tester.pumpAndSettle();

    expect(syncSwitchValue(tester), isFalse);
    expect(find.textContaining('已暂停'), findsOneWidget);
    expect(find.textContaining('账号不一致'), findsOneWidget);
    // 暂停状态不会自动写入任何事件。
    expect(
      native.calls.where(
        (method) =>
            method == 'upsertEventBatch' || method == 'deleteOwnedEventsByIds',
      ),
      isEmpty,
    );

    // 显式重新开启：绑定当前登录账号，而不是默默沿用旧账号。
    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用专属本地日历'));
    await tester.pumpAndSettle();

    final control = CalendarSyncControl.instance;
    expect(control.state, CalendarSyncControlState.enabled);
    expect(control.ownerKey, '20230002');
  }, timeout: perTestTimeout);

  testWidgets('旧版本因登出落盘的 paused：无已验证教务身份时提示登录后自动恢复，不显示账号不一致', (tester) async {
    await seedEnabled(ownerKey: '20230001');
    final paused = await CalendarSyncControl.instance.pauseIfOwnerMismatch(
      ownerKey: '20230002',
      revision: 2,
    );
    expect(paused, CalendarSyncControlState.paused);
    // 教务此刻未登录（旧版本登出时落盘的 paused 会一直保留到重新登录）。
    expect(ZhengfangAuth.instance.verifiedStudentId, isNull);

    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    expect(syncSwitchValue(tester), isFalse);
    expect(find.textContaining('登录教务系统后将自动恢复（同一账号）'), findsOneWidget);
    expect(find.textContaining('账号不一致'), findsNothing);

    // 登录了另一个账号：切换为账号不一致文案。
    logInAndNotify('20230002');
    await tester.pumpAndSettle();
    expect(find.textContaining('账号不一致'), findsOneWidget);
    expect(find.textContaining('自动恢复（同一账号）'), findsNothing);

    // 再次登出：回到「登录后自动恢复」文案。
    await ZhengfangAuth.instance.markLoggedOut();
    await tester.pumpAndSettle();
    expect(find.textContaining('自动恢复（同一账号）'), findsOneWidget);
    expect(find.textContaining('账号不一致'), findsNothing);
  }, timeout: perTestTimeout);

  testWidgets('教务登出/会话缺失：开关保持开启并提示等待登录，不显示账号不一致', (tester) async {
    await seedEnabled(ownerKey: '20230001');
    final state = await CalendarSyncControl.instance.pauseIfOwnerMismatch(
      ownerKey: null,
      revision: 2,
    );
    expect(state, CalendarSyncControlState.enabled);

    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    expect(syncSwitchValue(tester), isTrue);
    expect(find.textContaining('等待登录教务系统'), findsOneWidget);
    expect(find.textContaining('账号不一致'), findsNothing);
    expect(find.textContaining('已暂停'), findsNothing);
    expect(
      native.calls.where(
        (method) =>
            method == 'upsertEventBatch' || method == 'deleteOwnedEventsByIds',
      ),
      isEmpty,
    );

    // 同一学号重新登录后提示消失，开关仍开启。
    await CalendarSyncControl.instance.pauseIfOwnerMismatch(
      ownerKey: '20230001',
      revision: 3,
    );
    await tester.pumpAndSettle();
    expect(syncSwitchValue(tester), isTrue);
    expect(find.textContaining('等待登录教务系统'), findsNothing);
  }, timeout: perTestTimeout);

  testWidgets('关闭确认对话框取消时不扫描也不删除任何事件', (tester) async {
    await seedEnabled();
    await seedLedgerEntry();
    await pumpSettingsPage(tester);
    await revealSyncRow(tester);

    expect(syncSwitchValue(tester), isTrue);
    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();

    expect(find.text('关闭课表日历同步'), findsOneWidget);
    expect(find.textContaining('扫描会先关闭同步，不会删除任何日程'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 取消后既不扫描也不删除，状态保持 enabled、账本不动。
    expect(native.listOwnedCalls, 0);
    expect(native.deleteCalls, 0);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.enabled,
    );
    expect(await CalendarSyncControl.instance.residualCount(), 1);
  }, timeout: perTestTimeout);

  testWidgets('扫描预览后确认清理：残留如实报告，可重新扫描清理干净', (tester) async {
    const ledgerOpaque = '00000001-0000-4000-8000-000000000000';
    const orphanOpaque = '00000002-0000-4000-8000-000000000000';
    await seedEnabled();
    await seedLedgerEntry();
    native.ownedCalendars = const <CalendarOwnedCalendarInfo>[
      CalendarOwnedCalendarInfo(
        calendarId: 42,
        displayName: '课程日历',
        writable: true,
      ),
    ];
    // provider 中：一条与账本同 opaqueId（已记账），一条孤儿（未记账）。
    native.ownedEvents = <int, List<CalendarSyncOwnedEvent>>{
      42: const <CalendarSyncOwnedEvent>[
        CalendarSyncOwnedEvent(opaqueId: ledgerOpaque, eventId: 7),
        CalendarSyncOwnedEvent(opaqueId: orphanOpaque, eventId: 8),
      ],
    };
    // 只删掉已记账那条，孤儿删除失败 → 有残留。
    native.onDelete = (events) => CalendarSyncDeleteResult(
      deletedIds: const <int>[7],
      notDeletedIds: const <int>[8],
    );

    await pumpSettingsPage(tester);
    logIn('20230001');
    await revealSyncRow(tester);

    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭并扫描'));
    await tester.pumpAndSettle();

    // 预览如实分列：总 2 条、未确认 1 条。
    expect(find.textContaining('发现 2 条带当前应用标记的遗留日程'), findsOneWidget);
    expect(find.textContaining('其中 1 条未被本地记录确认'), findsOneWidget);
    expect(find.text('清理已确认的日程'), findsOneWidget);

    await tester.tap(find.text('清理已确认的日程'));
    await tester.pumpAndSettle();

    // 残留时如实报告数量与原因，绝不假称关闭成功。
    expect(find.textContaining('仍有 1 条未能确认'), findsWidgets);
    expect(find.textContaining('已清理遗留日程'), findsNothing);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.cleanupPending,
    );
    expect(syncSwitchValue(tester), isFalse);
    expect(find.text('上次清理结果'), findsOneWidget);

    await waitForSnackBar(tester);

    // cleanupPending 期间开关不能重新开启（不覆盖残留账本）。
    await tester.ensureVisible(find.text('同步到系统日历'));
    await tester.tap(find.text('同步到系统日历'));
    await tester.pump();
    expect(find.text('存在未完成的清理，请先点击「扫描遗留日程」'), findsOneWidget);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.cleanupPending,
    );
    await waitForSnackBar(tester);

    // 删除行为恢复后重新扫描：残留清空，回到 off。
    native.onDelete = null;
    await tester.ensureVisible(find.text('扫描遗留日程'));
    await tester.tap(find.text('扫描遗留日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理已确认的日程'));
    await tester.pumpAndSettle();

    expect(CalendarSyncControl.instance.state, CalendarSyncControlState.off);
    expect(find.text('已清理遗留日程'), findsOneWidget);
    expect(await CalendarSyncControl.instance.residualCount(), 0);
    expect(find.text('上次清理结果'), findsNothing);
  }, timeout: perTestTimeout);

  testWidgets('开启请求在途时重复点击不会发起第二次调用', (tester) async {
    await pumpSettingsPage(tester);
    logIn('20230001');
    await revealSyncRow(tester);

    final gate = Completer<void>();
    pendingCreateGate = gate;
    native.createGate = gate.future;

    await tester.tap(find.text('同步到系统日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用专属本地日历'));
    await tester.pump();
    // 等对话框完全退场，此时 enable 仍被 gate 阻塞。
    await tester.pump(const Duration(milliseconds: 300));

    await tester.ensureVisible(find.text('同步到系统日历'));
    await tester.tap(find.text('同步到系统日历'));
    await tester.pump();
    await tester.tap(find.text('同步到系统日历'));
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();
    // 让在途 enable 链完全收束（drain 微任务 / 帧），不把未完成的异步留给下一例。
    await tester.idle();

    expect(native.createCalendarCalls, 1);
    expect(
      CalendarSyncControl.instance.state,
      CalendarSyncControlState.enabled,
    );
  }, timeout: perTestTimeout);
}
