import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

/// 纯内存假通道：绝不触达真实系统日历，记录调用并允许逐方法注入行为。
class _FakeChannel implements CalendarSyncChannel {
  bool permissions = true;

  /// 申请权限时是否授予（模拟用户点“允许”）。
  bool grantOnRequest = true;
  int requestCalls = 0;
  int createCalendarCalls = 0;
  final List<String> calls = <String>[];

  CalendarSyncLocalCalendar localCalendar = const CalendarSyncLocalCalendar(
    id: 42,
    displayName: '嘉兴大学课程',
  );

  /// 置上后 [createOrGetLocalCalendar] 会等待该 Completer，用于确定性并发测试。
  Completer<void>? createCalendarGate;

  Future<List<CalendarSyncOwnedEvent>> Function({
    required int calendarId,
    List<String>? opaqueIds,
  })?
  onQuery;

  Future<CalendarSyncDeleteResult> Function({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  })?
  onDelete;

  Future<CalendarSyncBatchResult> Function({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  })?
  onUpsert;

  @override
  Future<bool> checkPermissions() async {
    calls.add('checkPermissions');
    return permissions;
  }

  @override
  Future<bool> requestPermissions() async {
    calls.add('requestPermissions');
    requestCalls++;
    if (grantOnRequest) permissions = true;
    return permissions;
  }

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() async {
    calls.add('createOrGetLocalCalendar');
    createCalendarCalls++;
    final gate = createCalendarGate;
    if (gate != null) {
      createCalendarGate = null;
      await gate.future;
    }
    return localCalendar;
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
  }) {
    calls.add('queryOwnedEvents');
    final handler = onQuery;
    if (handler == null) {
      return Future<List<CalendarSyncOwnedEvent>>.value(
        const <CalendarSyncOwnedEvent>[],
      );
    }
    return handler(calendarId: calendarId, opaqueIds: opaqueIds);
  }

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) {
    calls.add('deleteOwnedEventsByIds');
    final handler = onDelete;
    if (handler == null) {
      return Future<CalendarSyncDeleteResult>.value(
        CalendarSyncDeleteResult(
          deletedIds: <int>[for (final event in events) event.eventId],
          notDeletedIds: const <int>[],
        ),
      );
    }
    return handler(calendarId: calendarId, events: events);
  }

  @override
  Future<CalendarSyncBatchResult> upsertEventBatch({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  }) {
    calls.add('upsertEventBatch');
    final handler = onUpsert;
    if (handler == null) {
      return Future<CalendarSyncBatchResult>.error(
        StateError('测试未注入 upsertEventBatch 行为'),
      );
    }
    return handler(calendarId: calendarId, events: events);
  }
}

/// 可控内存 store：记录 write/clear 顺序，支持用 Completer 阻塞写盘，
/// 用于确定性验证 enable/disable/pause 的串行化。
class _FakeStateStore implements CalendarSyncStateStore {
  CalendarSyncControlBinding binding = CalendarSyncControlBinding.off;
  final List<String> ops = <String>[];
  Completer<void>? writeGate;
  Completer<void>? clearGate;

  @override
  Future<CalendarSyncControlBinding> read() async => binding;

  @override
  Future<void> write(CalendarSyncControlBinding value) async {
    final gate = writeGate;
    if (gate != null) {
      writeGate = null;
      await gate.future;
    }
    binding = value;
    ops.add('write:${value.state.name}');
  }

  @override
  Future<void> clear() async {
    final gate = clearGate;
    if (gate != null) {
      clearGate = null;
      await gate.future;
    }
    binding = CalendarSyncControlBinding.off;
    ops.add('clear');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  String opaqueId(int index) =>
      '${index.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000';

  CalendarSyncEventPlan plan(int index) => CalendarSyncEventPlan(
    opaqueId: opaqueId(index),
    businessKey: 'course-$index',
  );

  CalendarSyncOwnedEvent owned(int index, int eventId) =>
      CalendarSyncOwnedEvent(opaqueId: opaqueId(index), eventId: eventId);

  CalendarSyncException failure(CalendarSyncFailureKind kind) =>
      CalendarSyncException(kind: kind, message: 'test');

  ({
    CalendarSyncControl control,
    _FakeChannel channel,
    CalendarEventLedgerStore ledger,
    CalendarSyncStateStore store,
  })
  build({
    _FakeChannel? channel,
    CalendarEventLedgerStore? ledger,
    CalendarSyncStateStore? store,
  }) {
    final resolvedChannel = channel ?? _FakeChannel();
    final resolvedLedger = ledger ?? CalendarEventLedgerStore.debugNew();
    final resolvedStore = store ?? CalendarSyncControlStore.debugNew();
    final control = CalendarSyncControl.debugNew(
      channel: resolvedChannel,
      ledger: resolvedLedger,
      store: resolvedStore,
    );
    return (
      control: control,
      channel: resolvedChannel,
      ledger: resolvedLedger,
      store: resolvedStore,
    );
  }

  group('default off', () {
    test('starts off, is not writable and performs zero IPC', () async {
      final env = build();
      await env.control.load();

      expect(env.control.state, CalendarSyncControlState.off);
      expect(env.control.isWritable, isFalse);
      expect(env.control.ownerKey, isNull);
      expect(env.control.calendarId, isNull);
      expect(env.channel.calls, isEmpty);
    });

    test(
      'enable rejects empty owner and bad calendar without IPC write',
      () async {
        final env = build();
        await env.control.load();

        final emptyOwner = await env.control.enable(ownerKey: '   ');
        expect(emptyOwner.enabled, isFalse);
        expect(
          emptyOwner.failure?.kind,
          CalendarSyncFailureKind.invalidArgument,
        );
        expect(env.control.state, CalendarSyncControlState.off);
        expect(env.channel.calls, isEmpty);

        final badCalendar = await env.control.enable(
          ownerKey: '20230001',
          calendarId: 0,
        );
        expect(badCalendar.enabled, isFalse);
        expect(
          badCalendar.failure?.kind,
          CalendarSyncFailureKind.invalidArgument,
        );
        expect(env.channel.calls, isEmpty);
      },
    );
  });

  group('enable', () {
    test(
      'requests permission, resolves local calendar and persists binding',
      () async {
        final env = build();
        env.channel.permissions = false;

        final result = await env.control.enable(ownerKey: '20230001');

        expect(result.enabled, isTrue);
        expect(result.calendarId, 42);
        expect(env.control.state, CalendarSyncControlState.enabled);
        expect(env.control.ownerKey, '20230001');
        expect(env.control.isWritable, isTrue);
        expect(env.channel.requestCalls, 1);
        expect(env.channel.createCalendarCalls, 1);

        // 新实例读盘恢复绑定（不触发权限/ provider）。
        final restored = CalendarSyncControl.debugNew(
          channel: _FakeChannel(),
          ledger: CalendarEventLedgerStore.debugNew(),
          store: CalendarSyncControlStore.debugNew(),
        );
        await restored.load();
        expect(restored.state, CalendarSyncControlState.enabled);
        expect(restored.ownerKey, '20230001');
        expect(restored.calendarId, 42);
      },
    );

    test(
      'honours a user-selected calendar id without creating local calendar',
      () async {
        final env = build();

        final result = await env.control.enable(
          ownerKey: '20230001',
          calendarId: 7,
        );

        expect(result.enabled, isTrue);
        expect(result.calendarId, 7);
        expect(env.channel.createCalendarCalls, 0);
      },
    );

    test(
      'fails closed on permission denial and keeps state unchanged',
      () async {
        final env = build();
        env.channel.permissions = false;
        env.channel.grantOnRequest = false;

        final result = await env.control.enable(ownerKey: '20230001');

        expect(result.enabled, isFalse);
        expect(result.failure?.kind, CalendarSyncFailureKind.permissionDenied);
        expect(env.control.state, CalendarSyncControlState.off);
        expect(env.channel.requestCalls, 1);
      },
    );
  });

  group('pauseIfOwnerMismatch', () {
    test('A -> B pauses and keeps every A ledger entry', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      final batch = await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await env.ledger.commitBatch(
        ownerKey: 'A',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );

      final state = await env.control.pauseIfOwnerMismatch(
        ownerKey: 'B',
        revision: 5,
      );

      expect(state, CalendarSyncControlState.paused);
      expect(env.control.isWritable, isFalse);
      expect(env.control.ownerKey, 'A');
      final snapshot = await env.ledger.reload();
      expect(snapshot.owners.keys, contains('A'));
      expect(
        snapshot.batchesFor('A').single.entries[opaqueId(1)]?.eventId,
        101,
      );
    });

    test('logout (null owner) pauses but retains the ledger', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );

      final state = await env.control.pauseIfOwnerMismatch(
        ownerKey: null,
        revision: 6,
      );

      expect(state, CalendarSyncControlState.paused);
      expect((await env.ledger.reload()).owners.keys, contains('A'));
    });

    test('same owner re-login resumes and never deletes the ledger', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await env.control.pauseIfOwnerMismatch(ownerKey: null, revision: 6);

      final state = await env.control.pauseIfOwnerMismatch(
        ownerKey: 'A',
        revision: 7,
      );

      expect(state, CalendarSyncControlState.enabled);
      expect(env.control.ownerKey, 'A');
      expect((await env.ledger.reload()).owners.keys, contains('A'));
    });

    test('cleanupPending is not auto-resumed', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      final batch = await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await env.ledger.commitBatch(
        ownerKey: 'A',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );
      env.channel.onDelete = ({required calendarId, required events}) async =>
          const CalendarSyncDeleteResult(
            deletedIds: <int>[],
            notDeletedIds: <int>[101],
          );
      await env.control.disableAndCleanup();

      final state = await env.control.pauseIfOwnerMismatch(
        ownerKey: 'A',
        revision: 9,
      );
      expect(state, CalendarSyncControlState.cleanupPending);
    });
  });

  group('reconcilePending', () {
    test(
      'recovers an old-generation pending entry without promoting it',
      () async {
        final env = build();
        final old = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
          generation: 'gen-old',
        );
        final newer = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(2)],
          generation: 'gen-new',
        );
        await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: newer.generation,
          eventIds: <String, int>{opaqueId(2): 202},
        );

        env.channel.onQuery = ({required calendarId, opaqueIds}) async {
          if (opaqueIds!.contains(opaqueId(1))) {
            return <CalendarSyncOwnedEvent>[owned(1, 501)];
          }
          return const <CalendarSyncOwnedEvent>[];
        };

        final result = await env.control.reconcilePending();

        expect(result.reconciledCount, 1);
        expect(result.pendingRemaining, 0);
        expect(result.aborted, isFalse);

        final snapshot = await env.ledger.reload();
        final recovered = snapshot
            .batchesFor('A')
            .firstWhere((batch) => batch.generation == 'gen-old');
        expect(recovered.entries[opaqueId(1)]?.eventId, 501);

        // 恢复不会晋升 active：旧 generation 的迟到提交仍被拒绝。
        final late = await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: 'gen-old',
          eventIds: <String, int>{opaqueId(1): 501},
        );
        expect(late.status, CalendarEventLedgerCommitStatus.staleGeneration);
        expect(snapshot.batchesFor('A').last.generation, 'gen-new');
        expect(old.generation, 'gen-old');
      },
    );

    test('recovers a pending batch after a simulated restart', () async {
      final first = build();
      await first.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
        generation: 'gen-crash',
      );

      // 模拟进程重启：全新 ledger / control 实例，只从磁盘恢复。
      final restarted = build();
      restarted.channel.onQuery = ({required calendarId, opaqueIds}) async =>
          <CalendarSyncOwnedEvent>[owned(1, 777)];

      final result = await restarted.control.reconcilePending();

      expect(result.reconciledCount, 1);
      expect(result.pendingRemaining, 0);
      expect(
        (await restarted.ledger.reload())
            .batchesFor('A')
            .single
            .entries[opaqueId(1)]
            ?.eventId,
        777,
      );
    });

    test(
      'keeps pending and reports failure when the provider denies',
      () async {
        final env = build();
        await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );
        env.channel.onQuery = ({required calendarId, opaqueIds}) async =>
            throw failure(CalendarSyncFailureKind.permissionDenied);

        final result = await env.control.reconcilePending();

        expect(result.failureKind, CalendarSyncFailureKind.permissionDenied);
        expect(result.pendingRemaining, 1);
        final snapshot = await env.ledger.reload();
        expect(
          snapshot.batchesFor('A').single.entries[opaqueId(1)]?.isPending,
          isTrue,
        );
      },
    );

    test(
      'rejects in-flight results after a same-owner revision change',
      () async {
        final env = build();
        await env.control.enable(ownerKey: 'A', calendarId: 7, revision: 1);
        await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );

        final completer = Completer<List<CalendarSyncOwnedEvent>>();
        env.channel.onQuery = ({required calendarId, opaqueIds}) =>
            completer.future;

        final future = env.control.reconcilePending();
        await pumpEventQueue();

        // 同账号重登：不暂停，但推进 revision/generation。
        final state = await env.control.pauseIfOwnerMismatch(
          ownerKey: 'A',
          revision: 2,
        );
        expect(state, CalendarSyncControlState.enabled);

        completer.complete(<CalendarSyncOwnedEvent>[owned(1, 999)]);
        final result = await future;

        expect(result.aborted, isTrue);
        expect(result.reconciledCount, 0);
        final snapshot = await env.ledger.reload();
        expect(
          snapshot.batchesFor('A').single.entries[opaqueId(1)]?.isPending,
          isTrue,
        );
      },
    );
  });

  group('disableAndCleanup', () {
    test(
      'deletes only owned committed entries and clears binding when empty',
      () async {
        final env = build();
        await env.control.enable(ownerKey: 'A', calendarId: 7);
        final batch = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1), plan(2)],
        );
        await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101, opaqueId(2): 102},
        );

        final result = await env.control.disableAndCleanup();

        expect(result.isComplete, isTrue);
        expect(result.deletedCount, 2);
        expect(result.residualCount, 0);
        expect(env.control.state, CalendarSyncControlState.off);
        expect((await env.ledger.reload()).isEmpty, isTrue);

        // 重复调用安全：不再发起新的删除 IPC。
        final deletesBefore = env.channel.calls
            .where((call) => call == 'deleteOwnedEventsByIds')
            .length;
        final second = await env.control.disableAndCleanup();
        expect(second.isComplete, isTrue);
        expect(
          env.channel.calls
              .where((call) => call == 'deleteOwnedEventsByIds')
              .length,
          deletesBefore,
        );
      },
    );

    test(
      'partial deletion keeps the residual ledger and reports reasons',
      () async {
        final env = build();
        await env.control.enable(ownerKey: 'A', calendarId: 7);
        final batch = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1), plan(2), plan(3)],
        );
        await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: batch.generation,
          eventIds: <String, int>{
            opaqueId(1): 101,
            opaqueId(2): 102,
            opaqueId(3): 103,
          },
        );
        env.channel.onDelete = ({required calendarId, required events}) async =>
            const CalendarSyncDeleteResult(
              deletedIds: <int>[101],
              notDeletedIds: <int>[102, 103],
            );

        final result = await env.control.disableAndCleanup();

        expect(result.isComplete, isFalse);
        expect(result.deletedCount, 1);
        expect(result.residualCount, 2);
        expect(
          result.residualReasons,
          contains(CalendarSyncCleanupResidualReason.notDeleted),
        );
        expect(env.control.state, CalendarSyncControlState.cleanupPending);

        final snapshot = await env.ledger.reload();
        expect(snapshot.batchesFor('A').single.entries.keys.toSet(), <String>{
          opaqueId(2),
          opaqueId(3),
        });
      },
    );

    test('permission denial keeps every entry and reports residual', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      final batch = await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await env.ledger.commitBatch(
        ownerKey: 'A',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );
      env.channel.onDelete = ({required calendarId, required events}) async =>
          throw failure(CalendarSyncFailureKind.permissionDenied);

      final result = await env.control.disableAndCleanup();

      expect(result.failureKind, CalendarSyncFailureKind.permissionDenied);
      expect(result.residualCount, 1);
      expect(
        result.residualReasons,
        contains(CalendarSyncCleanupResidualReason.permissionDenied),
      );
      expect(env.control.state, CalendarSyncControlState.cleanupPending);
      expect(
        (await env.ledger.reload())
            .batchesFor('A')
            .single
            .entries[opaqueId(1)]
            ?.eventId,
        101,
      );
    });

    test('cleans every owner including the previous account', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      final batchA = await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await env.ledger.commitBatch(
        ownerKey: 'A',
        generation: batchA.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );

      // 换号后 B 显式开启，A 的账本保留。
      await env.control.pauseIfOwnerMismatch(ownerKey: 'B', revision: 2);
      await env.control.enable(ownerKey: 'B', calendarId: 8);
      final batchB = await env.ledger.beginPendingBatch(
        ownerKey: 'B',
        calendarId: 8,
        plans: <CalendarSyncEventPlan>[plan(2)],
      );
      await env.ledger.commitBatch(
        ownerKey: 'B',
        generation: batchB.generation,
        eventIds: <String, int>{opaqueId(2): 202},
      );

      final result = await env.control.disableAndCleanup();

      expect(result.deletedCount, 2);
      expect(result.residualCount, 0);
      expect((await env.ledger.reload()).isEmpty, isTrue);
    });
  });

  group('linearizable state transitions', () {
    test(
      'enable is rejected while cleanupPending and keeps the residual ledger',
      () async {
        final env = build();
        await env.control.enable(ownerKey: 'A', calendarId: 7);
        final batch = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );
        await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        );
        env.channel.onDelete = ({required calendarId, required events}) async =>
            const CalendarSyncDeleteResult(
              deletedIds: <int>[],
              notDeletedIds: <int>[101],
            );
        final cleanup = await env.control.disableAndCleanup();
        expect(cleanup.isComplete, isFalse);
        expect(env.control.state, CalendarSyncControlState.cleanupPending);

        // 账本残留未清完前，enable 一律拒绝且不得覆盖绑定。
        final retry = await env.control.enable(ownerKey: 'A', calendarId: 7);
        expect(retry.enabled, isFalse);
        expect(retry.blockedByCleanup, isTrue);
        expect(env.control.state, CalendarSyncControlState.cleanupPending);
        expect(env.control.ownerKey, 'A');
        expect(env.control.calendarId, 7);
        expect(
          (await env.ledger.reload())
              .batchesFor('A')
              .single
              .entries[opaqueId(1)]
              ?.eventId,
          101,
        );
      },
    );

    test(
      'an enable in flight cannot resurrect the binding after cleanup',
      () async {
        final store = _FakeStateStore();
        final channel = _FakeChannel();
        final env = build(channel: channel, store: store);
        final batch = await env.ledger.beginPendingBatch(
          ownerKey: 'X',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );
        await env.ledger.commitBatch(
          ownerKey: 'X',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        );

        // enable 卡在本地日历解析；期间 disable 完整跑完。
        final gate = Completer<void>();
        channel.createCalendarGate = gate;
        final enableFuture = env.control.enable(ownerKey: 'A');
        await pumpEventQueue();

        final cleanup = await env.control.disableAndCleanup();
        expect(cleanup.isComplete, isTrue);
        expect(env.control.state, CalendarSyncControlState.off);

        gate.complete();
        final enable = await enableFuture;

        // 迟到的 enable 被 generation 守卫拒绝，不会写回 enabled 绑定。
        expect(enable.enabled, isFalse);
        expect(env.control.state, CalendarSyncControlState.off);
        expect(store.binding.state, CalendarSyncControlState.off);
        final clearIndex = store.ops.lastIndexOf('clear');
        expect(clearIndex, isNonNegative);
        expect(
          store.ops.skip(clearIndex + 1).where((op) => op == 'write:enabled'),
          isEmpty,
        );
      },
    );

    test(
      'enable queued behind a started disable cannot overwrite cleanupPending',
      () async {
        final store = _FakeStateStore();
        final env = build(store: store);
        await env.control.enable(ownerKey: 'A', calendarId: 7);
        final batch = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );
        await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        );
        env.channel.onDelete = ({required calendarId, required events}) async =>
            const CalendarSyncDeleteResult(
              deletedIds: <int>[],
              notDeletedIds: <int>[101],
            );

        // 阻断 disable 的阻断阶段写盘：此时控制锁被持有，enable 只能排队。
        final gate = Completer<void>();
        store.writeGate = gate;
        final disableFuture = env.control.disableAndCleanup();
        await pumpEventQueue();
        final enableFuture = env.control.enable(ownerKey: 'B', calendarId: 8);
        await pumpEventQueue();

        gate.complete();
        final disable = await disableFuture;
        final enable = await enableFuture;

        expect(disable.residualCount, 1);
        expect(enable.enabled, isFalse);
        expect(enable.blockedByCleanup, isTrue);
        // 绑定保持 cleanupPending / owner A，未被 B 覆盖。
        expect(env.control.state, CalendarSyncControlState.cleanupPending);
        expect(env.control.ownerKey, 'A');
        expect(store.binding.state, CalendarSyncControlState.cleanupPending);
        expect(store.binding.ownerKey, 'A');
        expect(
          (await env.ledger.reload()).batchesFor('A').single.entries.length,
          1,
        );
      },
    );

    test('pause racing an enable commit is serialized', () async {
      final store = _FakeStateStore();
      final env = build(store: store);

      final gate = Completer<void>();
      store.writeGate = gate;
      final enableFuture = env.control.enable(ownerKey: 'A', calendarId: 7);
      await pumpEventQueue();
      final pauseFuture = env.control.pauseIfOwnerMismatch(
        ownerKey: 'B',
        revision: 5,
      );
      await pumpEventQueue();

      gate.complete();
      final enable = await enableFuture;
      final state = await pauseFuture;

      expect(enable.enabled, isTrue);
      expect(state, CalendarSyncControlState.paused);
      expect(env.control.ownerKey, 'A');
      expect(store.binding.state, CalendarSyncControlState.paused);
      expect(store.binding.ownerKey, 'A');
    });

    test('after a complete cleanup a fresh enable is allowed', () async {
      final env = build();
      await env.control.enable(ownerKey: 'A', calendarId: 7);
      final batch = await env.ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await env.ledger.commitBatch(
        ownerKey: 'A',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );

      final cleanup = await env.control.disableAndCleanup();
      expect(cleanup.isComplete, isTrue);
      expect(env.control.state, CalendarSyncControlState.off);

      final re = await env.control.enable(ownerKey: 'B', calendarId: 8);
      expect(re.enabled, isTrue);
      expect(re.blockedByCleanup, isFalse);
      expect(env.control.ownerKey, 'B');
      expect(env.control.calendarId, 8);
    });

    test(
      'persisted binding reloads consistently after pause and partial cleanup',
      () async {
        final env = build();
        await env.control.enable(ownerKey: 'A', calendarId: 7);
        await env.control.pauseIfOwnerMismatch(ownerKey: 'B', revision: 2);

        CalendarSyncControl fresh() => CalendarSyncControl.debugNew(
          channel: _FakeChannel(),
          ledger: CalendarEventLedgerStore.debugNew(),
          store: CalendarSyncControlStore.debugNew(),
        );

        var reloaded = fresh();
        await reloaded.load();
        expect(reloaded.state, env.control.state);
        expect(reloaded.state, CalendarSyncControlState.paused);
        expect(reloaded.ownerKey, 'A');
        expect(reloaded.calendarId, 7);

        final batch = await env.ledger.beginPendingBatch(
          ownerKey: 'A',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );
        await env.ledger.commitBatch(
          ownerKey: 'A',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        );
        env.channel.onDelete = ({required calendarId, required events}) async =>
            const CalendarSyncDeleteResult(
              deletedIds: <int>[],
              notDeletedIds: <int>[101],
            );
        final cleanup = await env.control.disableAndCleanup();
        expect(cleanup.isComplete, isFalse);

        reloaded = fresh();
        await reloaded.load();
        expect(reloaded.state, CalendarSyncControlState.cleanupPending);
        expect(reloaded.ownerKey, 'A');
        expect(reloaded.calendarId, 7);
      },
    );
  });

  group('ledger.recordRecoveredIds', () {
    test('only writes back pending entries and ignores unknown ids', () async {
      final ledger = CalendarEventLedgerStore.debugNew();
      await ledger.beginPendingBatch(
        ownerKey: 'A',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1), plan(2)],
        generation: 'gen-1',
      );

      final recovered = await ledger.recordRecoveredIds(
        ownerKey: 'A',
        generation: 'gen-1',
        eventIds: <String, int>{opaqueId(1): 101, opaqueId(9): 909},
      );

      expect(recovered, 1);
      expect(
        await ledger.recordRecoveredIds(
          ownerKey: 'nobody',
          generation: 'gen-1',
          eventIds: <String, int>{opaqueId(1): 101},
        ),
        0,
      );
      expect(
        await ledger.recordRecoveredIds(
          ownerKey: 'A',
          generation: 'missing',
          eventIds: <String, int>{opaqueId(1): 101},
        ),
        0,
      );

      final snapshot = await ledger.reload();
      final batch = snapshot.batchesFor('A').single;
      expect(batch.entries[opaqueId(1)]?.eventId, 101);
      expect(batch.entries[opaqueId(2)]?.isPending, isTrue);
    });
  });
}
