import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/maintenance_window.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../../helpers/test_setup.dart';
import '../../helpers/fake_inappwebview.dart';

const _resource = 'https://jwc.zjxu.edu.cn/list.jsp';
const _cmsCallback =
    'http://jwc.zjxu.edu.cn/system/resource/code/auth/clogin.jsp?owner=1062118769';
final _casLogin = Uri.https('newca.zjxu.edu.cn', '/cas/login', {
  'service': _cmsCallback,
}).toString();
const _proxiedCasLogin =
    'https://webvpn.zjxu.edu.cn/https/'
    '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
    '/cas/login?service=https%3A%2F%2Fjwc.zjxu.edu.cn%2Flist.jsp';

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
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform(
      cookieMode: FakeCookieManagerMode.acceptOnly,
    );
  });

  setUp(() async {
    await resetTestEnvironment();
    debugMaintenanceNowOverride = () => DateTime(2026, 11, 15, 10, 0);
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};
  });

  tearDown(() {
    debugMaintenanceNowOverride = null;
    CasAuthBroker.debugGetResourceOverride = null;
  });

  testWidgets('login form asks for auth without global logout', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async {
          throw const CasAuthExpiredException();
        };

    await tester.pumpWidget(
      const MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '通知',
          url: _resource,
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  testWidgets('network unknown keeps session and offers retry', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.connectionError,
          );
        };
    await tester.pumpWidget(
      const MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '通知',
          url: _resource,
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('暂时无法连接服务，请切换网络后重试'), findsOneWidget);
    expect(find.text('需要统一认证后继续'), findsNothing);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  testWidgets('network unknown without session guides login instead of error', (
    tester,
  ) async {
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.connectionError,
          );
        };
    await tester.pumpWidget(
      const MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '通知',
          url: _resource,
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 预热网络失败但本地无会话：给原生登录引导，而不是「切换网络」错误页。
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(find.text('暂时无法连接服务，请切换网络后重试'), findsNothing);
  });

  testWidgets('webvpn-proxied CAS bounce rewarms without showing the H5 page', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    final urls = <String>[];
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async {
          urls.add(url);
          return _ok(url);
        };

    final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          key: key,
          title: '通知',
          url: _resource,
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(WebViewPage), findsOneWidget);

    await key.currentState!.debugOnCasLoginEntry(_proxiedCasLogin);
    await tester.pump();
    await tester.pump();

    expect(urls, [_resource, _resource]);
    expect(find.byType(WebViewPage), findsOneWidget);
    expect(key.currentState!.debugWebViewUrl, _resource);
    expect(key.currentState!.debugWebViewUrl, isNot(contains('/cas/login')));
    expect(find.text('需要统一认证后继续'), findsNothing);
  });

  testWidgets('dispose cancels warmup and ignores a late success', (
    tester,
  ) async {
    final pending = Completer<Response<List<int>>>();
    CancelToken? token;
    CasAuthBroker.debugGetResourceOverride =
        (url, {dio, needsLogin, cancelToken, Duration? timeout, deadline}) {
          token = cancelToken;
          return pending.future;
        };

    await tester.pumpWidget(
      const MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '通知',
          url: _resource,
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    expect(token, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(token!.isCancelled, isTrue);

    pending.complete(_ok(_resource));
    await tester.pump();
    expect(find.byType(UnifiedAuthProtectedWebViewPage), findsNothing);
    expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
  });

  testWidgets('refresh cancels the previous warmup generation', (tester) async {
    final first = Completer<Response<List<int>>>();
    final tokens = <CancelToken?>[];
    var calls = 0;
    CasAuthBroker.debugGetResourceOverride =
        (url, {dio, needsLogin, cancelToken, Duration? timeout, deadline}) {
          tokens.add(cancelToken);
          calls++;
          if (calls == 1) return first.future;
          return Future.value(_ok(url));
        };

    final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          key: key,
          title: '通知',
          url: _resource,
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    final generation = key.currentState!.debugResourceWarmUpGeneration;

    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          key: key,
          title: '通知',
          url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=2',
          warmUpAsResource: true,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    expect(tokens.first!.isCancelled, isTrue);
    expect(
      key.currentState!.debugResourceWarmUpGeneration,
      greaterThan(generation),
    );

    first.complete(_ok(_resource));
    await tester.pump();
    expect(
      key.currentState!.debugWebViewUrl,
      'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=2',
    );
  });

  testWidgets(
    'CMS CAS bounce rewarms the resource and does not globally log out',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2024001',
      );
      final urls = <String>[];
      CasAuthBroker.debugGetResourceOverride =
          (
            url, {
            dio,
            needsLogin,
            cancelToken,
            Duration? timeout,
            deadline,
          }) async {
            urls.add(url);
            return _ok(url);
          };

      final key = GlobalKey<UnifiedAuthProtectedWebViewPageState>();
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedAuthProtectedWebViewPage(
            key: key,
            title: '通知',
            url: _resource,
            warmUpAsResource: true,
            autoPromptLogin: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(urls, [_resource]);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);

      await key.currentState!.debugOnCasLoginEntry(_casLogin);
      await tester.pump();
      await tester.pump();

      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(urls, [_resource, _resource]);
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(key.currentState!.debugWebViewUrl, _resource);
      expect(key.currentState!.debugWebViewUrl, isNot(contains('clogin.jsp')));
      expect(find.text('需要统一认证后继续'), findsNothing);
    },
  );

  testWidgets('registered service extra does not use getResource', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
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
          return _ok(url);
        };

    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '服务大厅',
          url: UnifiedAuthService.defaultServiceUrl,
          serviceUrl: UnifiedAuthService.defaultServiceUrl,
          autoPromptLogin: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(resourceCalls, 0);
    expect(find.byType(WebViewPage), findsOneWidget);
  });
}
