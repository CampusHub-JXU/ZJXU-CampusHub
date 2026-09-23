import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 合法（UUID 形态）随机标识占位：仅测试内可预测。
  String opaqueId(int index) =>
      '${index.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000';

  CalendarSyncEventPlan plan(int index, {String? businessKey}) =>
      CalendarSyncEventPlan(
        opaqueId: opaqueId(index),
        businessKey: businessKey ?? 'course-$index',
      );

  Future<CalendarSyncException> expectFailure(Future<Object?> future) async {
    try {
      await future;
    } on CalendarSyncException catch (error) {
      return error;
    }
    fail('期望抛出 CalendarSyncException');
  }

  group('beginPendingBatch', () {
    test('persists the plan before returning (crash-safe ordering)', () async {
      final store = CalendarEventLedgerStore.debugNew();

      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1), plan(2)],
      );

      expect(batch.entries, hasLength(2));
      expect(batch.pendingCount, 2);
      expect(batch.calendarId, 7);
      expect(CalendarSyncOpaqueId.isValid(batch.generation), isTrue);

      // 模拟进程重启：新实例读盘必须能恢复 pending 计划。
      final restarted = CalendarEventLedgerStore.debugNew();
      final snapshot = await restarted.reload();

      expect(snapshot.owners.keys, contains('owner-a'));
      final recovered = snapshot.batchesFor('owner-a').single;
      expect(recovered.generation, batch.generation);
      expect(recovered.calendarId, 7);
      expect(recovered.pendingCount, 2);
      expect(recovered.entries[opaqueId(1)]?.businessKey, 'course-1');
      expect(recovered.entries[opaqueId(1)]?.eventId, isNull);
    });

    test('honours an injected generation and rejects duplicates', () async {
      final store = CalendarEventLedgerStore.debugNew();
      await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
        generation: 'generation-1',
      );

      final duplicate = await expectFailure(
        store.beginPendingBatch(
          ownerKey: 'owner-a',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(2)],
          generation: 'generation-1',
        ),
      );
      expect(duplicate.kind, CalendarSyncFailureKind.invalidArgument);
    });

    test('rejects invalid local plans without writing', () async {
      final store = CalendarEventLedgerStore.debugNew();

      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: '   ',
            calendarId: 7,
            plans: <CalendarSyncEventPlan>[plan(1)],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-a',
            calendarId: 0,
            plans: <CalendarSyncEventPlan>[plan(1)],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-a',
            calendarId: 7,
            plans: const <CalendarSyncEventPlan>[],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-a',
            calendarId: 7,
            plans: <CalendarSyncEventPlan>[
              for (
                var index = 0;
                index <= CalendarSyncProtocol.maxBatchEvents;
                index++
              )
                plan(index),
            ],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-a',
            calendarId: 7,
            plans: <CalendarSyncEventPlan>[
              const CalendarSyncEventPlan(
                opaqueId: '2023012345',
                businessKey: 'course',
              ),
            ],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-a',
            calendarId: 7,
            plans: <CalendarSyncEventPlan>[
              CalendarSyncEventPlan(opaqueId: opaqueId(1), businessKey: '  '),
            ],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-a',
            calendarId: 7,
            plans: <CalendarSyncEventPlan>[plan(1), plan(1)],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );

      // 同一 opaqueId 不得在两个批次间重复建立归属。
      await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      expect(
        (await expectFailure(
          store.beginPendingBatch(
            ownerKey: 'owner-b',
            calendarId: 8,
            plans: <CalendarSyncEventPlan>[plan(1)],
          ),
        )).kind,
        CalendarSyncFailureKind.invalidArgument,
      );
      expect((await store.reload()).allBatches, hasLength(1));
    });
  });

  group('commitBatch', () {
    test('registers eventIds for the matching generation', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1), plan(2)],
      );

      final result = await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101, opaqueId(2): 102},
      );

      expect(result.status, CalendarEventLedgerCommitStatus.committed);
      expect(result.accepted, isTrue);
      expect(
        result.appliedOpaqueIds,
        containsAll(<String>[opaqueId(1), opaqueId(2)]),
      );
      expect(result.unknownOpaqueIds, isEmpty);

      final restarted = CalendarEventLedgerStore.debugNew();
      final snapshot = await restarted.reload();
      final committed = snapshot.batchesFor('owner-a').single;
      expect(committed.pendingCount, 0);
      expect(committed.entries[opaqueId(1)]?.eventId, 101);
      expect(committed.entries[opaqueId(2)]?.eventId, 102);
    });

    test('rejects late results from an old generation', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final first = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      // 同一账号重登后的新批次（或新一轮同步）取代旧 generation。
      final second = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(2)],
      );

      final late = await store.commitBatch(
        ownerKey: 'owner-a',
        generation: first.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );

      expect(late.status, CalendarEventLedgerCommitStatus.staleGeneration);
      expect(late.accepted, isFalse);
      expect(late.appliedOpaqueIds, isEmpty);

      final snapshot = await store.reload();
      final firstBatch = snapshot
          .batchesFor('owner-a')
          .firstWhere((batch) => batch.generation == first.generation);
      expect(firstBatch.entries[opaqueId(1)]?.isPending, isTrue);
      expect(firstBatch.entries[opaqueId(1)]?.eventId, isNull);

      // 当前批次仍可正常提交。
      final committed = await store.commitBatch(
        ownerKey: 'owner-a',
        generation: second.generation,
        eventIds: <String, int>{opaqueId(2): 102},
      );
      expect(committed.status, CalendarEventLedgerCommitStatus.committed);
    });

    test(
      'rejects unknown owner / unknown generation / bogus opaqueIds',
      () async {
        final store = CalendarEventLedgerStore.debugNew();
        final batch = await store.beginPendingBatch(
          ownerKey: 'owner-a',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );

        expect(
          (await store.commitBatch(
            ownerKey: 'nobody',
            generation: batch.generation,
            eventIds: const <String, int>{},
          )).status,
          CalendarEventLedgerCommitStatus.unknownOwner,
        );
        expect(
          (await store.commitBatch(
            ownerKey: 'owner-a',
            generation: 'missing-generation',
            eventIds: const <String, int>{},
          )).status,
          CalendarEventLedgerCommitStatus.unknownBatch,
        );

        final mixed = await store.commitBatch(
          ownerKey: 'owner-a',
          generation: batch.generation,
          eventIds: <String, int>{
            opaqueId(1): 101,
            opaqueId(9): 999,
            opaqueId(8): 0,
          },
        );
        expect(mixed.status, CalendarEventLedgerCommitStatus.committed);
        expect(mixed.appliedOpaqueIds, <String>[opaqueId(1)]);
        expect(
          mixed.unknownOpaqueIds,
          containsAll(<String>[opaqueId(9), opaqueId(8)]),
        );

        final snapshot = await store.reload();
        expect(snapshot.batchesFor('owner-a').single.entries.keys, <String>[
          opaqueId(1),
        ]);
      },
    );

    test('is idempotent when replaying the same eventIds', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );

      final first = await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );
      final replay = await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );

      expect(first.status, CalendarEventLedgerCommitStatus.committed);
      expect(replay.status, CalendarEventLedgerCommitStatus.committed);
      expect(replay.appliedOpaqueIds, <String>[opaqueId(1)]);
      expect(
        (await store.reload())
            .batchesFor('owner-a')
            .single
            .entries[opaqueId(1)]
            ?.eventId,
        101,
      );
    });
  });

  group('ownership retention across accounts', () {
    test('keeps every owner and batch until explicitly cleaned', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batchA = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      final batchB = await store.beginPendingBatch(
        ownerKey: 'owner-b',
        calendarId: 8,
        plans: <CalendarSyncEventPlan>[plan(2)],
      );
      await store.commitBatch(
        ownerKey: 'owner-b',
        generation: batchB.generation,
        eventIds: <String, int>{opaqueId(2): 202},
      );

      final restarted = CalendarEventLedgerStore.debugNew();
      final snapshot = await restarted.reload();

      expect(snapshot.owners.keys.toSet(), <String>{'owner-a', 'owner-b'});
      expect(
        snapshot.batchesFor('owner-a').single.generation,
        batchA.generation,
      );
      expect(
        snapshot.batchesFor('owner-b').single.entries[opaqueId(2)]?.eventId,
        202,
      );
      expect(restarted.ownerKeys, containsAll(<String>['owner-a', 'owner-b']));
    });

    test('exposes active batch and business-key lookups', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1, businessKey: '2026-1|高等数学|1-2')],
      );

      expect(
        store.activeBatch(ownerKey: 'owner-a', calendarId: 7)?.generation,
        batch.generation,
      );
      expect(store.activeBatch(ownerKey: 'owner-a', calendarId: 8), isNull);
      expect(
        store
            .entryForBusinessKey(
              ownerKey: 'owner-a',
              businessKey: '2026-1|高等数学|1-2',
            )
            ?.opaqueId,
        opaqueId(1),
      );
      expect(
        store.entryForBusinessKey(ownerKey: 'owner-a', businessKey: 'missing'),
        isNull,
      );
      expect(store.entriesForOwner('owner-a'), hasLength(1));
    });
  });

  group('removeEntries (cleanup)', () {
    test('removes only confirmed ids and keeps the rest', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1), plan(2), plan(3)],
      );
      await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{
          opaqueId(1): 101,
          opaqueId(2): 102,
          opaqueId(3): 103,
        },
      );

      // 清理部分失败：只移除删除成功的项，失败项保留供下次复核。
      final removed = await store.removeEntries(
        ownerKey: 'owner-a',
        generation: batch.generation,
        opaqueIds: <String>[opaqueId(1)],
      );
      expect(removed, 1);

      final afterPartial = await store.reload();
      final remaining = afterPartial.batchesFor('owner-a').single;
      expect(remaining.entries.keys.toSet(), <String>{
        opaqueId(2),
        opaqueId(3),
      });

      expect(
        await store.removeEntries(
          ownerKey: 'owner-a',
          generation: batch.generation,
          opaqueIds: <String>[opaqueId(9)],
        ),
        0,
      );
      expect(
        await store.removeEntries(
          ownerKey: 'owner-a',
          generation: 'missing-generation',
          opaqueIds: <String>[opaqueId(2)],
        ),
        0,
      );

      final removedRest = await store.removeEntries(
        ownerKey: 'owner-a',
        generation: batch.generation,
        opaqueIds: <String>[opaqueId(2), opaqueId(3)],
      );
      expect(removedRest, 2);

      // 批次与 owner 清空后自动移除。
      final empty = await store.reload();
      expect(empty.isEmpty, isTrue);
      expect(empty.owners, isEmpty);
      expect(store.ownerKeys, isEmpty);
    });

    test('a cleaned owner can no longer commit (unknownOwner)', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );
      await store.removeEntries(
        ownerKey: 'owner-a',
        generation: batch.generation,
        opaqueIds: <String>[opaqueId(1)],
      );

      final late = await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101},
      );
      expect(late.status, CalendarEventLedgerCommitStatus.unknownOwner);
      expect(late.accepted, isFalse);
    });
  });

  group('same-isolate serialization', () {
    test(
      'concurrent beginPendingBatch calls do not overwrite each other',
      () async {
        final store = CalendarEventLedgerStore.debugNew();

        await Future.wait<CalendarEventLedgerBatch>(
          <Future<CalendarEventLedgerBatch>>[
            for (var index = 0; index < 6; index++)
              store.beginPendingBatch(
                ownerKey: 'owner-a',
                calendarId: 7,
                plans: <CalendarSyncEventPlan>[plan(index)],
              ),
          ],
        );

        final snapshot = await CalendarEventLedgerStore.debugNew().reload();
        expect(snapshot.batchesFor('owner-a'), hasLength(6));
        expect(snapshot.allEntries, hasLength(6));
      },
    );

    test('interleaved begin/commit keep consistent state', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );

      await Future.wait<Object>(<Future<Object>>[
        store.commitBatch(
          ownerKey: 'owner-a',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        ),
        store.beginPendingBatch(
          ownerKey: 'owner-b',
          calendarId: 8,
          plans: <CalendarSyncEventPlan>[plan(2)],
        ),
      ]);

      final snapshot = await CalendarEventLedgerStore.debugNew().reload();
      expect(
        snapshot.batchesFor('owner-a').single.entries[opaqueId(1)]?.eventId,
        101,
      );
      expect(snapshot.batchesFor('owner-b').single.pendingCount, 1);
    });
  });

  group('corrupted ledger', () {
    test('fails closed, preserves the raw value and blocks writes', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CalendarEventLedgerStore.storageKey: '{not-json',
      });
      final store = CalendarEventLedgerStore.debugNew();

      final readFailure = await expectFailure(store.reload());
      expect(readFailure.kind, CalendarSyncFailureKind.ledgerCorrupted);

      final writeFailure = await expectFailure(
        store.beginPendingBatch(
          ownerKey: 'owner-a',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        ),
      );
      expect(writeFailure.kind, CalendarSyncFailureKind.ledgerCorrupted);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(CalendarEventLedgerStore.storageKey), '{not-json');
    });

    test('rejects a structurally wrong payload without deleting it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CalendarEventLedgerStore.storageKey: '{"v":99,"owners":{}}',
      });
      final store = CalendarEventLedgerStore.debugNew();

      final failure = await expectFailure(store.reload());
      expect(failure.kind, CalendarSyncFailureKind.ledgerCorrupted);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(CalendarEventLedgerStore.storageKey),
        '{"v":99,"owners":{}}',
      );
    });

    test('clearAll is the explicit recovery path', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CalendarEventLedgerStore.storageKey: '{not-json',
      });
      final store = CalendarEventLedgerStore.debugNew();

      await store.clearAll();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(CalendarEventLedgerStore.storageKey), isFalse);
      expect(store.snapshot.isEmpty, isTrue);
      expect((await store.reload()).isEmpty, isTrue);

      // 重建后可正常写入。
      await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );
      expect((await store.reload()).allBatches, hasLength(1));
    });

    test('clearAll removes a healthy ledger from disk and memory', () async {
      final store = CalendarEventLedgerStore.debugNew();
      await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1)],
      );

      await store.clearAll();

      expect(store.snapshot.isEmpty, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(CalendarEventLedgerStore.storageKey), isFalse);
      expect(
        (await CalendarEventLedgerStore.debugNew().reload()).isEmpty,
        isTrue,
      );
    });
  });

  group('reassignEventId (constrained rebind)', () {
    test('rebinds a committed entry with matching expected old id', () async {
      final store = CalendarEventLedgerStore.debugNew();
      final batch = await store.beginPendingBatch(
        ownerKey: 'owner-a',
        calendarId: 7,
        plans: <CalendarSyncEventPlan>[plan(1), plan(2)],
      );
      await store.commitBatch(
        ownerKey: 'owner-a',
        generation: batch.generation,
        eventIds: <String, int>{opaqueId(1): 101, opaqueId(2): 102},
      );

      expect(
        await store.reassignEventId(
          ownerKey: 'owner-a',
          generation: batch.generation,
          opaqueId: opaqueId(1),
          expectedOldEventId: 101,
          providerVerifiedNewEventId: 777,
        ),
        isTrue,
      );

      final snapshot = await store.reload();
      final entry = snapshot.batchesFor('owner-a').single;
      expect(entry.entries[opaqueId(1)]?.eventId, 777);
      expect(entry.entries[opaqueId(2)]?.eventId, 102);
    });

    test(
      'rejects mismatched expected id / unknown target without writing',
      () async {
        final store = CalendarEventLedgerStore.debugNew();
        final batch = await store.beginPendingBatch(
          ownerKey: 'owner-a',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
        );
        await store.commitBatch(
          ownerKey: 'owner-a',
          generation: batch.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        );

        Future<bool> attempt({
          String ownerKey = 'owner-a',
          String? generation,
          String? opaque,
          int expectedOld = 101,
          int newId = 777,
        }) => store.reassignEventId(
          ownerKey: ownerKey,
          generation: generation ?? batch.generation,
          opaqueId: opaque ?? opaqueId(1),
          expectedOldEventId: expectedOld,
          providerVerifiedNewEventId: newId,
        );

        expect(await attempt(expectedOld: 999), isFalse);
        expect(await attempt(generation: 'missing-generation'), isFalse);
        expect(await attempt(ownerKey: 'nobody'), isFalse);
        expect(await attempt(opaque: opaqueId(9)), isFalse);
        expect(await attempt(newId: 0), isFalse);

        final snapshot = await store.reload();
        expect(
          snapshot.batchesFor('owner-a').single.entries[opaqueId(1)]?.eventId,
          101,
        );
      },
    );

    test(
      'works for an old generation and does not relax the commit guard',
      () async {
        final store = CalendarEventLedgerStore.debugNew();
        final old = await store.beginPendingBatch(
          ownerKey: 'owner-a',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(1)],
          generation: 'gen-old',
        );
        await store.commitBatch(
          ownerKey: 'owner-a',
          generation: old.generation,
          eventIds: <String, int>{opaqueId(1): 101},
        );
        await store.beginPendingBatch(
          ownerKey: 'owner-a',
          calendarId: 7,
          plans: <CalendarSyncEventPlan>[plan(2)],
          generation: 'gen-new',
        );

        expect(
          await store.reassignEventId(
            ownerKey: 'owner-a',
            generation: 'gen-old',
            opaqueId: opaqueId(1),
            expectedOldEventId: 101,
            providerVerifiedNewEventId: 555,
          ),
          isTrue,
        );
        expect(
          (await store.reload())
              .batchesFor('owner-a')
              .firstWhere((batch) => batch.generation == 'gen-old')
              .entries[opaqueId(1)]
              ?.eventId,
          555,
        );

        // 旧代仍不能通过 commitBatch 写入（未晋升 active、守卫未放宽）。
        final late = await store.commitBatch(
          ownerKey: 'owner-a',
          generation: 'gen-old',
          eventIds: <String, int>{opaqueId(1): 999},
        );
        expect(late.status, CalendarEventLedgerCommitStatus.staleGeneration);
        expect(
          (await store.reload())
              .batchesFor('owner-a')
              .firstWhere((batch) => batch.generation == 'gen-old')
              .entries[opaqueId(1)]
              ?.eventId,
          555,
        );
      },
    );
  });

  test('reload on an empty store returns the empty snapshot', () async {
    final store = CalendarEventLedgerStore.debugNew();

    expect(store.isLoaded, isFalse);
    final snapshot = await store.reload();

    expect(snapshot.isEmpty, isTrue);
    expect(store.isLoaded, isTrue);
    expect(store.ownerKeys, isEmpty);
  });
}
