import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试替身 CookieManager 的能力档位。
///
/// 档位刻意保持三档：「不提供」与「只接受写入」会让生产代码在读 Cookie 时
/// 走不同分支（严格同步路径对异常 fail closed），不能随意合并。
enum FakeCookieManagerMode {
  /// 不覆盖 `createPlatformCookieManager`，保持平台接口默认行为。
  unsupported,

  /// 只实现 `setCookie`（恒返回 true），读/删仍走平台接口默认行为。
  acceptOnly,

  /// 内存 Cookie 罐：set / get / delete 可往返，`getCookies` 不按 URL 过滤。
  inMemory,
}

/// 共享的 InAppWebView 平台 fake：控件渲染为空 `SizedBox`，不触达原生。
///
/// 安装：`InAppWebViewPlatform.instance = FakeInAppWebViewPlatform(...)`。
class FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  FakeInAppWebViewPlatform({
    this.cookieMode = FakeCookieManagerMode.unsupported,
    this.withController = false,
  });

  final FakeCookieManagerMode cookieMode;

  /// 是否提供 `PlatformInAppWebViewController`（`noSuchMethod` 透传），
  /// 供 `InAppWebViewController.fromPlatformCreationParams` 构造测试控制器。
  final bool withController;

  /// 本平台创建出的 CookieManager（`unsupported` 时恒为 null）。
  FakeAcceptOnlyCookieManager? cookieManager;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return FakePlatformInAppWebViewWidget(params);
  }

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) {
    if (!withController) {
      return super.createPlatformInAppWebViewController(params);
    }
    return FakePlatformInAppWebViewController(params);
  }

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) {
    switch (cookieMode) {
      case FakeCookieManagerMode.unsupported:
        return super.createPlatformCookieManager(params);
      case FakeCookieManagerMode.acceptOnly:
        return cookieManager = FakeAcceptOnlyCookieManager(params);
      case FakeCookieManagerMode.inMemory:
        return cookieManager = FakeInMemoryCookieManager(params);
    }
  }
}

class FakePlatformInAppWebViewWidget extends PlatformInAppWebViewWidget {
  FakePlatformInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError('Controller is not used by this test fake.');
  }

  @override
  void dispose() {}
}

class FakePlatformInAppWebViewController
    extends PlatformInAppWebViewController {
  FakePlatformInAppWebViewController(super.params) : super.implementation();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAcceptOnlyCookieManager extends PlatformCookieManager {
  FakeAcceptOnlyCookieManager(super.params) : super.implementation();

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

class FakeInMemoryCookieManager extends FakeAcceptOnlyCookieManager {
  FakeInMemoryCookieManager(super.params);

  final Map<String, Cookie> _cookies = {};

  String _key(WebUri url, String name, String? domain, String path) {
    return '${url.host}|${domain ?? ''}|$path|$name';
  }

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
    _cookies[_key(url, name, domain, path)] = Cookie(
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
    _cookies.remove(_key(url, name, domain, path));
    return true;
  }
}

/// 读取页面中 `InAppWebView` 实际绑定到 fake 平台层的创建参数（含导航回调）。
PlatformInAppWebViewWidgetCreationParams boundInAppWebViewParams(
  WidgetTester tester,
) {
  final webView = tester.widget<InAppWebView>(find.byType(InAppWebView));
  final platform = webView.platform;
  expect(
    platform,
    isA<FakePlatformInAppWebViewWidget>(),
    reason: '测试必须运行在 fake InAppWebView 平台上',
  );
  return (platform as FakePlatformInAppWebViewWidget).params;
}
