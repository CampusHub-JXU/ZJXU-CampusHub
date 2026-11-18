import 'dart:async';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/academic_web_entry_preparer.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/webview_direct_route.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/academic_web_entry_page.dart';

import '../../helpers/test_setup.dart';
import '../../helpers/fake_inappwebview.dart';

const _directUrl =
    'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs';
const _webVpnUrl =
    'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421/'
    'xtgl/index_initMenu.html?jsdm=xs';

// ── fake InAppWebView 平台（同 webview_main_frame_failure_test 结构）─────────

PlatformInAppWebViewWidgetCreationParams _boundParams(WidgetTester tester) =>
    boundInAppWebViewParams(tester);

InAppWebViewController _testController() {
  return InAppWebViewController.fromPlatformCreationParams(
    params: const PlatformInAppWebViewControllerCreationParams(
      id: 'academic-web-entry-controller',
    ),
  );
}

// ── fake 准备器 ──────────────────────────────────────────────────────────────

class _FakePreparer extends AcademicWebEntryPreparer {
  _FakePreparer(this.steps);

  final List<Future<AcademicWebEntryResult> Function()> steps;
  final List<bool> forceWebVpnCalls = <bool>[];
  final List<CancelToken?> tokens = <CancelToken?>[];
  void Function()? onPrepare;
  int calls = 0;

  @override
  Future<AcademicWebEntryResult> prepare({
    String jsdm = 'xs',
    bool forceWebVpn = false,
    CancelToken? cancelToken,
    Duration totalBudget = AcademicWebEntryPreparer.defaultTotalBudget,
  }) {
    onPrepare?.call();
    forceWebVpnCalls.add(forceWebVpn);
    tokens.add(cancelToken);
    final index = calls < steps.length ? calls : steps.length - 1;
    calls++;
    return steps[index]();
  }
}

AcademicWebEntryReady _ready(
  String url, {
  Map<String, String> headers = const <String, String>{},
  ZhengfangMode mode = ZhengfangMode.direct,
}) {
  return AcademicWebEntryReady(url: url, headers: headers, selectedMode: mode);
}

class _FakeProxyBackend implements WebViewProxyBackend {
  _FakeProxyBackend({this.supported = true, List<String>? log})
    : log = log ?? <String>[];

  final bool supported;
  final List<String> log;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> setDirect() async => log.add('set');

  @override
  Future<void> clear() async => log.add('clear');
}

// ── driver ───────────────────────────────────────────────────────────────────

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FakePreparer preparer,
  WebViewDirectRoute? webViewDirectRoute,
  bool autoPromptLogin = false,
  Future<bool> Function(BuildContext context)? unifiedLoginPrompt,
  Future<bool> Function(BuildContext context)? academicLoginPrompt,
  Key? key,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AcademicWebEntryPage(
        key: key,
        title: '教务系统',
        preparer: preparer,
        // 默认注入「Dart 已走代理」的 fake，避免未 mock 的真实平台通道在 fake
        // async 下悬挂；直连覆盖行为由专用 group 覆盖。
        webViewDirectRoute:
            webViewDirectRoute ??
            WebViewDirectRoute(
              backend: _FakeProxyBackend(),
              isDartRouteDirect: () async => false,
            ),
        autoPromptLogin: autoPromptLogin,
        unifiedLoginPrompt: unifiedLoginPrompt,
        academicLoginPrompt: academicLoginPrompt,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<({_FakePreparer preparer, GlobalKey<AcademicWebEntryPageState> key})>
_bootReady(WidgetTester tester) async {
  final preparer = _FakePreparer([
    () async => _ready(_directUrl),
    () async => _ready(_webVpnUrl, mode: ZhengfangMode.webVpn),
  ]);
  final key = GlobalKey<AcademicWebEntryPageState>();
  await _pumpPage(tester, preparer: preparer, key: key);
  expect(find.byType(WebViewPage), findsOneWidget);
  return (preparer: preparer, key: key);
}

void _emitError(
  WidgetTester tester, {
  String url = _directUrl,
  String? method = 'GET',
  bool? isForMainFrame = true,
  WebResourceErrorType? type,
}) {
  final onReceivedError = _boundParams(tester).onReceivedError;
  expect(onReceivedError, isNotNull);
  onReceivedError!(
    _testController(),
    WebResourceRequest(
      url: WebUri(url),
      method: method,
      isForMainFrame: isForMainFrame,
    ),
    WebResourceError(
      description: 'connection dropped',
      type: type ?? WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
    ),
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
  });

  group('WebView 直连覆盖', () {
    testWidgets('先于准备 / 载入取得租约，页面销毁时释放', (tester) async {
      final log = <String>[];
      final backend = _FakeProxyBackend(log: log);
      final route = WebViewDirectRoute(
        backend: backend,
        isDartRouteDirect: () async => true,
      );
      final preparer = _FakePreparer([() async => _ready(_directUrl)])
        ..onPrepare = () => log.add('prepare');

      await _pumpPage(tester, preparer: preparer, webViewDirectRoute: route);
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(log, ['set', 'prepare'], reason: '覆盖必须先于 Cookie 同步 / 首次载入');
      expect(route.debugApplied, isTrue);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _settle(tester);
      expect(log, ['set', 'prepare', 'clear']);
      expect(route.debugApplied, isFalse);
      expect(route.debugLeaseCount, 0);
    });

    testWidgets('Dart 已走代理：不覆盖、不提示', (tester) async {
      final log = <String>[];
      final route = WebViewDirectRoute(
        backend: _FakeProxyBackend(log: log),
        isDartRouteDirect: () async => false,
      );
      final preparer = _FakePreparer([() async => _ready(_directUrl)]);

      await _pumpPage(tester, preparer: preparer, webViewDirectRoute: route);
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(log, isEmpty);
      expect(find.textContaining('无法让网页绕过系统代理'), findsNothing);
    });

    testWidgets('不支持覆盖：不阻塞入口，就绪后给一次非阻塞提示', (tester) async {
      final log = <String>[];
      final route = WebViewDirectRoute(
        backend: _FakeProxyBackend(supported: false, log: log),
        isDartRouteDirect: () async => true,
      );
      final preparer = _FakePreparer([() async => _ready(_directUrl)]);

      await _pumpPage(tester, preparer: preparer, webViewDirectRoute: route);
      await tester.pump();
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(find.textContaining('无法让网页绕过系统代理'), findsOneWidget);
      expect(log, isEmpty);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _settle(tester);
      expect(log, isEmpty, reason: '未生效的覆盖不得 clear');
      expect(route.debugLeaseCount, 0);
    });
  });

  testWidgets('Ready 用 result.url + result.headers 载入 WebView', (tester) async {
    final preparer = _FakePreparer([
      () async => _ready(_directUrl, headers: {'X-Entry': 'direct'}),
    ]);
    await _pumpPage(tester, preparer: preparer);

    final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(page.url, _directUrl);
    expect(page.initialHeaders, {'X-Entry': 'direct'});
    expect(preparer.calls, 1);
    expect(preparer.forceWebVpnCalls, [false]);
  });

  testWidgets('NeedsUnifiedLogin：自动弹统一认证弹窗，成功后重准备一次', (tester) async {
    var unifiedCalls = 0;
    var academicCalls = 0;
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryNeedsUnifiedLogin(),
      () async => _ready(_webVpnUrl, mode: ZhengfangMode.webVpn),
    ]);
    await _pumpPage(
      tester,
      preparer: preparer,
      autoPromptLogin: true,
      unifiedLoginPrompt: (context) async {
        unifiedCalls++;
        return true;
      },
      academicLoginPrompt: (context) async {
        academicCalls++;
        return true;
      },
    );

    expect(unifiedCalls, 1);
    expect(academicCalls, 0, reason: '统一认证需求绝不能走教务登录');
    expect(preparer.calls, 2);
    expect(preparer.forceWebVpnCalls, [false, false]);
    final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(page.url, _webVpnUrl);
  });

  testWidgets('NeedsUnifiedLogin：不自动弹时停在原生认证视图', (tester) async {
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryNeedsUnifiedLogin(),
    ]);
    await _pumpPage(tester, preparer: preparer);

    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(find.text('登录统一认证'), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
  });

  testWidgets('NeedsAcademicLogin：自动弹教务登录弹窗，成功后重准备一次', (tester) async {
    var unifiedCalls = 0;
    var academicCalls = 0;
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryNeedsAcademicLogin(),
      () async => _ready(_directUrl),
    ]);
    await _pumpPage(
      tester,
      preparer: preparer,
      autoPromptLogin: true,
      unifiedLoginPrompt: (context) async {
        unifiedCalls++;
        return true;
      },
      academicLoginPrompt: (context) async {
        academicCalls++;
        return true;
      },
    );

    expect(academicCalls, 1);
    expect(unifiedCalls, 0);
    expect(preparer.calls, 2);
    expect(find.byType(WebViewPage), findsOneWidget);
  });

  testWidgets('NeedsAcademicLogin：不自动弹时停在教务认证视图', (tester) async {
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryNeedsAcademicLogin(),
    ]);
    await _pumpPage(tester, preparer: preparer);

    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('需要登录后继续'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
  });

  testWidgets('Unavailable：错误视图可重试，重试重新武装兜底', (tester) async {
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryUnavailable('无法确认教务会话状态'),
      () async => _ready(_directUrl),
      () async => _ready(_webVpnUrl, mode: ZhengfangMode.webVpn),
    ]);
    await _pumpPage(tester, preparer: preparer);

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('无法确认教务会话状态'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await _settle(tester);
    expect(preparer.calls, 2);
    expect(find.byType(WebViewPage), findsOneWidget);

    // 显式重试重新武装一次性兜底：随后的合格失败仍会兜底。
    _emitError(tester);
    await _settle(tester);
    expect(preparer.calls, 3);
    expect(preparer.forceWebVpnCalls.last, isTrue);
    final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(page.url, _webVpnUrl);
  });

  testWidgets('Denied：错误视图无重试入口', (tester) async {
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryDenied('非受信教务入口'),
    ]);
    await _pumpPage(tester, preparer: preparer);

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('非受信教务入口'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('Stale：静默丢弃，不切成错误 / 登录视图', (tester) async {
    final preparer = _FakePreparer([
      () async => const AcademicWebEntryStale(
        AcademicWebEntryStaleReason.identityChanged,
      ),
    ]);
    await _pumpPage(tester, preparer: preparer);

    expect(preparer.calls, 1);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byType(AuthRequiredView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('合格的主框架 GET 失败触发一次直连→WebVPN 兜底', (tester) async {
    final boot = await _bootReady(tester);
    expect(boot.preparer.calls, 1);

    _emitError(tester);
    await _settle(tester);

    expect(boot.preparer.calls, 2);
    expect(boot.preparer.forceWebVpnCalls, [false, true]);
    expect(boot.key.currentState!.debugFallbackUsed, isTrue);
    final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(page.url, _webVpnUrl);
    expect(page.initialHeaders, isEmpty);
  });

  testWidgets('兜底每页面生命周期最多一次', (tester) async {
    final boot = await _bootReady(tester);

    _emitError(tester);
    await _settle(tester);
    expect(boot.preparer.calls, 2);

    // 新 WebView（webvpn URL）再次出现合格失败：不得再自动兜底，走默认错误页。
    _emitError(tester, url: _webVpnUrl);
    await _settle(tester);
    expect(boot.preparer.calls, 2);
    expect(find.text('页面加载失败'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
  });

  group('兜底拒绝矩阵', () {
    testWidgets('POST 方法拒绝', (tester) async {
      final boot = await _bootReady(tester);
      _emitError(tester, method: 'POST');
      await _settle(tester);
      expect(boot.preparer.calls, 1);
    });

    testWidgets('method 为 null 拒绝', (tester) async {
      final boot = await _bootReady(tester);
      _emitError(tester, method: null);
      await _settle(tester);
      expect(boot.preparer.calls, 1);
    });

    testWidgets('isForMainFrame=false 不触发回调', (tester) async {
      final boot = await _bootReady(tester);
      _emitError(tester, isForMainFrame: false);
      await _settle(tester);
      expect(boot.preparer.calls, 1);
      // 非主框架失败被 WebViewPage 直接忽略：既不兜底也不进错误页。
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(find.text('页面加载失败'), findsNothing);
    });

    testWidgets('isForMainFrame=null 不触发回调', (tester) async {
      final boot = await _bootReady(tester);
      _emitError(tester, isForMainFrame: null);
      await _settle(tester);
      expect(boot.preparer.calls, 1);
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(find.text('页面加载失败'), findsNothing);
    });

    testWidgets('URL 不匹配拒绝', (tester) async {
      final boot = await _bootReady(tester);
      _emitError(
        tester,
        url: 'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/other.html?jsdm=xs',
      );
      await _settle(tester);
      expect(boot.preparer.calls, 1);
    });

    testWidgets('SSL / 证书 / bad-url 类型拒绝', (tester) async {
      for (final type in <WebResourceErrorType>[
        WebResourceErrorType.FAILED_SSL_HANDSHAKE,
        WebResourceErrorType.SECURE_CONNECTION_FAILED,
        WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED,
        WebResourceErrorType.BAD_URL,
      ]) {
        final boot = await _bootReady(tester);
        _emitError(tester, type: type);
        await _settle(tester);
        expect(boot.preparer.calls, 1, reason: 'type=$type 不得触发兜底');
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();
      }
    });

    testWidgets('本页主动作废的入口拒绝', (tester) async {
      final boot = await _bootReady(tester);
      boot.key.currentState!.debugMarkEntryCancelled();
      _emitError(tester);
      await _settle(tester);
      expect(boot.preparer.calls, 1);
    });

    testWidgets('入口后交互式导航拒绝', (tester) async {
      final boot = await _bootReady(tester);
      final onLoadStop = _boundParams(tester).onLoadStop;
      expect(onLoadStop, isNotNull);
      onLoadStop!(
        _testController(),
        WebUri('https://jwzx.zjxu.edu.cn/jwglxt/xtgl/other.html?jsdm=xs'),
      );
      await tester.pump();
      _emitError(tester);
      await _settle(tester);
      expect(boot.preparer.calls, 1);
    });

    testWidgets('过期代际拒绝', (tester) async {
      final boot = await _bootReady(tester);
      final state = boot.key.currentState!;
      final handled = await state.debugHandleMainFrameFailure(
        WebViewMainFrameLoadFailure(
          url: _directUrl,
          method: 'GET',
          isForMainFrame: true,
          type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
        ),
        generation: state.debugGeneration - 1,
      );
      expect(handled, isFalse);
      await _settle(tester);
      expect(boot.preparer.calls, 1);
    });
  });

  testWidgets('兜底期间身份变化：静默丢弃迟到结果', (tester) async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '2024001');
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    final completer = Completer<AcademicWebEntryResult>();
    final preparer = _FakePreparer([
      () async => _ready(_directUrl),
      () => completer.future,
    ]);
    final key = GlobalKey<AcademicWebEntryPageState>();
    await _pumpPage(tester, preparer: preparer, key: key);

    _emitError(tester);
    await tester.pump();
    expect(preparer.calls, 2);

    // 兜底在途：身份变化（登出 / 换号）。
    ZhengfangAuth.instance.debugSetSession(active: false, studentId: null);
    completer.complete(_ready(_webVpnUrl, mode: ZhengfangMode.webVpn));
    await _settle(tester);

    // 迟到结果被丢弃：仍停在原直连 WebView，未创建新入口。
    final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(page.url, _directUrl);
    expect(key.currentState!.debugReadyUrl, _directUrl);
  });

  testWidgets('dispose 取消在途准备，且不再 setState', (tester) async {
    final completer = Completer<AcademicWebEntryResult>();
    final preparer = _FakePreparer([() => completer.future]);
    await tester.pumpWidget(
      MaterialApp(
        home: AcademicWebEntryPage(title: '教务系统', preparer: preparer),
      ),
    );
    await tester.pump();
    final token = preparer.tokens.single;
    expect(token, isNotNull);
    expect(token!.isCancelled, isFalse);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(token.isCancelled, isTrue);

    completer.complete(const AcademicWebEntryUnavailable('late'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
