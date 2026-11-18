import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../../helpers/test_setup.dart';
import '../../helpers/fake_inappwebview.dart';

const _businessUrl =
    'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5';
const _resource = 'https://jwc.zjxu.edu.cn/list.jsp';
const _directCasUrl =
    'https://newca.zjxu.edu.cn/cas/login'
    '?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn';
const _proxiedCasUrl =
    'https://webvpn.zjxu.edu.cn/https/'
    '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
    '/cas/login?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn';

/// 读取当前 WebViewPage 实际绑定到平台层的导航回调。
PlatformInAppWebViewWidgetCreationParams _boundParams(WidgetTester tester) =>
    boundInAppWebViewParams(tester);

InAppWebViewController _testController() {
  return InAppWebViewController.fromPlatformCreationParams(
    params: const PlatformInAppWebViewControllerCreationParams(
      id: 'callback-test-controller',
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

Future<void> _pumpUntilSettled(WidgetTester tester) {
  return tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform(
      cookieMode: FakeCookieManagerMode.acceptOnly,
      withController: true,
    );
  });

  setUp(() async {
    await resetTestEnvironment();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};
  });

  tearDown(() {
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = null;
    CasAuthBroker.debugGetResourceOverride = null;
    UnifiedAuthService.instance.debugReset();
  });

  testWidgets('direct CAS navigation is cancelled and stays on native auth', (
    tester,
  ) async {
    var prepareCalls = 0;
    final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          key: key,
          title: '校园卡账单',
          url: _businessUrl,
          serviceUrl: CasService.campusCardStatus.serviceUrl,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async {
            prepareCalls++;
            if (prepareCalls == 1) return _businessUrl;
            throw const CasAuthExpiredException();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(find.byType(InAppWebView), findsOneWidget);

    final policy = await _invokeShouldOverrideUrlLoading(tester, _directCasUrl);
    expect(policy, NavigationActionPolicy.CANCEL);

    await _pumpUntilSettled(tester);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(find.text('一键填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
    expect(key.currentState!.debugWebViewUrl, _businessUrl);
  });

  testWidgets('webvpn-proxied CAS navigation is cancelled as well', (
    tester,
  ) async {
    var prepareCalls = 0;
    final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          key: key,
          title: '校园卡账单',
          url: _businessUrl,
          serviceUrl: CasService.campusCardStatus.serviceUrl,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async {
            prepareCalls++;
            return _businessUrl;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(prepareCalls, 1);

    final policy = await _invokeShouldOverrideUrlLoading(
      tester,
      _proxiedCasUrl,
    );
    expect(policy, NavigationActionPolicy.CANCEL);

    await _pumpUntilSettled(tester);
    // 代理 CAS 被识别为登录入口：取消导航并触发重新准备，绝不把 CAS 挂进 WebView。
    expect(prepareCalls, 2);
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(key.currentState!.debugWebViewUrl, _businessUrl);
    expect(key.currentState!.debugWebViewUrl, isNot(contains('/cas/login')));
    expect(find.text('一键填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
  });

  testWidgets(
    'two resource CAS bounces terminate bounded and keep the global session',
    (tester) async {
      final warmed = <String>[];
      CasAuthBroker.debugGetResourceOverride =
          (
            url, {
            dio,
            needsLogin,
            cancelToken,
            Duration? timeout,
            deadline,
          }) async {
            warmed.add(url);
            return Response<List<int>>(
              data: utf8.encode('<html></html>'),
              requestOptions: RequestOptions(path: url),
              statusCode: 200,
            );
          };

      final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedAuthProtectedWebViewPage(
            key: key,
            title: '通知',
            url: _resource,
            warmUpAsResource: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(warmed, [_resource]);

      expect(
        await _invokeShouldOverrideUrlLoading(tester, _proxiedCasUrl),
        NavigationActionPolicy.CANCEL,
      );
      await _pumpUntilSettled(tester);
      // 第一次 bounce：重新预热后仍以资源页恢复。
      expect(warmed, [_resource, _resource]);
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(key.currentState!.debugWebViewUrl, _resource);

      expect(
        await _invokeShouldOverrideUrlLoading(tester, _proxiedCasUrl),
        NavigationActionPolicy.CANCEL,
      );
      await _pumpUntilSettled(tester);

      // 第二次 bounce 有界终止：不再预热、不再挂 CAS、不自动弹登录框。
      expect(warmed, [_resource, _resource]);
      expect(find.byType(WebViewPage), findsNothing);
      expect(find.byType(InAppWebView), findsNothing);
      expect(find.byType(LoginShell), findsNothing);
      expect(find.text('需要统一认证后继续'), findsOneWidget);
      expect(key.currentState!.debugWebViewUrl, _resource);
      // 资源 bounce 不得清全局统一认证会话。
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    },
  );

  testWidgets('zhengfang quick fill stays and disappears on CAS navigation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WebViewPage(
          title: '教务系统',
          url: 'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html',
          enableLoginQuickFill: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('教务快速填充'), findsOneWidget);
    expect(find.text('一卡通快速填充'), findsNothing);

    // 模拟 WebView 实际导航到统一认证 CAS 页：教务快速填充必须消失，
    // 且全程不出现「一卡通快速填充」。
    _boundParams(tester).onLoadStart!(_testController(), WebUri(_directCasUrl));
    await tester.pump();
    await tester.pump();

    expect(find.text('教务快速填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
    expect(find.text('一键填充'), findsNothing);
  });

  testWidgets('oauth/forward landing does not re-arm the one-retry contract', (
    tester,
  ) async {
    var prepareCalls = 0;
    final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          key: key,
          title: '校园卡账单',
          url: _businessUrl,
          serviceUrl: CasService.campusCardStatus.serviceUrl,
          preserveSessionOnAuthBounce: true,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async {
            prepareCalls++;
            return _businessUrl;
          },
        ),
      ),
    );
    await _pumpUntilSettled(tester);
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(prepareCalls, 1);

    // 第一次 CAS bounce：重跑 prepare 后恢复业务入口，进入重试中状态。
    expect(
      await _invokeShouldOverrideUrlLoading(tester, _directCasUrl),
      NavigationActionPolicy.CANCEL,
    );
    await _pumpUntilSettled(tester);
    expect(prepareCalls, 2);
    expect(find.byType(WebViewPage), findsOneWidget);

    // SSO 中间跳转页落地（oauth/forward）：既非 CAS 登录入口也非业务页，
    // 不得重置 bounce 计数——否则「一次自动重试」被无限重新武装。
    final loadStop = _boundParams(tester).onLoadStop;
    expect(loadStop, isNotNull);
    loadStop!(
      _testController(),
      WebUri('https://newca.zjxu.edu.cn/cas/oauth/forward/st-token'),
    );
    await tester.pump();
    await tester.pump();

    // 第二次 bounce：有界终止——不再重跑 prepare，停在原生认证视图。
    expect(
      await _invokeShouldOverrideUrlLoading(tester, _directCasUrl),
      NavigationActionPolicy.CANCEL,
    );
    await _pumpUntilSettled(tester);
    expect(prepareCalls, 2);
    expect(find.byType(WebViewPage), findsNothing);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    // preserveSessionOnAuthBounce：全局会话不被清。
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  testWidgets(
    'ordinary business landings still re-arm the one-retry contract',
    (tester) async {
      var prepareCalls = 0;
      final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedAuthProtectedWebViewPage(
            key: key,
            title: '校园卡账单',
            url: _businessUrl,
            serviceUrl: CasService.campusCardStatus.serviceUrl,
            autoPromptLogin: false,
            prepareAuthenticatedUrl: () async {
              prepareCalls++;
              return _businessUrl;
            },
          ),
        ),
      );
      await _pumpUntilSettled(tester);
      expect(prepareCalls, 1);

      expect(
        await _invokeShouldOverrideUrlLoading(tester, _directCasUrl),
        NavigationActionPolicy.CANCEL,
      );
      await _pumpUntilSettled(tester);
      expect(prepareCalls, 2);

      // 普通业务页落地是有效进展：bounce 计数归零（既有行为保持不变）。
      final loadStop = _boundParams(tester).onLoadStop;
      expect(loadStop, isNotNull);
      loadStop!(_testController(), WebUri(_businessUrl));
      await tester.pump();
      await tester.pump();

      // 再次 bounce 仍允许自动重试一次：业务落地重新武装了重试契约。
      expect(
        await _invokeShouldOverrideUrlLoading(tester, _directCasUrl),
        NavigationActionPolicy.CANCEL,
      );
      await _pumpUntilSettled(tester);
      expect(prepareCalls, 3);
      expect(find.byType(WebViewPage), findsOneWidget);
    },
  );
}
