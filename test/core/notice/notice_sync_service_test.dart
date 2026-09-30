import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

Notice _notice(String id) => Notice(
  title: '通知$id',
  url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=$id',
  category: '通知公告',
  date: '2026-09-01',
);

String _listHtml(Iterable<Notice> notices) =>
    '<ul id="ul1">${notices.map((n) {
      return '<li class="clearfix">'
          '<a class="a1" href="content.jsp?urltype=news.NewsContentUrl'
          '&wbtreeid=1046&wbnewsid=${n.id}">${n.title}</a></li>';
    }).join()}</ul>';

const _loginHtml =
    '<html><head><title>统一身份认证平台</title></head>'
    '<body><form id="fm1"><input name="execution"/></form></body></html>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MockHttpClientAdapter adapter;
  late List<Map<String, Object?>> sentNotifications;
  late DateTime now;
  bool notificationsEnabled = true;
  bool failNotificationSend = false;

  void registerListHandler(List<Notice> Function(int page) pageContent) {
    adapter.register('GET', '/list.jsp', (options) async {
      final page =
          int.tryParse(options.uri.queryParameters['PAGENUM'] ?? '1') ?? 1;
      return ResponseBody.fromString(_listHtml(pageContent(page)), 200);
    });
  }

  setUp(() async {
    await resetTestEnvironment();
    NoticeService.instance.debugReset();
    tempDir = await Directory.systemTemp.createTemp('notice_sync_svc_test');
    NoticeSyncStore.instance.debugReset();
    NoticeSyncStore.instance.debugDirectoryProvider = () async => tempDir;
    BackgroundSessionGate.instance.debugReset();
    BackgroundSessionGate.instance.debugDirectoryProvider = () async => tempDir;

    adapter = MockHttpClientAdapter();
    registerListHandler(
      (page) => page == 1 ? [_notice('1'), _notice('2')] : [_notice('3')],
    );
    final dio = Dio(BaseOptions(responseType: ResponseType.bytes))
      ..httpClientAdapter = adapter;
    NoticeService.instance.debugSetDio(dio);

    sentNotifications = [];
    notificationsEnabled = true;
    failNotificationSend = false;
    now = DateTime(2026, 9, 1, 10);

    NoticeSyncService.instance.debugNow = () => now;
    NoticeSyncService.instance.debugNotificationsEnabled = () async =>
        notificationsEnabled;
    NoticeSyncService.instance.debugShowNotification =
        ({required id, required title, required body, required payload}) async {
          if (failNotificationSend) throw Exception('send failed');
          sentNotifications.add({
            'id': id,
            'title': title,
            'body': body,
            'payload': payload,
          });
          return true;
        };
  });

  tearDown(() async {
    NoticeSyncService.instance
      ..debugNow = null
      ..debugNotificationsEnabled = null
      ..debugShowNotification = null;
    NoticeSyncStore.instance.debugReset();
    BackgroundSessionGate.instance.debugReset();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  void advanceHours(int hours) => now = now.add(Duration(hours: hours));

  group('baseline', () {
    test(
      'first sync builds baseline: inbox visible, no unread, no notify',
      () async {
        final outcome = await NoticeSyncService.instance.sync(
          trigger: NoticeSyncTrigger.foregroundAuto,
        );

        expect(outcome.ok, isTrue);
        expect(outcome.notified, isFalse);
        expect(sentNotifications, isEmpty);
        final state = NoticeSyncStore.instance.state;
        expect(state.baselineBuilt, isTrue);
        expect(state.snapshotIds.keys, containsAll(['1', '2']));
        // 基线条目进收件箱（用户立刻可见），但不进未读/待播报（不打扰）。
        expect(state.inbox.map((n) => n.id), ['1', '2']);
        expect(state.unreadIds, isEmpty);
        expect(state.pendingNotifyIds, isEmpty);
        expect(state.lastSuccessfulSyncAt, isNotNull);
      },
    );

    test(
      'baseline second page failure keeps retry cursor, next sync completes',
      () async {
        // 基线：首页正常；下轮首页出现全新内容触发第二页补抓且失败 →
        // 游标保留；再下一轮重试成功后清除。
        var secondPageShouldFail = true;
        adapter.register('GET', '/list.jsp', (options) async {
          final page =
              int.tryParse(options.uri.queryParameters['PAGENUM'] ?? '1') ?? 1;
          if (page == 1) {
            return ResponseBody.fromString(_listHtml([_notice('1')]), 200);
          }
          if (secondPageShouldFail) throw Exception('page2 down');
          return ResponseBody.fromString(_listHtml([_notice('90')]), 200);
        });

        await NoticeSyncService.instance.sync(
          trigger: NoticeSyncTrigger.foregroundAuto,
        );
        var state = NoticeSyncStore.instance.state;
        expect(state.baselineBuilt, isTrue);
        expect(state.pendingBackfillPage, isNull);

        // 首页全为新增 → 触发第二页补抓，失败 → 游标保留。
        advanceHours(3);
        adapter.register('GET', '/list.jsp', (options) async {
          final page =
              int.tryParse(options.uri.queryParameters['PAGENUM'] ?? '1') ?? 1;
          if (page == 1) {
            return ResponseBody.fromString(_listHtml([_notice('2')]), 200);
          }
          if (secondPageShouldFail) throw Exception('page2 down');
          return ResponseBody.fromString(_listHtml([_notice('90')]), 200);
        });
        final outcome = await NoticeSyncService.instance.sync(
          trigger: NoticeSyncTrigger.foregroundAuto,
        );
        expect(outcome.ok, isTrue);
        state = NoticeSyncStore.instance.state;
        expect(state.pendingBackfillPage, 2);
        expect(state.snapshotIds.containsKey('2'), isTrue);

        // 下轮重试成功：补录入快照、清游标、不进收件箱/未读。
        advanceHours(3);
        secondPageShouldFail = false;
        registerListHandler(
          (page) => page == 1 ? [_notice('2')] : [_notice('90')],
        );
        await NoticeSyncService.instance.sync(
          trigger: NoticeSyncTrigger.foregroundAuto,
        );
        state = NoticeSyncStore.instance.state;
        expect(state.pendingBackfillPage, isNull);
        expect(state.snapshotIds.containsKey('90'), isTrue);
        expect(state.inbox.map((n) => n.id), contains('2'));
        expect(state.inbox.map((n) => n.id), isNot(contains('90')));
      },
    );
  });

  group('incremental sync and notify', () {
    Future<void> seedBaseline() async {
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      advanceHours(3);
    }

    test('new notice enters inbox/unread/pending and notifies once', () async {
      await seedBaseline();
      registerListHandler(
        (page) => page == 1 ? [_notice('7')] : [_notice('2')],
      );

      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );

      expect(outcome.freshCount, 1);
      expect(outcome.notified, isTrue);
      expect(sentNotifications, hasLength(1));
      expect(sentNotifications.first['payload'], 'notice-center');
      expect(
        (sentNotifications.first['body'] as String).contains('通知7'),
        isTrue,
      );
      final state = NoticeSyncStore.instance.state;
      // 基线条目（1、2）已在收件箱，新条目 7 插入头部；未读只含 7。
      expect(state.inbox.map((n) => n.id), ['7', '1', '2']);
      expect(state.unreadIds, ['7']);
      expect(state.pendingNotifyIds, isEmpty);
      expect(state.notifiedIds, ['7']);
    });

    test('quiet hour defers notify, no-new-sync still catches up', () async {
      now = DateTime(2026, 9, 1, 23, 30); // 静音窗内
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      advanceHours(3);
      registerListHandler(
        (page) => page == 1 ? [_notice('7')] : [_notice('2')],
      );
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      var state = NoticeSyncStore.instance.state;
      expect(state.pendingNotifyIds, contains('7'));
      expect(sentNotifications, isEmpty);

      // 静音结束（23:00–07:00 窗外）、无任何新增：仍补发（评审 P1 用例）。
      advanceHours(5); // 02:30 → 07:30
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(outcome.notified, isTrue);
      expect(sentNotifications, hasLength(1));
      state = NoticeSyncStore.instance.state;
      expect(state.pendingNotifyIds, isEmpty);
      expect(state.notifiedIds, contains('7'));
    });

    test('permission denied defers notify, restore catches up', () async {
      notificationsEnabled = false;
      await seedBaseline();
      registerListHandler(
        (page) => page == 1 ? [_notice('7')] : [_notice('2')],
      );
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(NoticeSyncStore.instance.state.pendingNotifyIds, contains('7'));

      notificationsEnabled = true;
      advanceHours(3);
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(outcome.notified, isTrue);
      expect(sentNotifications, hasLength(1));
    });

    test('send failure rolls back pending and retries next round', () async {
      failNotificationSend = true;
      await seedBaseline();
      registerListHandler(
        (page) => page == 1 ? [_notice('7')] : [_notice('2')],
      );
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      var state = NoticeSyncStore.instance.state;
      expect(state.pendingNotifyIds, contains('7'));
      expect(state.notifiedIds, isEmpty);

      failNotificationSend = false;
      advanceHours(3);
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(outcome.notified, isTrue);
      expect(sentNotifications, hasLength(1));
      expect(NoticeSyncStore.instance.state.notifiedIds, contains('7'));
    });

    test('manual refresh never sends notifications', () async {
      // 静音期积压一条待播报。
      now = DateTime(2026, 9, 1, 23, 30);
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      advanceHours(3);
      registerListHandler(
        (page) => page == 1 ? [_notice('7')] : [_notice('2')],
      );
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(NoticeSyncStore.instance.state.pendingNotifyIds, isNotEmpty);

      // 页面内手动刷新：force 绕过节流，但不领取播报。
      advanceHours(1);
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.manualRefresh,
      );
      expect(outcome.skipped, isFalse);
      expect(outcome.notified, isFalse);
      expect(sentNotifications, isEmpty);
      expect(NoticeSyncStore.instance.state.pendingNotifyIds, isNotEmpty);
    });

    test('reorder and re-date do not produce false positives', () async {
      await seedBaseline();
      // 置顶重排：基线已有条目 1、2，顺序对调 + 日期变化（同稳定 id）。
      registerListHandler(
        (page) => page == 1 ? [_notice('2'), _notice('1')] : [_notice('3')],
      );
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(outcome.freshCount, 0);
      expect(outcome.notified, isFalse);
      expect(sentNotifications, isEmpty);
      // 基线已入收件箱：重排不产生新增，收件箱保持原内容与顺序。
      expect(NoticeSyncStore.instance.state.inbox.map((n) => n.id), ['1', '2']);
    });
  });

  group('throttle and failure handling', () {
    test('auto sync within success window is skipped', () async {
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      advanceHours(1);
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      expect(outcome.skipped, isTrue);
    });

    test('authRequired leaves business data untouched', () async {
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      advanceHours(3);
      registerListHandler(
        (page) => page == 1 ? [_notice('7')] : [_notice('2')],
      );
      // 先制造一条新增入库，再让下一轮认证失效。
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      final before = NoticeSyncStore.instance.state;
      expect(before.inbox, isNotEmpty);

      advanceHours(3);
      adapter.register('GET', '/list.jsp', (options) async {
        return ResponseBody.fromString(_loginHtml, 200);
      });
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );

      expect(outcome.fetchStatus, NoticeFetchStatus.authRequired);
      final after = NoticeSyncStore.instance.state;
      expect(after.inbox.map((n) => n.id), before.inbox.map((n) => n.id));
      expect(after.snapshotIds.length, before.snapshotIds.length);
      expect(after.lastAttemptAt, isNotNull);
    });

    test('afterLogin retry bypasses throttle', () async {
      await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.foregroundAuto,
      );
      advanceHours(1);
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.afterLogin,
      );
      expect(outcome.skipped, isFalse);
    });
  });

  group('notifyAuthExpired', () {
    test('sends once, then is rate limited', () async {
      expect(await NoticeSyncService.instance.notifyAuthExpired(), isTrue);
      expect(sentNotifications, hasLength(1));
      expect(sentNotifications.single['title'], contains('重新登录'));
      expect(await NoticeSyncService.instance.notifyAuthExpired(), isFalse);
      expect(sentNotifications, hasLength(1));
    });

    test('skipped during quiet hours and without permission', () async {
      now = DateTime(2026, 9, 1, 23, 30);
      expect(await NoticeSyncService.instance.notifyAuthExpired(), isFalse);
      now = DateTime(2026, 9, 1, 10);
      notificationsEnabled = false;
      expect(await NoticeSyncService.instance.notifyAuthExpired(), isFalse);
      expect(sentNotifications, isEmpty);
    });

    test('send failure rolls back so the next check can retry', () async {
      failNotificationSend = true;
      expect(await NoticeSyncService.instance.notifyAuthExpired(), isFalse);
      failNotificationSend = false;
      expect(await NoticeSyncService.instance.notifyAuthExpired(), isTrue);
      expect(sentNotifications, hasLength(1));
    });
  });
}
