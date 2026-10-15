import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/features/notice/notice_detail_page.dart';

import '../../helpers/test_setup.dart';

const _url =
    'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=1';

/// 含真实合并单元格（`th` 表头 + `rowspan=2`）的合成详情页：结构照抓包确认的
/// 博达 VSB 模板（非真实公告内容）。
const _html = '''
<div class="newsDetail"><div class="title">关于测试事项的通知</div>
<div class="leftInfo"><span class="newsInfo">发表时间：26-09-18 10:26:49</span></div>
<div id="vsb_content"><div class="v_news_content">
<p style="text-indent: 2em;">请各学院<strong>按时</strong>报送。</p>
<table>
<tr><th>课程</th><th>学分</th></tr>
<tr><td rowspan="2">思想政治理论课</td><td>3</td></tr>
<tr><td>2</td></tr>
</table>
</div></div>
<ul><li><a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=7">附件1：申请表.docx</a></li></ul>
</div>
''';

/// 首行是 td 表头、首列是窄「序号」列的常见教务表格。
const _htmlWidths = '''
<div class="newsDetail"><div class="title">关于测试事项的通知</div>
<div class="leftInfo"><span class="newsInfo">发表时间：26-09-18 10:26:49</span></div>
<div id="vsb_content"><div class="v_news_content">
<table>
<tr><td>序号</td><td>事项说明</td></tr>
<tr><td>1</td><td>各学院请于本周五前将汇总表报送教务处教学运行科，逾期不予受理</td></tr>
</table>
</div></div>
</div>
''';

/// 单元格里嵌表格：原生无法忠实还原，应回退原网页。
const _htmlNested = '''
<div class="newsDetail"><div class="title">关于测试事项的通知</div>
<div class="leftInfo"><span class="newsInfo">发表时间：26-09-18 10:26:49</span></div>
<div id="vsb_content"><div class="v_news_content">
<table><tr><td>外层</td><td><table><tr><td>内层</td></tr></table></td></tr></table>
</div></div>
</div>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> opened;

  setUp(() async {
    await resetTestEnvironment();
    opened = [];
  });

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

  void stubHtml(String html) {
    stub(
      (url) async => Response(
        data: utf8.encode(html),
        requestOptions: RequestOptions(path: url),
        statusCode: 200,
      ),
    );
  }

  Future<void> pump(WidgetTester tester, {ThemeData? theme}) async {
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (_, _) =>
              const NoticeDetailPage(title: '关于测试事项的通知', url: _url),
        ),
        GoRoute(
          path: '/external-webview',
          name: 'external-webview',
          builder: (_, state) {
            opened.add((state.extra as Map)['url'] as String);
            return const Scaffold(body: Text('original'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router, theme: theme),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders merged-cell tables with real data and headers', (
    tester,
  ) async {
    stubHtml(_html);
    await pump(tester);

    expect(find.text('关于测试事项的通知'), findsOneWidget);
    expect(find.text('2026-09-18 10:26'), findsOneWidget);
    expect(find.textContaining('请各学院', findRichText: true), findsOneWidget);
    expect(find.text('附件1：申请表.docx'), findsOneWidget);

    // 合并单元格真实渲染，不再出现旧占位提示。
    expect(find.textContaining('思想政治理论课', findRichText: true), findsOneWidget);
    expect(find.textContaining('课程', findRichText: true), findsOneWidget);
    expect(find.textContaining('学分', findRichText: true), findsOneWidget);
    expect(find.text('此处是含合并单元格的表格'), findsNothing);
    expect(find.text('这个表格结构过于复杂，无法在应用内完整还原'), findsNothing);

    // th 表头语义。
    expect(
      find.ancestor(
        of: find.textContaining('课程', findRichText: true),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.header == true,
        ),
      ),
      findsWidgets,
    );

    // 通过菜单打开原网页。
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看原网页'));
    await tester.pumpAndSettle();
    expect(opened, [_url]);
  });

  testWidgets('merged table scrolls locally on a 360dp narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    stubHtml(_html);
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsOneWidget,
    );
    // 正文仍在，未被整页水平溢出挤出。
    expect(find.textContaining('思想政治理论课', findRichText: true), findsOneWidget);
  });

  testWidgets('merged table renders in dark theme', (tester) async {
    stubHtml(_html);
    await pump(tester, theme: ThemeData.dark());

    expect(tester.takeException(), isNull);
    expect(find.textContaining('思想政治理论课', findRichText: true), findsOneWidget);
  });

  testWidgets('merged table renders at 2x text scale without overflow', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    stubHtml(_html);
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('思想政治理论课', findRichText: true), findsOneWidget);
  });

  testWidgets('narrow index column is narrower than the long text column', (
    tester,
  ) async {
    stubHtml(_htmlWidths);
    await pump(tester);

    final index = tester.getRect(find.text('序号'));
    final desc = tester.getRect(find.text('事项说明'));
    // 「事项说明」列从「序号」列右缘开始；序号列明显窄于说明列。
    final indexColumnWidth = desc.left - index.left;
    expect(indexColumnWidth, lessThan(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested tables fall back to the original page', (tester) async {
    stubHtml(_htmlNested);
    await pump(tester);

    expect(find.text('这个表格结构过于复杂，无法在应用内完整还原'), findsOneWidget);
    await tester.tap(find.text('查看原网页'));
    await tester.pumpAndSettle();
    expect(opened, [_url]);
  });

  testWidgets('auth expiry shows the login prompt', (tester) async {
    stub((_) async => throw const CasAuthExpiredException());
    await pump(tester);
    expect(find.text('登录后查看通知'), findsOneWidget);
    expect(find.text('登录统一认证'), findsOneWidget);
  });

  testWidgets('unknown page structure falls back to the original page', (
    tester,
  ) async {
    stubHtml('<html><body>改版了</body></html>');
    await pump(tester);
    expect(find.text('暂不支持原生阅读'), findsOneWidget);
    await tester.tap(find.text('查看原网页'));
    await tester.pumpAndSettle();
    expect(opened, [_url]);
  });
}
