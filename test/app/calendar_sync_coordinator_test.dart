import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/calendar_event_projector.dart';
import 'package:jxu_campus_hub/app/calendar_sync_coordinator.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';

/// 纯内存假通道：绝不触达真实系统日历，记录 native 调用与 payload。
class _FakeChannel implements CalendarSyncChannel, CalendarOwnedEventDiscovery {
  bool permissions = true;
  int _eventIdSeq = 1000;
  final List<String> calls = <String>[];
  final List<CalendarSyncEventDraft> upsertedDrafts =
      <CalendarSyncEventDraft>[];
  final List<CalendarSyncOwnedEvent> deletedEvents = <CalendarSyncOwnedEvent>[];

  /// opaqueId → provider eventId（用于 reconcile 查询与删除命中判定）。
  final Map<String, int> ownedByOpaqueId = <String, int>{};

  /// 只读扫描是否完整（默认完整；可注入 false 模拟 provider 不可用）。
  bool scanComplete = true;

  /// 置上后下一次 upsert 会等待该 Completer（确定性并发测试）。
  Completer<void>? upsertGate;

  Future<CalendarSyncBatchResult> Function(
    int calendarId,
    List<CalendarSyncEventDraft> events,
  )?
  onUpsert;

  Future<CalendarSyncDeleteResult> Function(
    int calendarId,
    List<CalendarSyncOwnedEvent> events,
  )?
  onDelete;

  int upsertCalls = 0;
  int deleteCalls = 0;

  @override
  Future<bool> checkPermissions() async {
    calls.add('checkPermissions');
    return permissions;
  }

  @override
  Future<bool> requestPermissions() async {
    calls.add('requestPermissions');
    return permissions;
  }

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() async {
    calls.add('createOrGetLocalCalendar');
    return const CalendarSyncLocalCalendar(id: 42, displayName: '嘉兴大学课程');
  }

  @override
  Future<List<CalendarSyncWritableCalendar>> listWritableCalendars() async {
    calls.add('listWritableCalendars');
    return const <CalendarSyncWritableCalendar>[];
  }

  @override
  Future<List<CalendarSyncOwnedEvent>> queryOwnedEvents({
    required int calendarId,
    List<String>? opaqueIds,
  }) async {
    calls.add('queryOwnedEvents');
    final requested = opaqueIds ?? ownedByOpaqueId.keys.toList();
    return <CalendarSyncOwnedEvent>[
      for (final opaqueId in requested)
        if (ownedByOpaqueId.containsKey(opaqueId))
          CalendarSyncOwnedEvent(
            opaqueId: opaqueId,
            eventId: ownedByOpaqueId[opaqueId]!,
          ),
    ];
  }

  @override
  Future<CalendarSyncBatchResult> upsertEventBatch({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  }) async {
    calls.add('upsertEventBatch');
    upsertCalls++;
    final gate = upsertGate;
    if (gate != null) {
      upsertGate = null;
      await gate.future;
    }
    final handler = onUpsert;
    if (handler != null) return handler(calendarId, events);

    upsertedDrafts.addAll(events);
    final eventIds = <String, int>{};
    var inserted = 0;
    var updated = 0;
    for (final event in events) {
      final existing = ownedByOpaqueId[event.opaqueId];
      final id = existing ?? ++_eventIdSeq;
      if (existing == null) {
        inserted++;
      } else {
        updated++;
      }
      ownedByOpaqueId[event.opaqueId] = id;
      eventIds[event.opaqueId] = id;
    }
    return CalendarSyncBatchResult(
      insertedCount: inserted,
      updatedCount: updated,
      eventIds: eventIds,
    );
  }

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) async {
    calls.add('deleteOwnedEventsByIds');
    deleteCalls++;
    final handler = onDelete;
    if (handler != null) return handler(calendarId, events);

    deletedEvents.addAll(events);
    final deleted = <int>[];
    final notDeleted = <int>[];
    for (final event in events) {
      if (ownedByOpaqueId[event.opaqueId] == event.eventId) {
        deleted.add(event.eventId);
        ownedByOpaqueId.remove(event.opaqueId);
      } else {
        notDeleted.add(event.eventId);
      }
    }
    return CalendarSyncDeleteResult(
      deletedIds: deleted,
      notDeletedIds: notDeleted,
    );
  }

  @override
  Future<CalendarOwnedCalendarDiscovery> listOwnedEventCalendars() async {
    calls.add('listOwnedEventCalendars');
    return CalendarOwnedCalendarDiscovery(
      calendars: const <CalendarOwnedCalendarInfo>[],
      complete: scanComplete,
      reason: scanComplete ? null : CalendarOwnedDiscoveryReason.unavailable,
    );
  }

  @override
  Future<CalendarOwnedEventScan> scanOwnedEvents({
    required int calendarId,
  }) async {
    calls.add('scanOwnedEvents');
    return CalendarOwnedEventScan(
      events: <CalendarSyncOwnedEvent>[
        for (final entry in ownedByOpaqueId.entries)
          CalendarSyncOwnedEvent(opaqueId: entry.key, eventId: entry.value),
      ],
      complete: scanComplete,
      reason: scanComplete ? null : CalendarOwnedDiscoveryReason.unavailable,
    );
  }
}

List<ProjectedCourseOccurrence> _defaultProjector({
  required ScheduleCacheSnapshot snapshot,
  required String verifiedOwner,
  required ScheduleTermContext confirmedCurrentTerm,
  required DateTime semesterStartDate,
  required DateTime now,
  required int reminderMinutes,
}) => projectCurrentTermCalendarEvents(
  snapshot: snapshot,
  verifiedOwner: verifiedOwner,
  confirmedCurrentTerm: confirmedCurrentTerm,
  semesterStartDate: semesterStartDate,
  now: now,
  reminderMinutes: reminderMinutes,
);

class _Harness {
  _Harness({CalendarSyncProjector? projector}) {
    control = CalendarSyncControl.debugNew(
      channel: channel,
      ledger: ledger,
      store: CalendarSyncControlStore.debugNew(),
      discovery: channel,
    );
    coordinator = CalendarSyncCoordinator.debugNew(
      channel: channel,
      control: control,
      ledger: ledger,
      readIdentity: () => identity,
      loadSnapshot: ({required ownerKey, required term}) => snapshot,
      readKnownCurrentTerm: () => term,
      clock: () => now,
      readSemesterStartDate: () => semesterStart,
      projector: projector ?? _defaultProjector,
      reminderMinutesReader: () => reminderMinutes,
      discovery: channel,
    );
  }

  final _FakeChannel channel = _FakeChannel();
  final CalendarEventLedgerStore ledger = CalendarEventLedgerStore.debugNew();
  late final CalendarSyncControl control;
  late final CalendarSyncCoordinator coordinator;

  CalendarSyncIdentity identity = const CalendarSyncIdentity(
    isLoggedIn: false,
    revision: 0,
  );
  ScheduleCacheSnapshot? snapshot;
  ScheduleTermContext? term;
  DateTime now = DateTime(2026, 9, 10, 12);
  DateTime semesterStart = DateTime(2026, 8, 31);

  /// 当前生效的提醒提前量（模拟持久化设置，测试可改后重跑）。
  int reminderMinutes = ProjectedCourseOccurrence.defaultReminderMinutes;

  Future<void> enable(
    String owner,
    int calendarId, {
    required int revision,
  }) async {
    identity = CalendarSyncIdentity(
      isLoggedIn: true,
      ownerKey: owner,
      revision: revision,
    );
    final result = await control.enable(
      ownerKey: owner,
      calendarId: calendarId,
      revision: revision,
    );
    expect(result.enabled, isTrue, reason: 'enable 应成功');
  }

  ScheduleCacheSnapshot snapshotWith({
    List<CourseEntry>? courses,
    String studentId = _ownerA,
    ScheduleTermContext termContext = _term2026,
    DateTime? scheduleUpdatedAt,
    DateTime? changeRulesUpdatedAt,
    bool changeRulesCurrentScoped = true,
    bool changeRulesDateAware = true,
  }) => ScheduleCacheSnapshot(
    studentId: studentId,
    termContext: termContext,
    courses: courses ?? const <CourseEntry>[_mathCourse],
    changeRules: const [],
    scheduleUpdatedAt:
        scheduleUpdatedAt ?? now.subtract(const Duration(hours: 2)),
    changeRulesUpdatedAt:
        changeRulesUpdatedAt ?? now.subtract(const Duration(hours: 2)),
    changeRulesCurrentScoped: changeRulesCurrentScoped,
    changeRulesDateAware: changeRulesDateAware,
  );

  Future<void> run() async {
    coordinator.requestSync();
    await coordinator.waitForIdle();
  }
}

const String _ownerA = '20230001';
const int _calendarId = 7;
const ScheduleTermContext _term2026 = ScheduleTermContext(
  academicYear: 2026,
  term: 3,
);

/// 20 周、周一第 1-2 节。
const CourseEntry _mathCourse = CourseEntry(
  courseName: '高等数学',
  teacherName: '张老师',
  weekday: 1,
  startLesson: 1,
  endLesson: 2,
  weekRange: '1-20周',
  classroom: 'A101',
  campus: '梁林校区',
  typeSymbol: '◆',
);

/// 仅第 1 周、周一第 1-2 节（单事件，便于精确断言）。
const CourseEntry _oneWeekCourse = CourseEntry(
  courseName: '高等数学',
  teacherName: '张老师',
  weekday: 1,
  startLesson: 1,
  endLesson: 2,
  weekRange: '1周',
  classroom: 'A101',
  campus: '梁林校区',
  typeSymbol: '◆',
);

String _opaqueId(int index) =>
    '${index.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000';

String _manualBusinessKey(ScheduleTermContext term, String label) =>
    'calendar-course-v1\u001F${term.key}\u001F$label\u001F老师\u001F1\u001F1-2\u001F1\u001FA101';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppLogger.instance.debugReset();
  });

  group('默认关闭', () {
    test('关闭时零 native 写', () async {
      final h = _Harness();
      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: _ownerA,
        revision: 1,
      );
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      await h.run();

      expect(h.channel.calls, isNot(contains('upsertEventBatch')));
      expect(h.channel.calls, isNot(contains('deleteOwnedEventsByIds')));
      expect(h.control.state, CalendarSyncControlState.off);
    });
  });

  group('可信投影', () {
    test('展开 20 周且按设置默认 20 分钟提醒', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      expect(h.channel.upsertedDrafts, hasLength(20));
      expect(
        h.channel.upsertedDrafts.every((draft) => draft.reminderMinutes == 20),
        isTrue,
      );
      expect(
        h.channel.upsertedDrafts.every(
          (draft) => draft.timeZone == 'Asia/Shanghai',
        ),
        isTrue,
      );
      final snapshot = await h.ledger.reload();
      expect(snapshot.batchesFor(_ownerA), hasLength(1));
      expect(snapshot.allEntries, hasLength(20));
      expect(snapshot.pendingEntryCount, 0);
    });

    test('仅改提醒提前量：既有归属事件按新值 upsert，不因 businessKey 相同被忽略', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      // 首轮：按默认 20 分钟新建 20 条归属事件。
      await h.run();
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      expect(h.channel.upsertedDrafts, hasLength(20));
      final firstIds = Map<String, int>.of(h.channel.ownedByOpaqueId);
      expect(firstIds, hasLength(20));

      // 第二轮：只改提醒提前量为 30，businessKey / 时间全部不变。
      h.reminderMinutes = 30;
      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      // 既有 20 条被覆盖更新（同一 opaqueId → 同一 eventId），不新建、不删除。
      final secondRun = h.channel.upsertedDrafts.sublist(20);
      expect(secondRun, hasLength(20));
      expect(secondRun.every((draft) => draft.reminderMinutes == 30), isTrue);
      expect(h.channel.ownedByOpaqueId, firstIds);
      expect(h.channel.deleteCalls, 0);
    });

    test('businessKey 学期字段判定与 projector 输出一致', () {
      final h = _Harness();
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      final occurrences = _defaultProjector(
        snapshot: h.snapshot!,
        verifiedOwner: _ownerA,
        confirmedCurrentTerm: _term2026,
        semesterStartDate: h.semesterStart,
        now: h.now,
        reminderMinutes: ProjectedCourseOccurrence.defaultReminderMinutes,
      );
      expect(occurrences, isNotEmpty);
      expect(
        occurrences.every(
          (o) => calendarBusinessKeyBelongsToTerm(o.businessKey, _term2026),
        ),
        isTrue,
      );
      expect(
        calendarBusinessKeyBelongsToTerm(
          occurrences.first.businessKey,
          const ScheduleTermContext(academicYear: 2025, term: 3),
        ),
        isFalse,
      );
    });
  });

  group('fail-closed 拒绝', () {
    test('未确认学期不写', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = null;
      h.snapshot = h.snapshotWith();

      await h.run();

      expect(h.channel.upsertCalls, 0);
      expect(h.channel.deleteCalls, 0);
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.noWork);
    });

    test('快照 owner 不符不写', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith(studentId: '20230099');

      await h.run();

      expect(h.channel.upsertCalls, 0);
      expect(h.channel.deleteCalls, 0);
    });

    test('过期快照不写', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith(
        scheduleUpdatedAt: h.now.subtract(const Duration(days: 30)),
      );

      await h.run();

      expect(h.channel.upsertCalls, 0);
      expect(h.channel.deleteCalls, 0);
    });
  });

  group('身份变化', () {
    test('同账号重登不暂停并复用映射；切号暂停且不写', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      await h.run();
      final firstOpaqueIds = h.channel.upsertedDrafts
          .map((draft) => draft.opaqueId)
          .toSet();
      expect(firstOpaqueIds, hasLength(20));

      // 同账号重登（revision 推进）：不暂停、复用同一批 opaqueId。
      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: _ownerA,
        revision: 2,
      );
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();

      expect(h.control.state, CalendarSyncControlState.enabled);
      final afterRelogin = await h.ledger.reload();
      expect(afterRelogin.batchesFor(_ownerA), hasLength(1));
      expect(afterRelogin.allEntries, hasLength(20));
      expect(
        h.channel.upsertedDrafts
            .skip(20)
            .map((draft) => draft.opaqueId)
            .toSet(),
        firstOpaqueIds,
      );

      // 切号：暂停、不再写、保留原 owner 账本。
      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: '20230002',
        revision: 3,
      );
      final upsertsBefore = h.channel.upsertCalls;
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();

      expect(h.control.state, CalendarSyncControlState.paused);
      expect(h.channel.upsertCalls, upsertsBefore);
      expect((await h.ledger.reload()).batchesFor(_ownerA), hasLength(1));
    });

    test('教务登出 / 会话缺失：保持 enabled 等待、不写日历；同账号回来继续同步', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      await h.run();
      final upsertsBefore = h.channel.upsertCalls;
      final deletesBefore = h.channel.deleteCalls;
      expect(upsertsBefore, greaterThan(0));

      // 登出（身份缺失）。
      h.identity = const CalendarSyncIdentity(isLoggedIn: false, revision: 2);
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();
      await h.run();

      expect(h.control.state, CalendarSyncControlState.enabled);
      expect(h.control.isWaitingForIdentity, isTrue);
      expect(h.control.ownerKey, _ownerA);
      expect(h.channel.upsertCalls, upsertsBefore);
      expect(h.channel.deleteCalls, deletesBefore);
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.noWork);

      // 同学号重新登录：不暂停、继续同步（复用同一批映射，不重复新增）。
      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: _ownerA,
        revision: 3,
      );
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();

      expect(h.control.state, CalendarSyncControlState.enabled);
      expect(h.control.isWaitingForIdentity, isFalse);
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      expect((await h.ledger.reload()).allEntries, hasLength(20));
    });

    test('冷启动竞态：教务尚未 restoreSession 时 start 同步不暂停也不写', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      // 模拟新进程：控制态由磁盘恢复（enabled），正方身份尚为空。
      h.control.debugReset();
      h.identity = const CalendarSyncIdentity(isLoggedIn: false, revision: 0);
      await h.run();

      expect(h.control.state, CalendarSyncControlState.enabled);
      expect(h.control.isWaitingForIdentity, isTrue);
      expect(h.channel.upsertCalls, 0);
      expect(
        (await CalendarSyncControlStore.debugNew().read()).state,
        CalendarSyncControlState.enabled,
      );

      // restoreSession 完成：同学号，revision 推进 → 恢复同步。
      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: _ownerA,
        revision: 1,
      );
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();

      expect(h.control.state, CalendarSyncControlState.enabled);
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      expect(h.channel.upsertedDrafts, hasLength(20));
    });

    test('登出后换另一账号登录才暂停并落盘', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.identity = const CalendarSyncIdentity(isLoggedIn: false, revision: 2);
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();
      expect(h.control.state, CalendarSyncControlState.enabled);

      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: '20230002',
        revision: 3,
      );
      await h.coordinator.onAuthIdentityChanged();
      await h.coordinator.waitForIdle();

      expect(h.control.state, CalendarSyncControlState.paused);
      expect(h.channel.upsertCalls, 0);
      expect(
        (await CalendarSyncControlStore.debugNew().read()).state,
        CalendarSyncControlState.paused,
      );
    });
  });

  group('事务与崩溃恢复', () {
    test('新增事件先落盘 pending，upsert 失败保留 pending 且不删除', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      h.channel.onUpsert = (calendarId, events) async =>
          throw const CalendarSyncException(
            kind: CalendarSyncFailureKind.providerUnavailable,
            message: 'test',
          );

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.failed);
      final snapshot = await h.ledger.reload();
      expect(snapshot.pendingEntryCount, 20);
      expect(h.channel.deleteCalls, 0);
    });

    test('崩溃后按 provider 真实 query 恢复并复用 opaqueId', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      final occurrences = _defaultProjector(
        snapshot: h.snapshot!,
        verifiedOwner: _ownerA,
        confirmedCurrentTerm: _term2026,
        semesterStartDate: h.semesterStart,
        now: h.now,
        reminderMinutes: ProjectedCourseOccurrence.defaultReminderMinutes,
      );
      expect(occurrences, hasLength(20));

      // 模拟崩溃：provider 已写入但 eventId 未登记（pending 先落盘）。
      final plans = <CalendarSyncEventPlan>[];
      for (var i = 0; i < occurrences.length; i++) {
        final opaqueId = _opaqueId(i + 1);
        plans.add(occurrences[i].toEventPlan(opaqueId: opaqueId));
        h.channel.ownedByOpaqueId[opaqueId] = 5000 + i;
      }
      await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: plans,
        generation: 'crash-gen',
      );

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      final snapshot = await h.ledger.reload();
      expect(snapshot.batchesFor(_ownerA), hasLength(1));
      expect(snapshot.pendingEntryCount, 0);
      expect(snapshot.allEntries, hasLength(20));
      // 复用恢复出的 opaqueId，不新建批次。
      expect(
        h.channel.upsertedDrafts.map((draft) => draft.opaqueId).toSet(),
        <String>{for (var i = 0; i < 20; i++) _opaqueId(i + 1)},
      );
    });
  });

  group('差量删除边界', () {
    test('只删当前学期陈旧项，历史学期保留', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);

      const historicalTerm = ScheduleTermContext(academicYear: 2025, term: 3);
      final historicalId = _opaqueId(901);
      final staleId = _opaqueId(902);
      final historicalBatch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: historicalId,
            businessKey: _manualBusinessKey(historicalTerm, '历史课'),
          ),
        ],
        generation: 'historical',
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: historicalBatch.generation,
        eventIds: <String, int>{historicalId: 9001},
      );
      final staleBatch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: staleId,
            businessKey: _manualBusinessKey(_term2026, '旧课'),
          ),
        ],
        generation: 'stale',
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: staleBatch.generation,
        eventIds: <String, int>{staleId: 9002},
      );
      h.channel.ownedByOpaqueId[historicalId] = 9001;
      h.channel.ownedByOpaqueId[staleId] = 9002;

      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      await h.run();

      final deletedEventIds = h.channel.deletedEvents
          .map((event) => event.eventId)
          .toSet();
      expect(deletedEventIds, contains(9002));
      expect(deletedEventIds, isNot(contains(9001)));

      final snapshot = await h.ledger.reload();
      final remaining = snapshot.allEntries
          .map((entry) => entry.eventId)
          .toSet();
      expect(remaining, contains(9001));
      expect(remaining, isNot(contains(9002)));
    });

    test('重复映射只保留最新一条，历史学期重复保留', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      final occurrences = _defaultProjector(
        snapshot: h.snapshot!,
        verifiedOwner: _ownerA,
        confirmedCurrentTerm: _term2026,
        semesterStartDate: h.semesterStart,
        now: h.now,
        reminderMinutes: ProjectedCourseOccurrence.defaultReminderMinutes,
      );
      final desiredKey = occurrences.first.businessKey;

      final duplicateOldId = _opaqueId(911);
      final duplicateNewId = _opaqueId(912);
      final oldBatch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: duplicateOldId,
            businessKey: desiredKey,
          ),
        ],
        generation: 'dup-old',
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: oldBatch.generation,
        eventIds: <String, int>{duplicateOldId: 9101},
      );
      final newBatch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: duplicateNewId,
            businessKey: desiredKey,
          ),
        ],
        generation: 'dup-new',
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: newBatch.generation,
        eventIds: <String, int>{duplicateNewId: 9102},
      );
      h.channel.ownedByOpaqueId[duplicateOldId] = 9101;
      h.channel.ownedByOpaqueId[duplicateNewId] = 9102;

      // 历史学期重复映射：一律保留。
      const historicalTerm = ScheduleTermContext(academicYear: 2025, term: 3);
      final historicalKey = _manualBusinessKey(historicalTerm, '历史课');
      final historicalOldId = _opaqueId(913);
      final historicalNewId = _opaqueId(914);
      for (final entry in <({String id, String generation, int eventId})>[
        (id: historicalOldId, generation: 'hist-old', eventId: 9103),
        (id: historicalNewId, generation: 'hist-new', eventId: 9104),
      ]) {
        final batch = await h.ledger.beginPendingBatch(
          ownerKey: _ownerA,
          calendarId: _calendarId,
          plans: <CalendarSyncEventPlan>[
            CalendarSyncEventPlan(
              opaqueId: entry.id,
              businessKey: historicalKey,
            ),
          ],
          generation: entry.generation,
        );
        await h.ledger.commitBatch(
          ownerKey: _ownerA,
          generation: batch.generation,
          eventIds: <String, int>{entry.id: entry.eventId},
        );
        h.channel.ownedByOpaqueId[entry.id] = entry.eventId;
      }

      await h.run();

      final deletedEventIds = h.channel.deletedEvents
          .map((event) => event.eventId)
          .toSet();
      expect(deletedEventIds, contains(9101));
      expect(deletedEventIds, isNot(contains(9102)));
      expect(deletedEventIds, isNot(contains(9103)));
      expect(deletedEventIds, isNot(contains(9104)));
      expect(
        h.channel.upsertedDrafts.map((draft) => draft.opaqueId),
        contains(duplicateNewId),
      );

      final remaining = (await h.ledger.reload()).allEntries
          .map((entry) => entry.eventId)
          .toSet();
      expect(remaining, contains(9102));
      expect(remaining, isNot(contains(9101)));
      expect(remaining, containsAll(<int>[9103, 9104]));
    });

    test('快照不可信时不执行删除', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      final staleId = _opaqueId(903);
      final batch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: staleId,
            businessKey: _manualBusinessKey(_term2026, '旧课'),
          ),
        ],
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: batch.generation,
        eventIds: <String, int>{staleId: 9003},
      );
      h.channel.ownedByOpaqueId[staleId] = 9003;

      h.term = _term2026;
      h.snapshot = null;
      await h.run();

      expect(h.channel.deleteCalls, 0);
      expect(
        (await h.ledger.reload()).allEntries.map((entry) => entry.eventId),
        contains(9003),
      );
    });

    test('投影抛错时不执行删除', () async {
      final h = _Harness(
        projector:
            ({
              required snapshot,
              required verifiedOwner,
              required confirmedCurrentTerm,
              required semesterStartDate,
              required now,
              required reminderMinutes,
            }) => throw const CalendarProjectionException(
              CalendarProjectionFailure.scheduleStale,
              'test',
            ),
      );
      await h.enable(_ownerA, _calendarId, revision: 1);
      final staleId = _opaqueId(904);
      final batch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: staleId,
            businessKey: _manualBusinessKey(_term2026, '旧课'),
          ),
        ],
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: batch.generation,
        eventIds: <String, int>{staleId: 9004},
      );
      h.channel.ownedByOpaqueId[staleId] = 9004;

      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      await h.run();

      expect(h.channel.deleteCalls, 0);
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.noWork);
    });

    test('写入失败时不执行删除', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      final staleId = _opaqueId(905);
      final batch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: staleId,
            businessKey: _manualBusinessKey(_term2026, '旧课'),
          ),
        ],
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: batch.generation,
        eventIds: <String, int>{staleId: 9005},
      );
      h.channel.ownedByOpaqueId[staleId] = 9005;
      h.channel.onUpsert = (calendarId, events) async =>
          throw const CalendarSyncException(
            kind: CalendarSyncFailureKind.batchFailed,
            message: 'test',
          );

      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      await h.run();

      expect(h.channel.deleteCalls, 0);
      expect(
        (await h.ledger.reload()).allEntries.map((entry) => entry.eventId),
        contains(9005),
      );
    });
  });

  group('幂等与并发', () {
    test('重复触发不生成重复事件', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      await h.run();
      await h.run();

      final snapshot = await h.ledger.reload();
      expect(snapshot.batchesFor(_ownerA), hasLength(1));
      expect(snapshot.allEntries, hasLength(20));
      expect(
        h.channel.upsertedDrafts.map((draft) => draft.opaqueId).toSet(),
        hasLength(20),
      );
    });

    test('单轮并发去重不产生重复事件', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      final gate = Completer<void>();
      h.channel.upsertGate = gate;
      h.coordinator.requestSync();
      await pumpEventQueue();
      // 第一轮在 upsert 处挂起时再次触发：应被合并为一次补跑。
      h.coordinator.requestSync();
      gate.complete();
      await h.coordinator.waitForIdle();

      final snapshot = await h.ledger.reload();
      expect(snapshot.batchesFor(_ownerA), hasLength(1));
      expect(snapshot.allEntries, hasLength(20));
    });
  });

  group('生命周期', () {
    test('inactive 不写，resumed 后恢复', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();

      h.coordinator.onAppInactive();
      h.coordinator.onCampusDataChanged();
      await h.coordinator.waitForIdle();
      expect(h.channel.upsertCalls, 0);
      expect(h.channel.deleteCalls, 0);

      h.coordinator.onAppResumed();
      await h.coordinator.waitForIdle();
      expect(h.channel.upsertCalls, 1);
      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
    });
  });

  group('数据安全整改', () {
    test('A 旧轮在切号并重绑 B 后阻断后续 provider 操作', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      final staleId = _opaqueId(921);
      final batch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: staleId,
            businessKey: _manualBusinessKey(_term2026, '旧课'),
          ),
        ],
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: batch.generation,
        eventIds: <String, int>{staleId: 9001},
      );
      h.channel.ownedByOpaqueId[staleId] = 9001;

      final gate = Completer<void>();
      h.channel.upsertGate = gate;
      h.coordinator.requestSync();
      await pumpEventQueue(); // 旧 A 轮卡在 upsert

      // 切号并对 B 显式 enable（重绑到 B cal8）；旧 A 轮必须立即失效。
      h.identity = const CalendarSyncIdentity(
        isLoggedIn: true,
        ownerKey: '20230002',
        revision: 3,
      );
      await h.control.enable(ownerKey: '20230002', calendarId: 8, revision: 3);
      await h.coordinator.onAuthIdentityChanged();
      await pumpEventQueue();

      gate.complete();
      await h.coordinator.waitForIdle();

      // 旧 A 轮不得继续删除 A 日历上的陈旧项。
      expect(h.channel.deleteCalls, 0);
      expect(
        (await h.ledger.reload()).allEntries.map((entry) => entry.eventId),
        contains(9001),
      );
    });

    test('commit 被拒绝时立即 fail closed 不删除', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      final staleId = _opaqueId(922);
      final staleBatch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          CalendarSyncEventPlan(
            opaqueId: staleId,
            businessKey: _manualBusinessKey(_term2026, '旧课'),
          ),
        ],
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: staleBatch.generation,
        eventIds: <String, int>{staleId: 9002},
      );
      h.channel.ownedByOpaqueId[staleId] = 9002;

      // 原生 upsert 期间并发产生更新批次，使本轮 commitBatch 变成 stale。
      h.channel.onUpsert = (calendarId, events) async {
        await h.ledger.beginPendingBatch(
          ownerKey: _ownerA,
          calendarId: _calendarId,
          plans: <CalendarSyncEventPlan>[
            CalendarSyncEventPlan(
              opaqueId: _opaqueId(923),
              businessKey: _manualBusinessKey(_term2026, '并发课'),
            ),
          ],
          generation: 'concurrent-newer',
        );
        return CalendarSyncBatchResult(
          insertedCount: events.length,
          updatedCount: 0,
          eventIds: <String, int>{
            for (var i = 0; i < events.length; i++)
              events[i].opaqueId: 6000 + i,
          },
        );
      };

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.failed);
      expect(h.channel.deleteCalls, 0);
      expect(
        (await h.ledger.reload()).allEntries.map((entry) => entry.eventId),
        contains(9002),
      );
    });

    test('eventId 重建后回写账本，关闭时按新 id 精准清理', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith(courses: const <CourseEntry>[_oneWeekCourse]);
      final occurrences = _defaultProjector(
        snapshot: h.snapshot!,
        verifiedOwner: _ownerA,
        confirmedCurrentTerm: _term2026,
        semesterStartDate: h.semesterStart,
        now: h.now,
        reminderMinutes: ProjectedCourseOccurrence.defaultReminderMinutes,
      );
      expect(occurrences, hasLength(1));
      final opaque = _opaqueId(924);
      final batch = await h.ledger.beginPendingBatch(
        ownerKey: _ownerA,
        calendarId: _calendarId,
        plans: <CalendarSyncEventPlan>[
          occurrences.single.toEventPlan(opaqueId: opaque),
        ],
        generation: 'rebind',
      );
      await h.ledger.commitBatch(
        ownerKey: _ownerA,
        generation: batch.generation,
        eventIds: <String, int>{opaque: 500},
      );
      h.channel.ownedByOpaqueId[opaque] = 500;

      // provider 返回重建后的新 id（旧事件被手删后又以同 opaqueId 新建）。
      h.channel.onUpsert = (calendarId, events) async =>
          CalendarSyncBatchResult(
            insertedCount: 0,
            updatedCount: events.length,
            eventIds: <String, int>{
              for (final event in events) event.opaqueId: 777,
            },
          );

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.synced);
      expect((await h.ledger.reload()).allEntries.single.eventId, 777);

      // 关闭清理：provider 当前是 777，必须按查回的新 id 删除。
      h.channel.ownedByOpaqueId[opaque] = 777;
      final cleanup = await h.control.disableAndCleanup();
      expect(cleanup.isComplete, isTrue);
      expect(h.channel.deletedEvents.single.eventId, 777);
      expect((await h.ledger.reload()).isEmpty, isTrue);
    });

    test('设备日志不含课程内容', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      const sentinel = '高等数学-机密内容';
      h.channel.onUpsert = (calendarId, events) async =>
          throw const CalendarSyncException(
            kind: CalendarSyncFailureKind.batchFailed,
            message: sentinel,
          );

      await h.run();

      final logged = AppLogger.instance.entries
          .map((entry) => entry.formatted)
          .join('\n');
      expect(AppLogger.instance.entries, isNotEmpty);
      expect(logged.contains(sentinel), isFalse);
    });
  });

  group('Issue #48 根因守卫与 drain', () {
    test('C1：当前日历有未记账自有事件时拒绝新建（fail closed）', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      // provider 已存在本 App 标记事件，但账本为空（旧版本 / 归属失落）。
      h.channel.ownedByOpaqueId[_opaqueId(999)] = 9999;

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.blocked);
      expect(h.channel.upsertCalls, 0);
      expect(h.channel.calls, isNot(contains('upsertEventBatch')));
    });

    test('C1：扫描不完整时拒绝新建（fail closed）', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      h.channel.scanComplete = false;

      await h.run();

      expect(h.coordinator.outcome.value, CalendarSyncRunOutcome.blocked);
      expect(h.channel.upsertCalls, 0);
    });

    test('stopAndDrainForCleanup 等待在途轮次结束', () async {
      final h = _Harness();
      await h.enable(_ownerA, _calendarId, revision: 1);
      h.term = _term2026;
      h.snapshot = h.snapshotWith();
      final gate = Completer<void>();
      h.channel.upsertGate = gate;

      h.coordinator.requestSync();
      await Future<void>.delayed(Duration.zero);
      expect(h.coordinator.debugActiveRun, isNotNull);

      var drained = false;
      final drain = h.coordinator.stopAndDrainForCleanup();
      unawaited(drain.then((_) => drained = true));
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);

      gate.complete();
      await drain;
      expect(drained, isTrue);
    });
  });
}
