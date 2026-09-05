import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';

Notice _notice(String id, {String? date}) => Notice(
  title: '通知$id',
  url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=$id',
  category: '通知公告',
  date: date ?? '2026-09-01',
);

NoticeSyncCommit _commitFresh(List<Notice> notices, {DateTime? now}) =>
    NoticeSyncCommit(
      freshNotices: notices,
      now: now ?? DateTime(2026, 9, 1, 10),
    );

void main() {
  late Directory tempDir;
  late NoticeSyncStore storeA;
  late NoticeSyncStore storeB;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('notice_sync_store_test');
    storeA = NoticeSyncStore.debugNew(directoryProvider: () async => tempDir);
    storeB = NoticeSyncStore.debugNew(directoryProvider: () async => tempDir);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('merge semantics', () {
    test(
      'commit persists snapshot/inbox/unread/pending across instances',
      () async {
        final result = await storeA.commitSync(
          _commitFresh([_notice('1'), _notice('2')]),
        );
        expect(result.acceptedFresh, hasLength(2));

        final reloaded = await storeB.reload();
        expect(reloaded.snapshotIds.keys, containsAll(['1', '2']));
        expect(reloaded.inbox.map((n) => n.id), containsAll(['1', '2']));
        expect(reloaded.unreadIds, containsAll(['1', '2']));
        expect(reloaded.pendingNotifyIds, containsAll(['1', '2']));
      },
    );

    test('duplicate commit is idempotent', () async {
      await storeA.commitSync(_commitFresh([_notice('1')]));
      final second = await storeA.commitSync(_commitFresh([_notice('1')]));
      expect(second.acceptedFresh, isEmpty);
      final state = await storeA.reload();
      expect(state.inbox, hasLength(1));
    });

    test('historic backfill only enters snapshot', () async {
      await storeA.commitSync(
        NoticeSyncCommit(
          historicNotices: [_notice('old')],
          now: DateTime(2026, 9, 1),
        ),
      );
      final state = await storeA.reload();
      expect(state.snapshotIds.containsKey('old'), isTrue);
      expect(state.inbox, isEmpty);
      expect(state.unreadIds, isEmpty);
      expect(state.pendingNotifyIds, isEmpty);
    });

    test(
      'inbox persists in date-descending order regardless of commit order',
      () async {
        // 教务处列表页存在置顶/补录混排：新条目出现在旧条目之后也要按
        // 日期归位，首页与通知中心的「最新」才可靠。
        await storeA.commitSync(
          _commitFresh([
            _notice('2', date: '2026-08-30'),
            _notice('3', date: '2026-07-13'),
            _notice('1', date: '2026-09-04'),
          ]),
        );
        final state = await storeA.reload();
        expect(state.inbox.map((n) => n.id), ['1', '2', '3']);
        // 首页区块载荷同源。
        expect(storeA.inboxHead.value.latest.map((n) => n.id), ['1', '2', '3']);
      },
    );

    test('baseline entries enter inbox but not unread/pending', () async {
      await storeA.commitSync(
        NoticeSyncCommit(
          baselineNotices: [_notice('1'), _notice('2')],
          baselineComplete: true,
          now: DateTime(2026, 9, 1),
        ),
      );
      final state = await storeA.reload();
      expect(state.baselineBuilt, isTrue);
      expect(state.snapshotIds.keys, containsAll(['1', '2']));
      expect(state.inbox.map((n) => n.id), ['1', '2']);
      expect(state.unreadIds, isEmpty);
      expect(state.pendingNotifyIds, isEmpty);
      // 收件箱可见性同步反映到首页区块载荷。
      expect(storeA.inboxHead.value.latest.map((n) => n.id), ['1', '2']);
      expect(storeA.inboxHead.value.unreadCount, 0);
    });

    test('json round-trip keeps backfill cursor and timestamps', () async {
      final attemptAt = DateTime(2026, 9, 1, 8, 55);
      await storeA.claimSync(now: attemptAt, force: true);
      await storeA.commitSync(
        NoticeSyncCommit(
          freshNotices: [_notice('1')],
          baselineComplete: true,
          backfillCursor: 2,
          markSuccess: true,
          now: DateTime(2026, 9, 1, 9),
        ),
      );
      final state = await storeB.reload();
      expect(state.baselineBuilt, isTrue);
      expect(state.pendingBackfillPage, 2);
      expect(state.lastSuccessfulSyncAt, DateTime(2026, 9, 1, 9));
      expect(state.lastAttemptAt, attemptAt);
    });
  });

  group('concurrent writers', () {
    test('stale writer does not clobber fresh commits', () async {
      // A 提交条目 1；B 持有旧镜像（空）直接提交条目 2 —— 锁内重读磁盘，
      // 两条都应存活（丢失更新回归用例）。
      await storeA.commitSync(_commitFresh([_notice('1')]));
      await storeB.commitSync(_commitFresh([_notice('2')]));

      final state = await storeA.reload();
      expect(state.snapshotIds.keys, containsAll(['1', '2']));
      expect(state.inbox.map((n) => n.id), containsAll(['1', '2']));
    });

    test('interleaved markRead and commit keep both effects', () async {
      await storeA.commitSync(_commitFresh([_notice('1'), _notice('2')]));
      // A 标已读 1；B 基于旧镜像（未读 1、2）提交条目 3。
      await storeA.markRead(['1']);
      await storeB.commitSync(_commitFresh([_notice('3')]));

      final state = await storeA.reload();
      expect(state.unreadIds, containsAll(['2', '3']));
      expect(state.unreadIds.contains('1'), isFalse);
    });

    test('concurrent claims: exactly one granted', () async {
      final results = await Future.wait([
        storeA.claimSync(now: DateTime(2026, 9, 1, 10), force: false),
        storeB.claimSync(now: DateTime(2026, 9, 1, 10, 0, 1), force: false),
      ]);
      expect(results.where((r) => r == NoticeSyncClaim.granted), hasLength(1));
    });

    test('claim throttle: fresh success blocks, stale success grants, '
        'failure retries after backoff', () async {
      final t0 = DateTime(2026, 9, 1, 8);
      expect(
        await storeA.claimSync(now: t0, force: false),
        NoticeSyncClaim.granted,
      );
      // 从未成功：attempt 退避期内 blocked。
      expect(
        await storeA.claimSync(
          now: t0.add(const Duration(minutes: 10)),
          force: false,
        ),
        NoticeSyncClaim.blocked,
      );
      // 退避到期：允许重试。
      expect(
        await storeA.claimSync(
          now: t0.add(const Duration(minutes: 31)),
          force: false,
        ),
        NoticeSyncClaim.granted,
      );
      // 成功后 1 小时：按 2h 节奏 blocked。
      await storeA.commitSync(
        NoticeSyncCommit(
          markSuccess: true,
          now: t0.add(const Duration(minutes: 31)),
        ),
      );
      expect(
        await storeA.claimSync(
          now: t0.add(const Duration(hours: 1)),
          force: false,
        ),
        NoticeSyncClaim.blocked,
      );
      // 成功后 2.5 小时：granted（自成功时刻起算超过 2h）。
      expect(
        await storeA.claimSync(
          now: t0.add(const Duration(hours: 4)),
          force: false,
        ),
        NoticeSyncClaim.granted,
      );
      // force 绕过节流。
      expect(
        await storeB.claimSync(
          now: t0.add(const Duration(hours: 2, minutes: 31)),
          force: true,
        ),
        NoticeSyncClaim.granted,
      );
    });

    test('concurrent notify claim: single non-empty batch', () async {
      await storeA.commitSync(_commitFresh([_notice('1'), _notice('2')]));
      final batches = await Future.wait([
        storeA.claimNotifyBatch(canNotify: true),
        storeB.claimNotifyBatch(canNotify: true),
      ]);
      final nonEmpty = batches.where((b) => b.isNotEmpty).toList();
      expect(nonEmpty, hasLength(1));
      expect(nonEmpty.first.map((n) => n.id), containsAll(['1', '2']));
    });
  });

  group('file lock', () {
    File lockFile() =>
        File('${tempDir.path}${Platform.pathSeparator}notice_sync_state.lock');

    test('legacy empty lock file is recovered instead of blocking', () async {
      // 旧版本 fcntl 实现遗留的空锁文件：必须在空锁宽限期内回收（而非
      // 等满 60s 陈旧阈值），升级后首次取锁不应被旧版残留卡住。宽限期
      // 只为活跃写者的毫秒级 token 写入窗口留余量。
      await lockFile().create();
      await storeA.reload();
      expect(lockFile().existsSync(), isFalse);
    });

    test('live foreign lock blocks until released', () async {
      final lock = lockFile();
      await lock.create();
      await lock.writeAsString('foreign-holder', flush: true);
      // 手动刷新 mtime，确保被视为活跃持有者（而非陈旧残留）。
      await lock.setLastModified(DateTime.now());

      var completed = false;
      final reloading = storeA.reload().then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(completed, isFalse, reason: '活跃锁必须阻塞其他写者');
      await lock.delete();
      await reloading;
      expect(completed, isTrue);
    });

    test('aged foreign lock is recovered', () async {
      final lock = lockFile();
      await lock.create();
      await lock.writeAsString('dead-holder', flush: true);
      await lock.setLastModified(
        DateTime.now().subtract(const Duration(seconds: 61)),
      );

      await storeA.reload();
      expect(lock.existsSync(), isFalse);
    });
  });

  group('notify queue linkage', () {
    test('markRead removes entry from pending queue', () async {
      await storeA.commitSync(_commitFresh([_notice('1'), _notice('2')]));
      await storeA.markRead(['1']);
      final batch = await storeA.claimNotifyBatch(canNotify: true);
      expect(batch.map((n) => n.id), ['2']);
    });

    test('canNotify false keeps queue for later catch-up', () async {
      await storeA.commitSync(_commitFresh([_notice('1')]));
      final batch = await storeA.claimNotifyBatch(canNotify: false);
      expect(batch, isEmpty);
      final state = await storeA.reload();
      expect(state.pendingNotifyIds, contains('1'));
    });

    test('confirmNotified / rollback update queues accordingly', () async {
      await storeA.commitSync(_commitFresh([_notice('1')]));
      final batch = await storeA.claimNotifyBatch(canNotify: true);
      await storeA.rollbackNotifyBatch(batch);
      var state = await storeA.reload();
      expect(state.pendingNotifyIds, contains('1'));
      expect(state.notifiedIds, isEmpty);

      await storeA.claimNotifyBatch(canNotify: true);
      await storeA.confirmNotified(batch);
      state = await storeA.reload();
      expect(state.notifiedIds, contains('1'));
      expect(state.pendingNotifyIds, isEmpty);
    });

    test('inbox eviction removes evicted ids from unread/pending', () async {
      // fresh 顺序 = 页面顺序（列表头最新）：1 最新，105 最旧。
      final notices = List.generate(105, (i) => _notice('${i + 1}'));
      await storeA.commitSync(_commitFresh(notices));
      final state = await storeA.reload();
      expect(state.inbox, hasLength(100));
      expect(state.unreadIds, hasLength(100));
      // 最旧的 5 条（101–105）被裁出收件箱，联动移出未读与待播报。
      expect(state.unreadIds.contains('105'), isFalse);
      expect(state.pendingNotifyIds.contains('105'), isFalse);
      expect(state.pendingNotifyIds.contains('101'), isFalse);
      expect(state.pendingNotifyIds.contains('100'), isTrue);
    });

    test('snapshot cap trims oldest ids', () async {
      final notices = List.generate(2005, (i) => _notice('s$i'));
      await storeA.commitSync(
        NoticeSyncCommit(historicNotices: notices, now: DateTime(2026, 9, 1)),
      );
      final state = await storeA.reload();
      expect(state.snapshotIds, hasLength(2000));
      expect(state.snapshotIds.containsKey('s0'), isFalse);
      expect(state.snapshotIds.containsKey('s2004'), isTrue);
    });
  });

  group('durability and visibility', () {
    test('corrupt state file rebuilds empty', () async {
      await storeA.commitSync(_commitFresh([_notice('1')]));
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}notice_sync_state.json',
      );
      await file.writeAsString('{broken json');
      final state = await storeA.reload();
      expect(state.inbox, isEmpty);
      expect(state.snapshotIds, isEmpty);
    });

    test(
      'background write then main-isolate reload refreshes summary',
      () async {
        expect(storeB.unreadSummary.value.count, 0);
        await storeA.commitSync(
          _commitFresh([
            _notice('1'),
            _notice('2'),
            _notice('3'),
            _notice('4'),
          ]),
        );
        // 网络同步可能被节流跳过，但 reload 必须让红点正确。
        await storeB.reload();
        final summary = storeB.unreadSummary.value;
        expect(summary.count, 4);
        expect(summary.latest, hasLength(3));
        expect(summary.latest.first.id, '1');
      },
    );

    test('markAllRead clears unread and pending', () async {
      await storeA.commitSync(_commitFresh([_notice('1'), _notice('2')]));
      await storeA.markAllRead();
      final state = await storeA.reload();
      expect(state.unreadIds, isEmpty);
      expect(state.pendingNotifyIds, isEmpty);
      expect(storeA.unreadSummary.value.count, 0);
    });
  });

  group('inbox head (home campus notice section)', () {
    test(
      'latest includes read entries, unread marks tracked separately',
      () async {
        expect(storeA.inboxHead.value.isEmpty, isTrue);
        await storeA.commitSync(
          _commitFresh([_notice('1'), _notice('2'), _notice('3')]),
        );

        var head = storeA.inboxHead.value;
        expect(head.latest.map((n) => n.id), ['1', '2', '3']);
        expect(head.unreadIds, containsAll(['1', '2', '3']));
        expect(head.unreadCount, 3);

        // 已读条目仍留在最新列表里，只是圆点消失。
        await storeA.markRead(['1']);
        head = storeA.inboxHead.value;
        expect(head.latest.map((n) => n.id), ['1', '2', '3']);
        expect(head.unreadIds.contains('1'), isFalse);
        expect(head.unreadCount, 2);
      },
    );

    test('unread count exceeds head entries (badge shows total)', () async {
      await storeA.commitSync(
        _commitFresh([
          _notice('1'),
          _notice('2'),
          _notice('3'),
          _notice('4'),
          _notice('5'),
        ]),
      );
      final head = storeA.inboxHead.value;
      expect(head.latest, hasLength(3));
      expect(head.unreadCount, 5);
      expect(head.unreadIds, hasLength(3));
    });

    test('reload on another instance refreshes head', () async {
      await storeA.commitSync(_commitFresh([_notice('1')]));
      await storeA.markAllRead();
      await storeB.reload();
      final head = storeB.inboxHead.value;
      expect(head.latest.map((n) => n.id), ['1']);
      expect(head.unreadIds, isEmpty);
      expect(head.unreadCount, 0);
    });
  });
}
