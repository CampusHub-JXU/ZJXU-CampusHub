import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jxu_campus_hub/app/routes.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../helpers/test_setup.dart';

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformInAppWebViewWidget(params);
  }
}

class _FakePlatformInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakePlatformInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError('Controller is not used by this test fake.');
  }

  @override
  void dispose() {}
}

Response<List<int>> _ok(String url) {
  return Response<List<int>>(
    data: utf8.encode('<html></html>'),
    requestOptions: RequestOptions(path: url),
    statusCode: 200,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  late GoRouter router;
  final resourceCalls = <String>[];

  setUp(() async {
    await resetTestEnvironment();
    resourceCalls.clear();
    // 资源预热会在 WebView 打开前同步业务 Cookie；测试里插件/文件 I/O
    // 无法完成，用钩子短路，避免 10 秒超时定时器悬挂。
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async {
          resourceCalls.add(url);
          return _ok(url);
        };
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/external-webview',
          name: 'external-webview',
          builder: buildExternalWebViewPage,
        ),
      ],
    );
  });

  tearDown(() {
    CasAuthBroker.debugGetResourceOverride = null;
    router.dispose();
  });

  Future<void> pumpRouter(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
  }

  testWidgets(
    'notice extra forwards warmUpAsResource and does not use resource as CAS service',
    (tester) async {
      const resource =
          'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl&wbnewsid=1';
      await pumpRouter(tester);
      router.pushNamed(
        'external-webview',
        extra: {
          'title': '通知详情',
          'url': resource,
          'requireUnifiedAuthProtection': true,
          'serviceUrl': resource,
          'loginDescription': '通知公告可直连访问，但需先完成统一认证',
          'warmUpAsResource': true,
          'showWebViewBottomBackButton': true,
        },
      );
      await tester.pump();
      await tester.pump();

      final page = tester.widget<UnifiedAuthProtectedWebViewPage>(
        find.byType(UnifiedAuthProtectedWebViewPage),
      );
      expect(page.warmUpAsResource, isTrue);
      expect(page.url, resource);
      expect(page.serviceUrl, UnifiedAuthService.defaultServiceUrl);
      expect(page.serviceUrl, isNot(resource));
      expect(resourceCalls, [resource]);
    },
  );

  testWidgets('registered service extra stays on CasSession path', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
    const service = 'https://newca.zjxu.edu.cn/casClient/login/ydd';
    await pumpRouter(tester);
    router.pushNamed(
      'external-webview',
      extra: {
        'title': '服务大厅',
        'url': service,
        'requireUnifiedAuthProtection': true,
        'serviceUrl': service,
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final page = tester.widget<UnifiedAuthProtectedWebViewPage>(
      find.byType(UnifiedAuthProtectedWebViewPage),
    );
    expect(page.warmUpAsResource, isFalse);
    expect(page.serviceUrl, service);
    expect(resourceCalls, isEmpty);
    expect(find.byType(WebViewPage), findsOneWidget);
  });
}
