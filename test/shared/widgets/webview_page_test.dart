import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/maintenance_window.dart';
import 'package:jxu_campus_hub/shared/widgets/external_url_launcher.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../helpers/fake_inappwebview.dart';

void main() {
  setUpAll(() {
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
  });

  setUp(() {
    debugMaintenanceNowOverride = () => DateTime(2026, 11, 15, 10, 0);
  });

  tearDown(() {
    debugMaintenanceNowOverride = null;
    debugResetExternalUrlLauncher();
    UnifiedAuthService.instance.debugReset();
  });

  testWidgets(
    'protected page retries network preparation and uses selected URL',
    (tester) async {
      // 有本地会话时，网络未知失败给「重试」而不是登录引导。
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2024001',
      );
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

  testWidgets(
    'prepare returning a CAS login URL stays on native auth guidance',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedAuthProtectedWebViewPage(
            title: '校园卡账单',
            url: 'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form',
            serviceUrl: CasService.campusCardStatus.serviceUrl,
            autoPromptLogin: false,
            prepareAuthenticatedUrl: () async =>
                'https://newca.zjxu.edu.cn/cas/login'
                '?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 绝不把学校 CAS 的 H5 登录页交给用户，也不出现一卡通快速填充。
      expect(find.text('需要统一认证后继续'), findsOneWidget);
      expect(find.byType(WebViewPage), findsNothing);
      expect(find.text('一键填充'), findsNothing);
      expect(find.text('一卡通快速填充'), findsNothing);
    },
  );

  testWidgets(
    'prepare returning a webvpn-proxied CAS login URL is blocked too',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedAuthProtectedWebViewPage(
            title: '校园卡账单',
            url: 'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form',
            serviceUrl: CasService.campusCardStatus.serviceUrl,
            autoPromptLogin: false,
            prepareAuthenticatedUrl: () async =>
                'https://webvpn.zjxu.edu.cn/https/'
                '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
                '/cas/login?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('需要统一认证后继续'), findsOneWidget);
      expect(find.byType(WebViewPage), findsNothing);
      expect(find.text('一键填充'), findsNothing);
    },
  );

  testWidgets('protected page mounts webview without quick fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '校园卡账单',
          url: 'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form',
          serviceUrl: CasService.campusCardStatus.serviceUrl,
          autoPromptLogin: false,
          prepareAuthenticatedUrl: () async =>
              'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final webView = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(webView.enableLoginQuickFill, isFalse);
    expect(find.text('一键填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
  });

  group('isZhengfangQuickFillTarget', () {
    test('detects zhengfang login page', () {
      expect(
        isZhengfangQuickFillTarget(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html',
        ),
        isTrue,
      );
    });

    test('never treats unified auth CAS pages as quick fill targets', () {
      expect(
        isZhengfangQuickFillTarget(
          'https://newca.zjxu.edu.cn/cas/login?service=test',
        ),
        isFalse,
      );
      expect(
        isZhengfangQuickFillTarget(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
          '/cas/login?service=test',
        ),
        isFalse,
      );
    });

    test('ignores non-login pages', () {
      expect(
        isZhengfangQuickFillTarget(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        ),
        isFalse,
      );
    });
  });

  group('isWebViewCasLoginEntryUrl', () {
    test('detects direct newca CAS login entry', () {
      expect(
        isWebViewCasLoginEntryUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=test',
        ),
        isTrue,
      );
    });

    test('detects webvpn-proxied CAS login entry', () {
      expect(
        isWebViewCasLoginEntryUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
          '/cas/login?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn',
        ),
        isTrue,
      );
    });

    test('keeps business pages and CAS client callbacks clear', () {
      expect(
        isWebViewCasLoginEntryUrl(
          'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5',
        ),
        isFalse,
      );
      expect(
        isWebViewCasLoginEntryUrl(
          'https://newca.zjxu.edu.cn/casClient/login/ydd',
        ),
        isFalse,
      );
      expect(
        isWebViewCasLoginEntryUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
          '/weixin/main.jsp',
        ),
        isFalse,
      );
    });
  });

  group('isSsoIntermediateLandingUrl', () {
    test('detects direct newca CAS oauth landings', () {
      // cas/login 本身也按中间跳转页对待：入口判定在前，这里只兜底。
      expect(
        isSsoIntermediateLandingUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=test',
        ),
        isTrue,
      );
      expect(
        isSsoIntermediateLandingUrl(
          'https://newca.zjxu.edu.cn/cas/oauth/forward/st-token',
        ),
        isTrue,
      );
      expect(
        isSsoIntermediateLandingUrl(
          'https://newca.zjxu.edu.cn/cas/oauth2.0/authorize?client_id=x',
        ),
        isTrue,
      );
    });

    test('detects dingtalk authorization hosts', () {
      expect(
        isSsoIntermediateLandingUrl(
          'https://login.dingtalk.com/oauth2/auth?redirect_uri=x',
        ),
        isTrue,
      );
      expect(
        isSsoIntermediateLandingUrl('https://oapi.dingtalk.com/connect/oauth2'),
        isTrue,
      );
      expect(isSsoIntermediateLandingUrl('https://dingtalk.com/'), isTrue);
    });

    test('detects webvpn-proxied CAS oauth landings', () {
      expect(
        isSsoIntermediateLandingUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a'
          '/cas/login?service=test',
        ),
        isTrue,
      );
      expect(
        isSsoIntermediateLandingUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a'
          '/cas/oauth/forward/st-token',
        ),
        isTrue,
      );
      expect(
        isSsoIntermediateLandingUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a'
          '/cas/oauth2.0/profile',
        ),
        isTrue,
      );
    });

    test('detects library sso ticket-consumer landings', () {
      // ssoFromDingDing 是 ticket 消费入口：ticket 落地后接着跳 CAS
      // oauth/forward，属于 SSO 链中间页，不是业务页。
      expect(
        isSsoIntermediateLandingUrl(
          'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing'
          '?ticket=ST-1',
        ),
        isTrue,
      );
      expect(
        isSsoIntermediateLandingUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fcfe439d3720264a74109ce29d51367b2b47'
          '/Info/Thirdparty/ssoFromDingDing?ticket=ST-1',
        ),
        isTrue,
      );
    });

    test('keeps ordinary business pages and the proxied site root clear', () {
      expect(
        isSsoIntermediateLandingUrl(
          'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5',
        ),
        isFalse,
      );
      // 图书馆站点根（直连与 WebVPN 代理形态）都是业务页，不是 SSO 中间跳转。
      expect(
        isSsoIntermediateLandingUrl('https://libapp.zjxu.edu.cn/'),
        isFalse,
      );
      expect(
        isSsoIntermediateLandingUrl(
          'https://webvpn.zjxu.edu.cn/https/'
          '77726476706e69737468656265737421fcfe439d3720264a74109ce29d51367b2b47/',
        ),
        isFalse,
      );
      expect(isSsoIntermediateLandingUrl(''), isFalse);
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

  group('isWebViewAuthRedirectHistoryUrl & resolveWebViewBackStepOffset', () {
    test('detects service hall ssoLogin and SSO redirect history items', () {
      expect(
        isWebViewAuthRedirectHistoryUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/ssoLogin.html?username=123&services=%2Fbusiness%2Fydd%2Fportal%2Fhome',
        ),
        isTrue,
      );
      expect(
        isWebViewAuthRedirectHistoryUrl(
          'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421fdf8529e2e206e446b1cc7a99c406d3693/mportal/start/ssoLogin.html?username=123',
        ),
        isTrue,
      );
      expect(
        isWebViewAuthRedirectHistoryUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ),
        isFalse,
      );
    });

    test('returns null when only auth redirect pages precede current page', () {
      expect(
        resolveWebViewBackStepOffset([
          'https://mobilehall.zjxu.edu.cn/mportal/start/ssoLogin.html?username=123',
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ], 1),
        isNull,
      );
    });

    test('skips auth redirect pages to land on previous real page', () {
      expect(
        resolveWebViewBackStepOffset([
          'https://mobilehall.zjxu.edu.cn/mportal/start/ssoLogin.html?username=123',
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
          'https://newca.zjxu.edu.cn/casClient/login/ydd',
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/wfw/id=1',
        ], 3),
        -2,
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
    testWidgets('renders top right 3-dots popup menu', (tester) async {
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

      expect(find.byTooltip('更多操作'), findsOneWidget);
    });

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
  });
}
