import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/shared/widgets/external_url_launcher.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';
import 'package:url_launcher/url_launcher.dart';

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

void main() {
  setUpAll(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  tearDown(() {
    debugResetExternalUrlLauncher();
  });

  testWidgets(
    'protected page retries network preparation and uses selected URL',
    (tester) async {
      var calls = 0;
      const proxyUrl = 'https://webvpn.zjxu.edu.cn/https/example/#/form';
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedAuthProtectedWebViewPage(
            title: '校园卡',
            url: 'https://mobilehall.zjxu.edu.cn/',
            serviceUrl: CasService.campusCardStatus.serviceUrl,
            autoPromptLogin: false,
            prepareAuthenticatedUrl: () async {
              if (++calls == 1) throw StateError('network offline');
              return proxyUrl;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂时无法连接服务，请切换网络后重试'), findsOneWidget);
      expect(find.text('登录统一认证'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(
        tester.widget<WebViewPage>(find.byType(WebViewPage)).url,
        proxyUrl,
      );
    },
  );

  testWidgets('protected page requests login only on explicit auth expiry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '校园卡',
          url: 'https://mobilehall.zjxu.edu.cn/',
          serviceUrl: CasService.campusCardStatus.serviceUrl,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async =>
              throw const CasAuthExpiredException(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(find.text('登录统一认证'), findsOneWidget);
    expect(find.byType(WebViewPage), findsNothing);
  });

  group('detectWebViewQuickFillKind', () {
    test('detects zhengfang login page', () {
      expect(
        detectWebViewQuickFillKind(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html',
        ),
        WebViewQuickFillKind.zhengfang,
      );
    });

    test('detects unified auth login page', () {
      expect(
        detectWebViewQuickFillKind(
          'https://newca.zjxu.edu.cn/cas/login?service=test',
        ),
        WebViewQuickFillKind.unifiedAuth,
      );
    });

    test('detects library login page as unified auth quick fill', () {
      expect(
        detectWebViewQuickFillKind(
          'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421fcfe439d3720264a74109ce29d51367b2b47/'
          '#!/User/Index/login?forward=%2FContent%2FIndex%2Findex',
        ),
        WebViewQuickFillKind.unifiedAuth,
      );
    });

    test('ignores non-login pages', () {
      expect(
        detectWebViewQuickFillKind(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        ),
        isNull,
      );
    });
  });

  group('isServiceHallHomeUrl', () {
    test('detects service hall homepage urls', () {
      expect(
        isServiceHallHomeUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ),
        isTrue,
      );
      expect(
        isServiceHallHomeUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html?t=1775743928213#//business/ydd/portal/home',
        ),
        isTrue,
      );
    });

    test('ignores non-home service hall urls', () {
      expect(
        isServiceHallHomeUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/wfw/id=ED8D7B51A2422411E0532602010A9D8D',
        ),
        isFalse,
      );
      expect(
        isServiceHallHomeUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isFalse,
      );
    });
  });

  group('selectLoadedWebViewUrl', () {
    test('prefers controller url over reported url', () {
      expect(
        selectLoadedWebViewUrl(
          fallbackUrl: 'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
          reportedUrl: 'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing',
          controllerUrl: 'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing?ticket=ST-1',
        ),
        'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing?ticket=ST-1',
      );
    });

    test('falls back when controller url is unavailable', () {
      expect(
        selectLoadedWebViewUrl(
          fallbackUrl: 'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
          reportedUrl: 'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing',
        ),
        'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing',
      );
    });
  });

  group('WebViewPage navigation and popup menu', () {
    testWidgets(
      'renders top right 3-dots popup menu and does not mount WebViewBackPill',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(
              title: '教务通知',
              url: 'https://jwzx.zjxu.edu.cn/notice/1.html',
              showWebViewBottomBackButton: true,
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(WebViewBackPill), findsNothing);
        expect(find.byTooltip('更多操作'), findsOneWidget);
      },
    );

    testWidgets(
      'opening popup menu reveals refresh and open in external browser options',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(
              title: '教务通知',
              url: 'https://jwzx.zjxu.edu.cn/notice/1.html',
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();

        expect(find.text('刷新'), findsOneWidget);
        expect(find.text('在浏览器中打开'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping open in external browser launches current URL externally',
      (tester) async {
        Uri? launchedUri;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              launchedUri = uri;
              return true;
            };

        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(
              title: '教务通知',
              url: 'https://jwzx.zjxu.edu.cn/notice/1.html',
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('在浏览器中打开'));
        await tester.pumpAndSettle();

        expect(
          launchedUri,
          Uri.parse('https://jwzx.zjxu.edu.cn/notice/1.html'),
        );
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'tapping open in external browser shows feedback when launch fails',
      (tester) async {
        debugUrlLauncherOverride = (
          uri, {
          mode = LaunchMode.platformDefault,
        }) async => false;

        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(
              title: '教务通知',
              url: 'https://jwzx.zjxu.edu.cn/notice/1.html',
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('在浏览器中打开'));
        await tester.pumpAndSettle();

        expect(find.text('未能调起系统外部浏览器'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping open in external browser shows feedback for invalid address',
      (tester) async {
        var launcherCalled = false;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              launcherCalled = true;
              return true;
            };

        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(title: '本地协议', url: 'javascript:void(0)'),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('在浏览器中打开'));
        await tester.pumpAndSettle();

        expect(launcherCalled, isFalse);
        expect(find.text('当前链接无效或不支持在外部浏览器打开'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping open in external browser preserves business code parameter for documents',
      (tester) async {
        Uri? launchedUri;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              launchedUri = uri;
              return true;
            };

        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(
              title: '文件下载',
              url: 'https://jwzx.zjxu.edu.cn/download?code=FILE_2026_09&id=101',
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('在浏览器中打开'));
        await tester.pumpAndSettle();

        expect(
          launchedUri,
          Uri.parse(
            'https://jwzx.zjxu.edu.cn/download?code=FILE_2026_09&id=101',
          ),
        );
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'tapping open in external browser blocks sensitive auth intermediate URL with clear feedback',
      (tester) async {
        var launcherCalled = false;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              launcherCalled = true;
              return true;
            };

        await tester.pumpWidget(
          const MaterialApp(
            home: WebViewPage(
              title: '认证跳转',
              url: 'https://mobilehall.zjxu.edu.cn/wfw?ticket=ST-12345678',
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('在浏览器中打开'));
        await tester.pumpAndSettle();

        expect(launcherCalled, isFalse);
        expect(find.text('当前页面处于登录认证跳转中，请在页面完全加载后再尝试外部打开'), findsOneWidget);
      },
    );

    testWidgets(
      'WebViewBackPill standalone widget renders properly for preview tests',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: WebViewBackPill(onTap: () {})),
          ),
        );
        await tester.pump();

        expect(find.text('网页内返回'), findsOneWidget);
      },
    );
  });
}
