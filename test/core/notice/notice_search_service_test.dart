import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/notice/notice_search_service.dart';

/// 合成夹具：结构照抓包确认的博达 VSB `sousuo.jsp` 结果页（非真实数据）。
String _page({String rows = '', String pager = ''}) =>
    '''
<html><body>
<select id="rangeSelect"><option value="0">检索范围：精确</option></select>
<select id="orderSelect"><option value="1">时间排序：是</option></select>
<table class=listFrame cellspacing=1><input type='hidden' name='newskeycode' value="教材">
$rows
</table>
$pager
</body></html>
''';

String _row(String href, String titleHtml, String date) =>
    '''
<div class="J_newsListLine line g_item"><table class="J_lineBody lineBody"><tbody><tr>
<td class="J_newsTitle newsTitle"><table width="100%"><tr>
<td align="left"><a class="fk-newsListTitle" href="$href" target="_blank">$titleHtml</a></td>
<td align="right"><span style="color: #888; font-size: 10pt;">$date</span></td>
</tr></table></td></tr></tbody></table></div>
''';

void main() {
  test('buildNoticeSearchUrl base64-encodes the UTF-8 keyword', () {
    final uri = Uri.parse(buildNoticeSearchUrl('教材', page: 3));
    expect(uri.host, 'jwc.zjxu.edu.cn');
    expect(uri.path, '/sousuo.jsp');
    expect(uri.queryParameters['newskeycode2'], '5pWZ5p2Q');
    expect(uri.queryParameters['range'], '0');
    expect(uri.queryParameters['order'], '1');
    expect(uri.queryParameters['currentnum'], '3');
  });

  group('parseNoticeSearchHtml', () {
    test('parses hits, dates, totals and strips keyword highlight', () {
      final result = parseNoticeSearchHtml(
        _page(
          rows:
              _row(
                'content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=10300',
                '2026-2027学年第一学期学生<span class="keywordfontcolor1">教材</span>发放通知',
                '2026年08月29日',
              ) +
              _row(
                'content.jsp?urltype=news.NewsContentUrl&wbtreeid=1004&wbnewsid=10523',
                '关于德育教材研究的通知 ',
                '2025年11月4日',
              ) +
              _row('https://evil.example/x', '外站链接', '2025年01月01日'),
          pager: '共有 329 条 首页 下一页 共有 33 页 当前第 1 页',
        ),
        page: 1,
      )!;
      expect(result.total, 329);
      expect(result.totalPages, 33);
      expect(result.hasMore, isTrue);
      expect(result.notices, hasLength(2), reason: '非 jwc 链接被丢弃');
      final first = result.notices.first;
      expect(first.title, '2026-2027学年第一学期学生教材发放通知');
      expect(first.date, '2026-08-29');
      expect(first.id, '10300');
      expect(
        first.url,
        'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=10300',
      );
      expect(result.notices[1].date, '2025-11-04');
    });

    test('zero-result page is a valid empty result', () {
      final result = parseNoticeSearchHtml(_page(), page: 1)!;
      expect(result.notices, isEmpty);
      expect(result.total, 0);
      expect(result.hasMore, isFalse);
    });

    test('unknown page structure returns null', () {
      expect(
        parseNoticeSearchHtml('<html><body>统一身份认证</body></html>', page: 1),
        isNull,
      );
    });
  });

  group('NoticeSearchService.search', () {
    tearDown(() => CasAuthBroker.debugGetResourceOverride = null);

    void stub(Future<Response<List<int>>> Function(String url) handler) {
      CasAuthBroker.debugGetResourceOverride = (
        url, {
        dio,
        needsLogin,
        cancelToken,
        Duration? timeout,
        deadline,
      }) => handler(url);
    }

    Response<List<int>> ok(String url, String body) => Response(
      data: utf8.encode(body),
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
    );

    test('empty keyword does not hit the network', () async {
      stub((_) => fail('should not fetch'));
      final result = await NoticeSearchService.instance.search('  ');
      expect(result, isA<NoticeSearchLoaded>());
    });

    test('maps auth expiry and unknown pages', () async {
      stub((_) async => throw const CasAuthExpiredException());
      expect(
        await NoticeSearchService.instance.search('教材'),
        isA<NoticeSearchAuthRequired>(),
      );
      stub((url) async => ok(url, '<html>改版</html>'));
      expect(
        await NoticeSearchService.instance.search('教材'),
        isA<NoticeSearchUnavailable>(),
      );
    });

    test('requests the resource URL for the given page', () async {
      String? requested;
      stub((url) async {
        requested = url;
        return ok(url, _page(pager: '共有 0 条'));
      });
      final result = await NoticeSearchService.instance.search('教材', page: 2);
      expect(result, isA<NoticeSearchLoaded>());
      expect(Uri.parse(requested!).queryParameters['currentnum'], '2');
    });
  });
}
