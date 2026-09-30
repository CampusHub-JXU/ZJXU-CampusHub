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

const _html = '''
<div class="newsDetail"><div class="title">关于测试事项的通知</div>
<div class="leftInfo"><span class="newsInfo">发表时间：26-09-18 10:26:49</span></div>
<div id="vsb_content"><div class="v_news_content">
<p style="text-indent: 2em;">请各学院<strong>按时</strong>报送。</p>
<table><tr><td rowspan="2">合并</td><td>a</td></tr><tr><td>b</td></tr></table>
</div></div>
<ul><li><a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=7">附件1：申请表.docx</a></li></ul>
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

  Future<void> pump(WidgetTester tester) async {
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
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  testWidgets('renders parsed notice natively', (tester) async {
    stub(
      (url) async => Response(
        data: utf8.encode(_html),
        requestOptions: RequestOptions(path: url),
        statusCode: 200,
      ),
    );
    await pump(tester);

    expect(find.text('关于测试事项的通知'), findsOneWidget);
    expect(find.text('2026-09-18 10:26'), findsOneWidget);
    expect(find.textContaining('请各学院', findRichText: true), findsOneWidget);
    expect(find.text('附件1：申请表.docx'), findsOneWidget);

    // 合并单元格表格不硬画，引导原网页。
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
    stub(
      (url) async => Response(
        data: utf8.encode('<html><body>改版了</body></html>'),
        requestOptions: RequestOptions(path: url),
        statusCode: 200,
      ),
    );
    await pump(tester);
    expect(find.text('暂不支持原生阅读'), findsOneWidget);
    await tester.tap(find.text('查看原网页'));
    await tester.pumpAndSettle();
    expect(opened, [_url]);
  });
}
