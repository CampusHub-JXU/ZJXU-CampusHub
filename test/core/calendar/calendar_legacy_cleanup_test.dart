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
  final List<String> calls = <String>[];
  int deleteCalls = 0;
  int upsertCalls = 0;

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
    // 由当前内存 provider 派生「有 marker 的日历」，与真实原生语义一致。
    final derived = <CalendarOwnedCalendarInfo>[
      for (final entry in owned.entries)
        if (entry.value.isNotEmpty)
          CalendarOwnedCalendarInfo(calendarId: entry.key, writable: true),
    ];
    return CalendarOwnedCalendarDiscovery(
      calendars: <CalendarOwnedCalendarInfo>[...derived, ...calendars],
      complete: discoveryComplete,
      reason: discoveryComplete
          ? null
          : CalendarOwnedDiscoveryReason.unavailable,
    );
  }

  @override
  Future<CalendarOwnedEventScan> scanOwnedEvents({
    required int calendarId,
  }) async {
    calls.add('scanOwnedEvents');
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

  @override
  Future<CalendarSyncControlBinding> read() async => binding;

  @override
  Future<void> write(CalendarSyncControlBinding value) async => binding = value;

  @override
  Future<void> clear() async => binding = CalendarSyncControlBinding.off;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const opaqueA = '11111111-1111-4111-8111-111111111111';
  const opaqueB = '22222222-2222-4222-8222-222222222222';

  late _FakeChannel channel;
  late CalendarEventLedgerStore ledger;
  late CalendarSyncControl control;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    channel = _FakeChannel();
    ledger = CalendarEventLedgerStore.debugNew();
    control = CalendarSyncControl.debugNew(
      channel: channel,
      ledger: ledger,
      store: _FakeStateStore(),
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
}
