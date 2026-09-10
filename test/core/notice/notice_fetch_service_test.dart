import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

const _listHtml = '''
<ul id="ul1">
  <li class="clearfix">
    <span class="fr"><a href="content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=10853" class="a2">[通知公告]</a>2026-04-08</span>
    <a href="content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=10853" class="fl a1">关于开展继续教育专项检查工作的通知new</a>
  </li>
  <li class="clearfix">
    <span class="fr"><a href="http://sjjx.zjxu.edu.cn/sjjx/shownews.aspx?ptype=js&newsno=1901" class="a2">[通知公告]</a>2026-03-30</span>
    <a href="http://sjjx.zjxu.edu.cn/sjjx/shownews.aspx?ptype=js&newsno=1901" class="fl a1">关于申报2026年嘉兴大学大学生科技竞赛项目的通知</a>
  </li>
</ul>
''';

const _loginHtml = '''
<html>
  <head><title>统一身份认证平台</title></head>
  <body>
    <form id="fm1">
      <input name="execution" />
    </form>
  </body>
</html>
''';

const _plainPageHtml = '''
<html>
  <head><title>通知公告</title></head>
  <body><p>站点改版占位页</p></body>
</html>
''';

NoticeService _serviceWith(MockHttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(responseType: ResponseType.bytes))
    ..httpClientAdapter = adapter;
  NoticeService.instance.debugSetDio(dio);
  return NoticeService.instance;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    NoticeService.instance.debugReset();
  });

  tearDown(() {
    NoticeService.instance.debugReset();
  });

  group('html parsing', () {
    test('parses jwc notice list html into notice items', () {
      final notices = parseJwcNoticeListHtml(_listHtml);

      expect(notices, hasLength(2));
      expect(notices.first.title, '关于开展继续教育专项检查工作的通知');
      expect(
        notices.first.url,
        'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=10853',
      );
      expect(notices.first.category, '通知公告');
      expect(notices.first.date, '2026-04-08');

      expect(
        notices.last.url,
        'http://sjjx.zjxu.edu.cn/sjjx/shownews.aspx?ptype=js&newsno=1901',
      );
      expect(notices.last.date, '2026-03-30');
    });

    test(
      'parses list page into date-descending order regardless of page order',
      () {
        // 教务处列表页存在置顶/补录混排（页面顺序 ≠ 时间序），解析层
        // 必须按发布日期倒序归位。
        const unorderedHtml = '''
<ul id="ul1">
  <li><a class="a1" href="content.jsp?urltype=news.NewsContentUrl&wbnewsid=1">旧通知</a><span class="fr">2026-03-01</span></li>
  <li><a class="a1" href="content.jsp?urltype=news.NewsContentUrl&wbnewsid=2">置顶旧通知</a><span class="fr">2026-01-15</span></li>
  <li><a class="a1" href="content.jsp?urltype=news.NewsContentUrl&wbnewsid=3">最新通知</a><span class="fr">2026-09-04</span></li>
  <li><a class="a1" href="content.jsp?urltype=news.NewsContentUrl&wbnewsid=4">无日期通知</a></li>
</ul>
''';
        final notices = parseJwcNoticeListHtml(unorderedHtml);

        expect(notices.map((n) => n.id), ['3', '1', '2', '4']);
      },
    );

    test('detects unified auth login html response', () {
      final response = Response<List<int>>(
        data: utf8.encode(_loginHtml),
        requestOptions: RequestOptions(
          path: 'https://jwc.zjxu.edu.cn/list.jsp',
        ),
      );

      expect(looksLikeNoticeResponseNeedsUnifiedAuth(response), isTrue);
    });

    test('does not treat normal notice page as unified auth login html', () {
      const pageHtml = '''
<html>
  <head><title>通知公告</title></head>
  <body>
    <ul id="ul1"><li><a class="a1" href="content.jsp?id=1">测试通知</a></li></ul>
  </body>
</html>
''';

      final response = Response<List<int>>(
        data: utf8.encode(pageHtml),
        requestOptions: RequestOptions(
          path: 'https://jwc.zjxu.edu.cn/list.jsp',
        ),
      );

      expect(looksLikeNoticeResponseNeedsUnifiedAuth(response), isFalse);
    });
  });

  group('notice id', () {
    test('prefers wbnewsid from detail url', () {
      const notice = Notice(
        title: 't',
        url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=10853',
        category: '通知公告',
      );
      expect(notice.id, '10853');
    });

    test('falls back to full url when wbnewsid missing', () {
      const notice = Notice(
        title: 't',
        url: 'https://jwc.zjxu.edu.cn/a.jsp?id=1',
        category: '通知公告',
      );
      expect(notice.id, 'https://jwc.zjxu.edu.cn/a.jsp?id=1');
    });

    test('json round-trip preserves fields', () {
      const notice = Notice(
        title: '标题',
        url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=1',
        category: '通知公告',
        date: '2026-04-08',
      );
      final decoded = Notice.fromJson(notice.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.id, notice.id);
      expect(decoded.title, notice.title);
      expect(decoded.date, notice.date);
    });
  });

  group('fetchNoticesRaw protocol', () {
    test('maps normal list page to ok', () async {
      final service = _serviceWith(
        MockHttpClientAdapter(
          handlers: {
            'GET /list.jsp': (_) async =>
                ResponseBody.fromString('<ul id="ul1"></ul>', 200),
          },
        ),
      );

      final result = await service.fetchNoticesRaw();
      expect(result.status, NoticeFetchStatus.ok);
      expect(result.notices, isEmpty);
    });

    test('maps login page with inactive session to authRequired', () async {
      final service = _serviceWith(
        MockHttpClientAdapter(
          handlers: {
            'GET /list.jsp': (_) async =>
                ResponseBody.fromString(_loginHtml, 200),
          },
        ),
      );

      final result = await service.fetchNoticesRaw();
      expect(result.status, NoticeFetchStatus.authRequired);
      expect(result.notices, isEmpty);
    });

    test('maps page without list structure to unavailable', () async {
      final service = _serviceWith(
        MockHttpClientAdapter(
          handlers: {
            'GET /list.jsp': (_) async =>
                ResponseBody.fromString(_plainPageHtml, 200),
          },
        ),
      );

      final result = await service.fetchNoticesRaw();
      expect(result.status, NoticeFetchStatus.unavailable);
    });

    test('never throws on transport failure', () async {
      final service = _serviceWith(MockHttpClientAdapter());

      final result = await service.fetchNoticesRaw();
      expect(
        result.status,
        anyOf(NoticeFetchStatus.authRequired, NoticeFetchStatus.unavailable),
      );
    });

    test('login form is authRequired; network cancel is unavailable', () async {
      final loginService = _serviceWith(
        MockHttpClientAdapter()..registerText('GET', '/list.jsp', _loginHtml),
      );
      expect(
        (await loginService.fetchNoticesRaw()).status,
        NoticeFetchStatus.authRequired,
      );

      NoticeService.instance.debugReset();
      final cancelToken = CancelToken();
      final pending = Completer<ResponseBody>();
      final networkService = _serviceWith(
        MockHttpClientAdapter()
          ..register('GET', '/list.jsp', (_) => pending.future),
      );
      final future = networkService.fetchNoticesRaw(cancelToken: cancelToken);
      cancelToken.cancel('offline');
      expect((await future).status, NoticeFetchStatus.unavailable);
      pending.complete(ResponseBody.fromString(_listHtml, 200));
    });
  });

  group('fetchNotices presentation path', () {
    test('ok result carries notices without cache fallback', () async {
      final service = _serviceWith(
        MockHttpClientAdapter(
          handlers: {
            'GET /list.jsp': (_) async =>
                ResponseBody.fromString(_listHtml, 200),
          },
        ),
      );

      final result = await service.fetchNotices();
      expect(result.failed, isFalse);
      expect(result.fromCache, isFalse);
      expect(result.authRequired, isFalse);
      expect(result.notices, hasLength(2));
    });

    test('auth failure without cache surfaces authRequired', () async {
      final service = _serviceWith(
        MockHttpClientAdapter(
          handlers: {
            'GET /list.jsp': (_) async =>
                ResponseBody.fromString(_loginHtml, 200),
          },
        ),
      );

      final result = await service.fetchNotices();
      expect(result.authRequired, isTrue);
      expect(result.failed, isFalse);
      expect(result.notices, isEmpty);
    });

    test('page without list structure without cache maps to failed', () async {
      final service = _serviceWith(
        MockHttpClientAdapter(
          handlers: {
            'GET /list.jsp': (_) async =>
                ResponseBody.fromString(_plainPageHtml, 200),
          },
        ),
      );

      final result = await service.fetchNotices();
      expect(result.failed, isTrue);
    });
  });
}
