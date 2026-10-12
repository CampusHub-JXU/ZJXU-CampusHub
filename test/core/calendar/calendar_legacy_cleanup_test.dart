import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

/// 合成假通道：内存 provider + 只读发现门面，绝不触达真实系统日历。
class _FakeChannel implements CalendarSyncChannel, CalendarOwnedEventDiscovery {
  final Map<int, List<CalendarSyncOwnedEvent>> owned =
      <int, List<CalendarSyncOwnedEvent>>{};
  final List<CalendarOwnedCalendarInfo> calendars =
      <CalendarOwnedCalendarInfo>[];
  bool scanComplete = true;
  bool discoveryComplete = true;
  CalendarOwnedDiscoveryReason discoveryReason =
      CalendarOwnedDiscoveryReason.unavailable;
  final List<String> calls = <String>[];
  int deleteCalls = 0;
  int upsertCalls = 0;

  /// 非 null 时 discovery **原样**返回该列表（不按 [owned] 派生可写日历），
  /// 用于精确构造 `writable=false/null` 的元数据场景。
  List<CalendarOwnedCalendarInfo>? explicitCalendars;

  /// 每次 [scanOwnedEvents] 调用时同步触发（含删除前复核与删除后复扫），
  /// 供测试在特定轮次注入并发身份变更。
  void Function()? onScan;

  @override
  Future<bool> checkPermissions() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() async =>
      const CalendarSyncLocalCalendar(id: 42, displayName: '嘉兴大学课程');

  @override
  Future<List<CalendarSyncWritableCalendar>> listWritableCalendars() async =>
      const <CalendarSyncWritableCalendar>[];

  @override
  Future<List<CalendarSyncOwnedEvent>> queryOwnedEvents({
    required int calendarId,
    List<String>? opaqueIds,
  }) async {
    calls.add('queryOwnedEvents');
    final events = owned[calendarId] ?? const <CalendarSyncOwnedEvent>[];
    if (opaqueIds == null) return events;
    final wanted = opaqueIds.toSet();
    return <CalendarSyncOwnedEvent>[
      for (final event in events)
        if (wanted.contains(event.opaqueId)) event,
    ];
  }

  @override
  Future<CalendarSyncBatchResult> upsertEventBatch({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  }) async {
    calls.add('upsertEventBatch');
    upsertCalls++;
    throw StateError('清理测试不应触发 upsert');
  }

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) async {
    calls.add('deleteOwnedEventsByIds');
    deleteCalls++;
    final current = owned[calendarId] ?? <CalendarSyncOwnedEvent>[];
    final deleted = <int>[];
    final notDeleted = <int>[];
    for (final event in events) {
      final match = current.any(
        (candidate) =>
            candidate.opaqueId == event.opaqueId &&
            candidate.eventId == event.eventId,
      );
      if (match) {
        deleted.add(event.eventId);
        current.removeWhere(
          (candidate) =>
              candidate.opaqueId == event.opaqueId &&
              candidate.eventId == event.eventId,
        );
      } else {
        notDeleted.add(event.eventId);
      }
    }
    owned[calendarId] = current;
    return CalendarSyncDeleteResult(
      deletedIds: deleted,
      notDeletedIds: notDeleted,
    );
  }

  @override
  Future<CalendarOwnedCalendarDiscovery> listOwnedEventCalendars() async {
    calls.add('listOwnedEventCalendars');
    final explicit = explicitCalendars;
    if (explicit != null) {
      return CalendarOwnedCalendarDiscovery(
        calendars: List<CalendarOwnedCalendarInfo>.from(explicit),
        complete: discoveryComplete,
        reason: discoveryComplete ? null : discoveryReason,
      );
    }
    // 由当前内存 provider 派生「有 marker 的日历」，与真实原生语义一致。
    final derived = <CalendarOwnedCalendarInfo>[
      for (final entry in owned.entries)
        if (entry.value.isNotEmpty)
          CalendarOwnedCalendarInfo(calendarId: entry.key, writable: true),
    ];
    return CalendarOwnedCalendarDiscovery(
      calendars: <CalendarOwnedCalendarInfo>[...derived, ...calendars],
      complete: discoveryComplete,
      reason: discoveryComplete ? null : discoveryReason,
    );
  }

  @override
  Future<CalendarOwnedEventScan> scanOwnedEvents({
    required int calendarId,
  }) async {
    calls.add('scanOwnedEvents');
    onScan?.call();
    return CalendarOwnedEventScan(
      events: List<CalendarSyncOwnedEvent>.unmodifiable(
        owned[calendarId] ?? const <CalendarSyncOwnedEvent>[],
      ),
      complete: scanComplete,
      reason: scanComplete ? null : CalendarOwnedDiscoveryReason.unavailable,
    );
  }
}

class _FakeStateStore implements CalendarSyncStateStore {
  CalendarSyncControlBinding binding = CalendarSyncControlBinding.off;

  /// 非 null 时 [clear] 抛出该 typed 异常（用于验证 store 失败不假成功）。
  CalendarSyncException? clearError;
  int clearCalls = 0;

  @override
  Future<CalendarSyncControlBinding> read() async => binding;

  @override
  Future<void> write(CalendarSyncControlBinding value) async => binding = value;

  @override
  Future<void> clear() async {
    clearCalls++;
    final error = clearError;
    if (error != null) throw error;
    binding = CalendarSyncControlBinding.off;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const opaqueA = '11111111-1111-4111-8111-111111111111';
  const opaqueB = '22222222-2222-4222-8222-222222222222';

  late _FakeChannel channel;
  late _FakeStateStore store;
  late CalendarEventLedgerStore ledger;
  late CalendarSyncControl control;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    channel = _FakeChannel();
    store = _FakeStateStore();
    ledger = CalendarEventLedgerStore.debugNew();
    control = CalendarSyncControl.debugNew(
      channel: channel,
      ledger: ledger,
      store: store,
      discovery: channel,
    );
  });

  test('off + empty ledger scans as complete with no residual', () async {
    final scan = await control.scanLegacyOwnedEvents();

    expect(scan.complete, isTrue);
    expect(scan.reason, isNull);
    expect(scan.totalKnownOwnedCount, 0);
    expect(scan.calendars, isEmpty);
    expect(control.state, CalendarSyncControlState.cleanupPending);
  });

  test('scan reports certified own events even with an empty ledger', () async {
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
      const CalendarSyncOwnedEvent(opaqueId: opaqueB, eventId: 2),
    ];

    final scan = await control.scanLegacyOwnedEvents();

    expect(scan.complete, isTrue);
    expect(scan.totalKnownOwnedCount, 2);
    expect(scan.recordedOrphanCount, 2);
    final preview = scan.calendars.single;
    expect(preview.calendarId, 42);
    expect(preview.ownedCount, 2);
    expect(preview.orphanCount, 2);
    expect(preview.recordedCount, 0);
  });

  test('cleanup deletes only previewed tuples and returns complete', () async {
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
      const CalendarSyncOwnedEvent(opaqueId: opaqueB, eventId: 2),
    ];
    final scan = await control.scanLegacyOwnedEvents();

    final result = await control.cleanupLegacyOwnedEvents(scan);

    expect(result.complete, isTrue);
    expect(result.deletedCount, 2);
    expect(result.residualCount, 0);
    expect(result.failures, isEmpty);
    expect(control.state, CalendarSyncControlState.off);
  });

  test('duplicate opaque with different eventIds are all deleted', () async {
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 2),
    ];
    final scan = await control.scanLegacyOwnedEvents();
    expect(scan.totalKnownOwnedCount, 2);

    final result = await control.cleanupLegacyOwnedEvents(scan);

    expect(result.deletedCount, 2);
    expect(result.residualCount, 0);
    expect(result.complete, isTrue);
    // 同一 opaqueId 的两个 eventId 必须分两次调用（通道要求批次内 opaqueId 唯一）。
    expect(channel.deleteCalls, 2);
  });

  test('incomplete scan is never treated as clean', () async {
    channel.scanComplete = false;
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
    ];

    final scan = await control.scanLegacyOwnedEvents();

    expect(scan.complete, isFalse);
    expect(scan.reason, CalendarLegacyCleanupFailure.providerUnavailable);
  });

  test('cleanup refuses a stale preview without deleting', () async {
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
    ];
    final stale = await control.scanLegacyOwnedEvents();
    // 第二次扫描使旧预览失效。
    await control.scanLegacyOwnedEvents();

    final result = await control.cleanupLegacyOwnedEvents(stale);

    expect(result.complete, isFalse);
    expect(result.deletedCount, 0);
    expect(
      result.failures,
      contains(CalendarLegacyCleanupFailure.invalidPreview),
    );
    expect(channel.deleteCalls, 0);
  });

  test('drain hook blocks cleanup until it completes', () async {
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
    ];
    final gate = Completer<void>();
    final scan = await control.scanLegacyOwnedEvents();
    // 扫描完成后才安装 drain 钩子，验证清理会等待在途写入者。
    control.setBeforeCleanupDrain(() => gate.future);

    final pending = control.cleanupLegacyOwnedEvents(scan);
    await Future<void>.delayed(Duration.zero);
    // drain 未完成前绝不删除。
    expect(channel.deleteCalls, 0);

    gate.complete();
    final result = await pending;
    expect(result.deletedCount, 1);
    expect(channel.deleteCalls, 1);
  });

  test('dismiss with residual stays cleanupPending', () async {
    channel.owned[42] = <CalendarSyncOwnedEvent>[
      const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
    ];
    final scan = await control.scanLegacyOwnedEvents();

    await control.dismissLegacyCleanupPreview(scan);

    expect(control.state, CalendarSyncControlState.cleanupPending);
  });

  test('dismiss with no residual returns to off', () async {
    final scan = await control.scanLegacyOwnedEvents();
    expect(scan.dismissible, isTrue);

    await control.dismissLegacyCleanupPreview(scan);

    expect(control.state, CalendarSyncControlState.off);
  });

  test(
    'enable refuses a different calendar while old bindings exist (C2)',
    () async {
      // 旧日历 7 仍有账本归属。
      final batch = await ledger.beginPendingBatch(
        ownerKey: '20240001',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[
          const CalendarSyncEventPlan(opaqueId: opaqueA, businessKey: 'k'),
        ],
      );
      await ledger.commitBatch(
        ownerKey: '20240001',
        generation: batch.generation,
        eventIds: <String, int>{opaqueA: 1},
      );

      final result = await control.enable(ownerKey: '20240001', calendarId: 42);

      expect(result.enabled, isFalse);
      expect(result.blockedByCleanup, isTrue);
    },
  );

  group('Issue #48 CORE follow-up regressions', () {
    CalendarOwnedCalendarInfo cal(int id, bool? writable) =>
        CalendarOwnedCalendarInfo(calendarId: id, writable: writable);

    test('incomplete discovery (permissionDenied) + empty ledger + off: '
        'incomplete result, cleanupPending, enable blocked', () async {
      channel.discoveryComplete = false;
      channel.discoveryReason = CalendarOwnedDiscoveryReason.permissionDenied;
      channel.explicitCalendars = <CalendarOwnedCalendarInfo>[];

      final scan = await control.scanLegacyOwnedEvents();
      expect(scan.complete, isFalse);
      expect(scan.reason, CalendarLegacyCleanupFailure.permissionDenied);

      final result = await control.cleanupLegacyOwnedEvents(scan);
      expect(result.complete, isFalse);
      expect(
        result.failures,
        contains(CalendarLegacyCleanupFailure.permissionDenied),
      );
      expect(control.state, CalendarSyncControlState.cleanupPending);

      final enable = await control.enable(ownerKey: '20230001', calendarId: 42);
      expect(enable.enabled, isFalse);
      expect(enable.blockedByCleanup, isTrue);
    });

    test(
      'incomplete discovery (scanLimit): incomplete result + cleanupPending',
      () async {
        channel.discoveryComplete = false;
        channel.discoveryReason = CalendarOwnedDiscoveryReason.scanLimit;
        channel.explicitCalendars = <CalendarOwnedCalendarInfo>[];

        final scan = await control.scanLegacyOwnedEvents();
        final result = await control.cleanupLegacyOwnedEvents(scan);

        expect(result.complete, isFalse);
        expect(
          result.failures,
          contains(CalendarLegacyCleanupFailure.scanLimit),
        );
        expect(control.state, CalendarSyncControlState.cleanupPending);
      },
    );

    test(
      'incomplete discovery (calendarUnavailable) with a known-writable '
      'candidate: known portion deleted but result stays incomplete',
      () async {
        channel.discoveryComplete = false;
        channel.discoveryReason =
            CalendarOwnedDiscoveryReason.calendarUnavailable;
        channel.explicitCalendars = <CalendarOwnedCalendarInfo>[cal(42, true)];
        channel.owned[42] = <CalendarSyncOwnedEvent>[
          const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
        ];

        final scan = await control.scanLegacyOwnedEvents();
        expect(scan.complete, isFalse);

        final result = await control.cleanupLegacyOwnedEvents(scan);
        expect(result.deletedCount, 1);
        expect(result.complete, isFalse);
        expect(
          result.failures,
          contains(CalendarLegacyCleanupFailure.calendarUnavailable),
        );
        expect(control.state, CalendarSyncControlState.cleanupPending);
      },
    );

    test(
      'unknown writability (null) candidate: no delete, residual truthful',
      () async {
        channel.explicitCalendars = <CalendarOwnedCalendarInfo>[cal(42, null)];
        channel.owned[42] = <CalendarSyncOwnedEvent>[
          const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
        ];

        final scan = await control.scanLegacyOwnedEvents();
        expect(scan.calendars.single.writable, isNull);

        final result = await control.cleanupLegacyOwnedEvents(scan);
        expect(channel.deleteCalls, 0);
        expect(result.deletedCount, 0);
        expect(result.residualCount, 1);
        expect(result.complete, isFalse);
        expect(
          result.failures,
          contains(CalendarLegacyCleanupFailure.calendarUnavailable),
        );
        expect(control.state, CalendarSyncControlState.cleanupPending);
      },
    );

    test(
      'read-only (writable=false) candidate: no delete, incomplete',
      () async {
        channel.explicitCalendars = <CalendarOwnedCalendarInfo>[cal(42, false)];
        channel.owned[42] = <CalendarSyncOwnedEvent>[
          const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
        ];

        final scan = await control.scanLegacyOwnedEvents();
        final result = await control.cleanupLegacyOwnedEvents(scan);

        expect(channel.deleteCalls, 0);
        expect(result.complete, isFalse);
        expect(result.residualCount, greaterThanOrEqualTo(1));
        expect(control.state, CalendarSyncControlState.cleanupPending);
      },
    );

    test(
      'mixed writable + unknown calendars: only the safe portion is deleted',
      () async {
        channel.explicitCalendars = <CalendarOwnedCalendarInfo>[
          cal(42, true),
          cal(43, null),
        ];
        channel.owned[42] = <CalendarSyncOwnedEvent>[
          const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
        ];
        channel.owned[43] = <CalendarSyncOwnedEvent>[
          const CalendarSyncOwnedEvent(opaqueId: opaqueB, eventId: 2),
        ];

        final scan = await control.scanLegacyOwnedEvents();
        final result = await control.cleanupLegacyOwnedEvents(scan);

        expect(result.deletedCount, 1);
        expect(result.residualCount, 1);
        expect(result.complete, isFalse);
        expect(
          result.failures,
          contains(CalendarLegacyCleanupFailure.calendarUnavailable),
        );
        expect(control.state, CalendarSyncControlState.cleanupPending);
        expect(channel.owned[42], isEmpty);
        expect(channel.owned[43], hasLength(1));
      },
    );

    test('complete empty scope can return to off', () async {
      channel.explicitCalendars = <CalendarOwnedCalendarInfo>[];

      final scan = await control.scanLegacyOwnedEvents();
      expect(scan.complete, isTrue);

      final result = await control.cleanupLegacyOwnedEvents(scan);
      expect(result.complete, isTrue);
      expect(result.deletedCount, 0);
      expect(result.residualCount, 0);
      expect(result.failures, isEmpty);
      expect(control.state, CalendarSyncControlState.off);
    });

    test(
      'store.clear failure: complete=false + typed failure + cleanupPending, '
      'retry after recovery succeeds',
      () async {
        channel.explicitCalendars = <CalendarOwnedCalendarInfo>[cal(42, true)];
        channel.owned[42] = <CalendarSyncOwnedEvent>[
          const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
        ];
        final scan = await control.scanLegacyOwnedEvents();
        store.clearError = CalendarSyncException.ledgerUnavailable('注入清除失败');

        final result = await control.cleanupLegacyOwnedEvents(scan);

        expect(result.deletedCount, 1);
        expect(result.complete, isFalse);
        expect(
          result.failures,
          contains(CalendarLegacyCleanupFailure.ledgerUnavailable),
        );
        expect(control.state, CalendarSyncControlState.cleanupPending);

        // 恢复后重试同一预览：原子提交成功才回到 off。
        store.clearError = null;
        final retry = await control.cleanupLegacyOwnedEvents(scan);
        expect(retry.complete, isTrue);
        expect(control.state, CalendarSyncControlState.off);
      },
    );

    test('stale finalization: generation change before commit => '
        'complete=false + aborted, cleanupPending retains preview', () async {
      channel.explicitCalendars = <CalendarOwnedCalendarInfo>[cal(42, true)];
      channel.owned[42] = <CalendarSyncOwnedEvent>[
        const CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 1),
      ];
      final scan = await control.scanLegacyOwnedEvents();

      // 预览扫描在安装钩子之前完成，故清理内计数：1 = 删除前复核、2 = 删除后
      // 复扫。在最后一次复扫时排队一次身份变更，使 generation 落在
      // 「复扫完成 → 原子提交」窗口内。
      var scans = 0;
      channel.onScan = () {
        scans++;
        if (scans == 2) {
          scheduleMicrotask(() {
            unawaited(
              control.pauseIfOwnerMismatch(
                ownerKey: 'someone-else',
                revision: 9,
              ),
            );
          });
        }
      };

      final result = await control.cleanupLegacyOwnedEvents(scan);

      expect(result.complete, isFalse);
      expect(result.aborted, isTrue);
      expect(control.state, CalendarSyncControlState.cleanupPending);
    });
  });
}
