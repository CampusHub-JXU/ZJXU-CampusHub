import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/features/notification_center/notification_center_page.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

Notice _notice(int n) => Notice(
  title: '通知$n',
  url:
      'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl'
      '&wbtreeid=1046&wbnewsid=$n',
  category: '通知公告',
  date: '2026-09-01',
);

String _listHtml(Iterable<Notice> notices) =>
    '<ul id="ul1">${notices.map((n) {
      final id = Uri.parse(n.url).queryParameters['wbnewsid'];
      return '<li class="clearfix">'
          '<a class="a1" href="content.jsp?urltype=news.NewsContentUrl'
          '&wbtreeid=1046&wbnewsid=$id">${n.title}</a></li>';
    }).join()}</ul>';

void main() {
  test('jwc notice urls are protected by unified auth', () {
    expect(
      shouldOpenCampusNoticeViaUnifiedAuth(
        'https://jwc.zjxu.edu.cn/content.jsp?id=1',
      ),
      isTrue,
    );
    expect(
      shouldOpenCampusNoticeViaUnifiedAuth(
        'https://www.zjxu.edu.cn/content.jsp?id=1',
      ),
      isFalse,
    );
    expect(shouldOpenCampusNoticeViaUnifiedAuth('not-a-url'), isFalse);
  });

  group('campus notice tab paging', () {
    late MockHttpClientAdapter adapter;
    late List<int> requestedPages;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await resetTestEnvironment();
      NoticeService.instance.debugReset();
      NoticeSyncStore.instance
        ..debugReset()
        ..debugReloadNoop = true
        ..debugInjectState(
          NoticeSyncSnapshot(
            snapshotIds: const {},
            inbox: [for (var i = 1; i <= 12; i++) _notice(i)],
            unreadIds: const {},
            pendingNotifyIds: const {},
            notifiedIds: const {},
            pendingBackfillPage: null,
            baselineBuilt: true,
          ),
        );
      adapter = MockHttpClientAdapter();
      requestedPages = [];
      adapter.register('GET', '/list.jsp', (options) async {
        final page =
            int.tryParse(options.uri.queryParameters['PAGENUM'] ?? '1') ?? 1;
        requestedPages.add(page);
        // 第 2 页与收件箱末尾重叠（11、12），用来验证按 id 去重。
        final content = switch (page) {
          2 => [_notice(11), _notice(12), _notice(13), _notice(14)],
          3 => [_notice(15)],
          _ => const <Notice>[],
        };
        return ResponseBody.fromString(_listHtml(content), 200);
      });
      NoticeService.instance.debugSetDio(
        Dio(BaseOptions(responseType: ResponseType.bytes))
          ..httpClientAdapter = adapter,
      );
    });

    tearDown(() {
      NoticeService.instance.debugReset();
      NoticeSyncStore.instance.debugReset();
    });

    testWidgets(
      'scrolling to the bottom loads older pages without duplicates',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: NotificationCenterPage()),
        );
        await tester.pumpAndSettle();

        final list = find.byType(Scrollable).first;
        await tester.dragUntilVisible(
          find.text('通知15', skipOffstage: false),
          list,
          const Offset(0, -300),
          maxIteration: 60,
        );
        await tester.pumpAndSettle();

        expect(find.text('通知15'), findsOneWidget);
        expect(find.text('通知13', skipOffstage: false), findsOneWidget);
        expect(find.text('通知12', skipOffstage: false), findsOneWidget);
        // 第 4 页返回空 → 停止；不会再继续请求。
        expect(requestedPages, [2, 3, 4]);
      },
    );
  });
}
