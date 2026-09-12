import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_page.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

import '../../helpers/test_setup.dart';

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformInAppWebViewWidget(params);
  }

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) {
    return _FakePlatformCookieManager(params);
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

class _FakePlatformCookieManager extends PlatformCookieManager {
  _FakePlatformCookieManager(super.params) : super.implementation();

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
    return true;
  }
}

void main() {
  setUpAll(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  setUp(() async {
    await resetTestEnvironment();
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride =
        (_,) async {};
    CasAuthBroker.debugGetResourceOverride =
        (url, {dio, needsLogin, cancelToken, Duration? timeout, deadline}) async {
          return Response<List<int>>(
            data: <int>[],
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
          );
        };
  });

  tearDown(() {
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = null;
    CasAuthBroker.debugGetResourceOverride = null;
  });

  testWidgets('体测成绩经 WebVPN 资源预热加载且不注入钉钉模拟', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PhysicalTestPage()));
    await tester.pumpAndSettle();

    final page = tester.widget<UnifiedAuthProtectedWebViewPage>(
      find.byType(UnifiedAuthProtectedWebViewPage),
    );
    expect(page.title, PhysicalTestPage.titleText);
    expect(page.url, PhysicalTestPage.homeUrl);
    expect(page.warmUpAsResource, isTrue);
    // 站点 SSO 面向钉钉工作台，注入模拟会拿到 errorCode 3。
    expect(page.emulateDingTalkEnvironment, isFalse);
    expect(page.showWebViewBottomBackButton, isTrue);
  });
}
