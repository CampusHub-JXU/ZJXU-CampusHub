import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/library/library_page.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../../helpers/test_setup.dart';

String get _proxiedSsoEntry => ZhengfangAuth.instance.buildWebVpnProxyUrl(
  CasService.librarySso.serviceUrl,
);

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformInAppWebViewWidget(params);
  }

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) {
    return _FakePlatformInAppWebViewController(params);
  }

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) {
    return _FakePlatformCookieManager(params);
  }
}

class _FakePlatformInAppWebViewController
    extends PlatformInAppWebViewController {
  _FakePlatformInAppWebViewController(super.params) : super.implementation();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class _FakePlatformCookieManager extends PlatformCookieManager {
  _FakePlatformCookieManager(super.params) : super.implementation();

  final Map<String, Cookie> _cookies = {};

  @override
  Future<bool> setCookie({
    required WebUri url,
    required String name,
    required String value,
    String path = '/',
    String? domain,
    int? expiresDate,
    int? maxAge,
    bool? isSecure,
    bool? isHttpOnly,
    HTTPCookieSameSitePolicy? sameSite,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    _cookies['${url.host}|${domain ?? ''}|$path|$name'] = Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path,
    );
    return true;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    return _cookies.values.toList(growable: false);
  }

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    _cookies.remove('${url.host}|${domain ?? ''}|$path|$name');
    return true;
  }
}

/// 网关登录页请求探针：把 `realUri` 改写成非登录路径，模拟已认证门户。
class _WebVpnPortalAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    options.path = 'https://webvpn.zjxu.edu.cn/user/index';
    return ResponseBody.fromString(
      '<html><body>webvpn portal</body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 读取当前 WebViewPage 实际绑定到平台层的导航回调。
PlatformInAppWebViewWidgetCreationParams _boundParams(WidgetTester tester) {
  final webView = tester.widget<InAppWebView>(find.byType(InAppWebView));
  final platform = webView.platform;
  expect(
    platform,
    isA<_FakePlatformInAppWebViewWidget>(),
    reason: '测试必须运行在 fake InAppWebView 平台上',
  );
  return (platform as _FakePlatformInAppWebViewWidget).params;
}

InAppWebViewController _testController() {
  return InAppWebViewController.fromPlatformCreationParams(
    params: const PlatformInAppWebViewControllerCreationParams(
      id: 'library-cas-navigation-test',
    ),
  );
}

NavigationAction _navigationAction(String url) {
  return NavigationAction(
    request: URLRequest(url: WebUri(url)),
    isForMainFrame: true,
  );
}

/// 模拟平台层真实回调：WebViewPage.shouldOverrideUrlLoading → 受保护页包装。
Future<NavigationActionPolicy?> _invokeShouldOverrideUrlLoading(
  WidgetTester tester,
  String url,
) {
  final callback = _boundParams(tester).shouldOverrideUrlLoading;
  expect(
    callback,
    isNotNull,
    reason: 'WebViewPage 必须把 shouldOverrideUrlLoading 绑定到平台层',
  );
  return callback!(_testController(), _navigationAction(url));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  setUp(() {
    LibraryPage.debugPrepareEntryOverride = null;
  });

  tearDown(() {
    LibraryPage.debugPrepareEntryOverride = null;
    CasAuthBroker.debugGetResourceOverride = null;
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = null;
    UnifiedAuthService.instance.debugReset();
  });

  testWidgets('library page uses dedicated unified auth entry', (tester) async {
    LibraryPage.debugPrepareEntryOverride = () async => _proxiedSsoEntry;
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));

    final page = tester.widget<UnifiedAuthProtectedWebViewPage>(
      find.byType(UnifiedAuthProtectedWebViewPage),
    );

    expect(page.title, '图书馆');
    expect(page.url, 'https://libapp.zjxu.edu.cn/');
    expect(
      page.serviceUrl,
      'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
    );
    expect(page.loginDescription, '图书馆经 WebVPN 访问，请先完成统一认证登录');
    expect(page.prepareAuthenticatedUrl, isNotNull);
    // prepare 已确认过主会话，业务 bounce 不得再清全局统一认证会话。
    expect(page.preserveSessionOnAuthBounce, isTrue);
    expect(page.onNavigationRequest, isNotNull);
    expect(page.showWebViewBottomBackButton, isTrue);
    // 关闭钉钉模拟：CAS oauth/forward 不再被注入的 dd mock 劫持。
    expect(page.emulateDingTalkEnvironment, isFalse);
  });

  testWidgets('图书馆 WebView 打开 CAS 入口且不启用任何快速填充', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    LibraryPage.debugPrepareEntryOverride = () async => _proxiedSsoEntry;
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};

    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final webView = tester.widget<WebViewPage>(find.byType(WebViewPage));
    // 入口是注册的 CAS service（经 WebVPN 代理），不是站点资源根。
    expect(webView.url, _proxiedSsoEntry);
    // 不提供「一卡通快速填充」，也不模拟钉钉环境。
    expect(webView.enableLoginQuickFill, isFalse);
    expect(webView.emulateDingTalkEnvironment, isFalse);
  });

  testWidgets('CAS 登录页导航被取消，WebView 不渲染 CAS H5/快速填充', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    LibraryPage.debugPrepareEntryOverride = () async => _proxiedSsoEntry;
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};

    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();
    expect(find.byType(WebViewPage), findsOneWidget);

    final policy = await _invokeShouldOverrideUrlLoading(
      tester,
      'https://newca.zjxu.edu.cn/cas/login?service='
      'https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing',
    );
    expect(policy, NavigationActionPolicy.CANCEL);
    await tester.pumpAndSettle();

    // CAS 登录 H5 绝不挂进图书馆 WebView；页面全程没有任何快速填充入口。
    expect(find.byType(InAppWebView), findsOneWidget);
    final state = tester.state<UnifiedAuthProtectedWebViewPageState>(
      find.byType(UnifiedAuthProtectedWebViewPage),
    );
    expect(state.debugWebViewUrl, _proxiedSsoEntry);
    expect(state.debugWebViewUrl, isNot(contains('/cas/login')));
    expect(find.text('一键填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
    expect(find.text('教务快速填充'), findsNothing);
  });

  testWidgets('prepare 完成前不挂 WebView，成功后打开业务入口', (tester) async {
    final pending = Completer<String>();
    LibraryPage.debugPrepareEntryOverride = () => pending.future;

    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pump();

    // 认证准备没有结果前只显示加载态，绝不先挂 CAS/业务 WebView。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);

    pending.complete(_proxiedSsoEntry);
    await tester.pump();
    await tester.pump();

    final webView = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(webView.url, _proxiedSsoEntry);
    expect(webView.enableLoginQuickFill, isFalse);
  });

  testWidgets('prepare 明确失效停在原生认证视图，不挂 CAS H5/快速填充', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '图书馆',
          url: LibraryPage.libraryUrl,
          serviceUrl: CasService.librarySso.serviceUrl,
          loginDescription: LibraryPage.authLoginDescription,
          preserveSessionOnAuthBounce: true,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async =>
              throw const CasAuthExpiredException(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);
    expect(find.text('一键填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
    expect(find.text('教务快速填充'), findsNothing);
  });

  testWidgets('prepare 网络未知给重试错误页，不挂 CAS H5', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '图书馆',
          url: LibraryPage.libraryUrl,
          serviceUrl: CasService.librarySso.serviceUrl,
          preserveSessionOnAuthBounce: true,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async =>
              throw TimeoutException('图书馆认证暂时无法连接'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('暂时无法连接服务，请切换网络后重试'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  testWidgets('图书馆业务 CAS bounce 有界且保留全局会话', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};
    var prepareCalls = 0;
    LibraryPage.debugPrepareEntryOverride = () async {
      prepareCalls++;
      return _proxiedSsoEntry;
    };

    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pump();
    await tester.pump();
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(prepareCalls, 1);

    const casLoginUrl =
        'https://newca.zjxu.edu.cn/cas/login?service='
        'https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing';

    expect(
      await _invokeShouldOverrideUrlLoading(tester, casLoginUrl),
      NavigationActionPolicy.CANCEL,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 第一次 bounce：重跑 prepare 后仍以业务入口恢复，不清全局会话。
    expect(prepareCalls, 2);
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);

    expect(
      await _invokeShouldOverrideUrlLoading(tester, casLoginUrl),
      NavigationActionPolicy.CANCEL,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 第二次 bounce 有界终止：不再 prepare、不挂 CAS、不改全局会话。
    expect(prepareCalls, 2);
    expect(find.byType(WebViewPage), findsNothing);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  group('prepareEntry 认证链路', () {
    late Directory cookies;

    setUp(() async {
      await resetTestEnvironment();
      cookies = await Directory.systemTemp.createTemp('library_entry_');
      DioClient.instance.debugCookieDirectoryPathProvider = (folder) async =>
          '${cookies.path}/$folder/';
      await DioClient.instance.ensureInitialized();
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2024001',
      );
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;
      ConnectModeResolver.instance.targetDirectReachabilityChecker = (
        _,
      ) async => true;
      ConnectModeResolver.instance.webVpnReachabilityChecker = () async => true;
    });

    tearDown(() async {
      await cookies.delete(recursive: true);
    });

    test('复用注册 CAS service，预热业务会话并在进入 WebView 前同步 Cookie', () async {
      final validatedServices = <String>[];
      UnifiedAuthService.instance.debugSessionValidator = (url) async {
        validatedServices.add(url);
        return true;
      };
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          _WebVpnPortalAdapter();
      final synced = <String>[];
      UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride =
          (url) async {
            synced.add(url);
          };
      var resourceCalls = 0;
      CasAuthBroker.debugGetResourceOverride =
          (
            url, {
            dio,
            needsLogin,
            cancelToken,
            Duration? timeout,
            deadline,
          }) async {
            resourceCalls++;
            return Response<List<int>>(
              data: utf8.encode('<html></html>'),
              requestOptions: RequestOptions(path: url),
              statusCode: 200,
            );
          };

      final url = await LibraryPage.prepareEntry();

      // CasSession 校验的是注册 service，不是站点资源 URL。
      expect(validatedServices, <String>[
        ZhengfangAuth.webVpnGatewayServiceUrl,
        CasService.librarySso.serviceUrl,
      ]);
      expect(validatedServices, isNot(contains(LibraryPage.libraryUrl)));
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.webVpn);
      // WebView 打开的是 WebVPN 代理后的 CAS 入口。
      expect(url, _proxiedSsoEntry);
      // service URL 是 ticket 消费者而不是业务资源：业务会话由 ensure 的
      // ticket 回调建立，绝不再对它跑一次 getResource（真实日志里那次
      // 「统一认证登录已失效」误判的来源）。
      expect(resourceCalls, 0);
      // ensure 成功后 Cookie 必须已同步，才把 URL 交给 WebView。
      expect(synced, isNotEmpty);
      expect(synced.last, url);
    });

    test('ensure 明确失效抛 CasAuthExpiredException，不调用 getResource', () async {
      UnifiedAuthService.instance.debugSessionValidator = (url) async =>
          url != CasService.librarySso.serviceUrl;
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          _WebVpnPortalAdapter();
      var resourceCalls = 0;
      CasAuthBroker.debugGetResourceOverride =
          (
            url, {
            dio,
            needsLogin,
            cancelToken,
            Duration? timeout,
            deadline,
          }) async {
            resourceCalls++;
            return Response<List<int>>(
              data: utf8.encode('<html></html>'),
              requestOptions: RequestOptions(path: url),
              statusCode: 200,
            );
          };

      await expectLater(
        LibraryPage.prepareEntry(),
        throwsA(isA<CasAuthExpiredException>()),
      );
      // 统一认证明确失效：给原生登录引导，不交给 WebView 继续 SSO。
      expect(resourceCalls, 0);
    });

    test('ensure 网络未知抛 TimeoutException，保留主会话且不调用 getResource', () async {
      UnifiedAuthService.instance.debugSessionValidator = (url) async =>
          url == CasService.librarySso.serviceUrl ? null : true;
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          _WebVpnPortalAdapter();
      var resourceCalls = 0;
      CasAuthBroker.debugGetResourceOverride =
          (
            url, {
            dio,
            needsLogin,
            cancelToken,
            Duration? timeout,
            deadline,
          }) async {
            resourceCalls++;
            return Response<List<int>>(
              data: utf8.encode('<html></html>'),
              requestOptions: RequestOptions(path: url),
              statusCode: 200,
            );
          };

      await expectLater(
        LibraryPage.prepareEntry(),
        throwsA(isA<TimeoutException>()),
      );
      // 网络未知不是登录过期：不得清全局会话。
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(resourceCalls, 0);
    });
  });
}
