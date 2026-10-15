import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/features/notification_center/campus_notice_site_search.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

/// Issue #63：站内搜索结果区不再套 `PlainListGroup` 大卡片。
///
/// 覆盖全部状态分支（加载成功 / 零结果 / 认证失效 / 网络不可用），确认无论
/// 走到哪条路径，子树里都不会残留圆角分组卡面。

/// 合成夹具：结构照博达 VSB `sousuo.jsp` 结果页（合成数据，非真实校园内容）。
String _page({String rows = '', String pager = ''}) =>
    '''
<html><body>
<select id="orderSelect"><option value="1">时间排序：是</option></select>
<table class=listFrame cellspacing=1>
$rows
</table>
$pager
</body></html>
''';

String _row(String href, String title, String date) =>
    '''
<div class="line"><table><tbody><tr>
<td><a class="fk-newsListTitle" href="$href">$title</a></td>
<td>$date</td>
</tr></tbody></table></div>
''';

void main() {
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

  Future<void> pumpSearch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusNoticeSiteSearch(
            query: '教材',
            excludeIds: const {},
            tileBuilder: (n) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(n.title),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 越过 500ms Debouncer。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  testWidgets('加载成功：结果无卡片包装，标题与总数保留', (tester) async {
    stub(
      (url) async => ok(
        url,
        _page(
          rows:
              _row(
                'content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=90001',
                '合成公告标题甲',
                '2026年08月29日',
              ) +
              _row(
                'content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=90002',
                '合成公告标题乙',
                '2026年08月28日',
              ),
          pager: '共有 2 条',
        ),
      ),
    );
    await pumpSearch(tester);

    expect(find.text('教务处全站'), findsOneWidget);
    expect(find.text('共 2 条'), findsOneWidget);
    expect(find.text('合成公告标题甲'), findsOneWidget);
    expect(find.text('合成公告标题乙'), findsOneWidget);
    expect(find.byType(PlainListGroup), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('零结果：空态提示无卡片包装', (tester) async {
    stub((url) async => ok(url, _page(pager: '共有 0 条')));
    await pumpSearch(tester);

    expect(find.text('没有找到相关通知'), findsOneWidget);
    expect(find.byType(PlainListGroup), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('认证失效：登录提示无卡片包装', (tester) async {
    stub((_) async => throw const CasAuthExpiredException());
    await pumpSearch(tester);

    expect(find.text('登录统一认证后可搜索全部通知'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '登录'), findsOneWidget);
    expect(find.byType(PlainListGroup), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网络不可用：重试提示无卡片包装', (tester) async {
    stub((_) async => throw StateError('boom'));
    await pumpSearch(tester);

    expect(find.text('全站搜索暂时不可用'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
    expect(find.byType(PlainListGroup), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
