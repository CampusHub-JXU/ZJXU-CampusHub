import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../../helpers/fake_inappwebview.dart';

const _url = 'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5';

/// 读取 WebViewPage 实际绑定到平台层的导航回调。
PlatformInAppWebViewWidgetCreationParams _boundParams(WidgetTester tester) =>
    boundInAppWebViewParams(tester);

InAppWebViewController _testController() {
  return InAppWebViewController.fromPlatformCreationParams(
    params: const PlatformInAppWebViewControllerCreationParams(
      id: 'main-frame-failure-controller',
    ),
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  WebViewMainFrameLoadFailureCallback? onMainFrameLoadFailure,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WebViewPage(
        title: '主框架加载失败',
        url: _url,
        onMainFrameLoadFailure: onMainFrameLoadFailure,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void _emitReceivedError(
  WidgetTester tester, {
  String url = _url,
  String? method,
  bool? isForMainFrame = true,
  WebResourceErrorType? type,
}) {
  final onReceivedError = _boundParams(tester).onReceivedError;
  expect(
    onReceivedError,
    isNotNull,
    reason: 'WebViewPage 必须把 onReceivedError 绑定到平台层',
  );
  onReceivedError!(
    _testController(),
    WebResourceRequest(
      url: WebUri(url),
      method: method,
      isForMainFrame: isForMainFrame,
    ),
    WebResourceError(
      description: 'connection dropped',
      type: type ?? WebResourceErrorType.TIMEOUT,
    ),
  );
}

void _emitReceivedHttpError(
  WidgetTester tester, {
  String url = _url,
  bool? isForMainFrame = true,
}) {
  final onReceivedHttpError = _boundParams(tester).onReceivedHttpError;
  expect(
    onReceivedHttpError,
    isNotNull,
    reason: 'WebViewPage 必须把 onReceivedHttpError 绑定到平台层',
  );
  onReceivedHttpError!(
    _testController(),
    WebResourceRequest(url: WebUri(url), isForMainFrame: isForMainFrame),
    WebResourceResponse(statusCode: 500, reasonPhrase: 'Server Error'),
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

  testWidgets(
    'default behavior without a callback keeps the existing error UI',
    (tester) async {
      await _pumpPage(tester);
      expect(find.byType(InAppWebView), findsOneWidget);

      _emitReceivedError(tester, method: 'GET');
      await tester.pump();
      await tester.pump();

      expect(find.text('页面加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'handled callback keeps the webview and receives GET/POST/null facts',
    (tester) async {
      final failures = <WebViewMainFrameLoadFailure>[];
      await _pumpPage(
        tester,
        onMainFrameLoadFailure: (failure) async {
          failures.add(failure);
          return true;
        },
      );

      _emitReceivedError(
        tester,
        method: 'GET',
        type: WebResourceErrorType.TIMEOUT,
      );
      await tester.pump();
      _emitReceivedError(
        tester,
        method: 'POST',
        type: WebResourceErrorType.CANNOT_CONNECT_TO_HOST,
      );
      await tester.pump();
      _emitReceivedError(
        tester,
        method: null,
        type: WebResourceErrorType.HOST_LOOKUP,
      );
      await tester.pump();

      expect(failures, hasLength(3));
      expect(failures[0].url, _url);
      expect(failures[0].method, 'GET');
      expect(failures[0].isForMainFrame, isTrue);
      expect(failures[0].type, WebResourceErrorType.TIMEOUT);
      expect(failures[1].method, 'POST');
      expect(failures[1].type, WebResourceErrorType.CANNOT_CONNECT_TO_HOST);
      expect(failures[2].method, isNull);
      expect(failures[2].type, WebResourceErrorType.HOST_LOOKUP);

      // handled=true：抑制默认错误页，WebView 保留。
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(find.text('页面加载失败'), findsNothing);
    },
  );

  testWidgets('false/null main-frame flags never invoke the callback', (
    tester,
  ) async {
    var calls = 0;
    await _pumpPage(
      tester,
      onMainFrameLoadFailure: (failure) async {
        calls++;
        return true;
      },
    );

    _emitReceivedError(tester, isForMainFrame: false);
    await tester.pump();
    _emitReceivedError(tester, isForMainFrame: null);
    await tester.pump();

    expect(calls, 0);
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(find.text('页面加载失败'), findsNothing);
  });

  testWidgets('onReceivedHttpError never invokes the failure callback', (
    tester,
  ) async {
    var calls = 0;
    await _pumpPage(
      tester,
      onMainFrameLoadFailure: (failure) async {
        calls++;
        return true;
      },
    );

    _emitReceivedHttpError(tester);
    await tester.pump();
    await tester.pump();

    expect(calls, 0);
    // HTTP 错误仍走既有默认错误页（本次改造不改变该路径）。
    expect(find.text('页面加载失败'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
  });

  testWidgets('unhandled callback (false) keeps the default error UI', (
    tester,
  ) async {
    await _pumpPage(tester, onMainFrameLoadFailure: (failure) async => false);

    _emitReceivedError(tester);
    await tester.pump();
    await tester.pump();

    expect(find.text('页面加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('throwing callback preserves default error UI without leaking', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      onMainFrameLoadFailure: (failure) async {
        throw StateError('callback boom');
      },
    );

    _emitReceivedError(tester);
    await tester.pump();
    await tester.pump();

    expect(find.text('页面加载失败'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing during an in-flight callback is safe', (tester) async {
    final completer = Completer<bool>();
    await _pumpPage(
      tester,
      onMainFrameLoadFailure: (failure) => completer.future,
    );

    _emitReceivedError(tester);
    await tester.pump();
    expect(find.byType(InAppWebView), findsOneWidget);

    // 卸载页面后再完成回调：不得 setState，也不得抛错。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    completer.complete(false);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a new load superseding an in-flight callback is not torn down', (
    tester,
  ) async {
    final completer = Completer<bool>();
    await _pumpPage(
      tester,
      onMainFrameLoadFailure: (failure) => completer.future,
    );

    _emitReceivedError(tester);
    await tester.pump();

    // 新加载开始推进代际，使在途回调结果过期。
    final onLoadStart = _boundParams(tester).onLoadStart;
    expect(onLoadStart, isNotNull);
    onLoadStart!(_testController(), WebUri(_url));
    await tester.pump();

    completer.complete(false);
    await tester.pump();
    await tester.pump();

    // 过期结果不得把新加载打成错误页。
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(find.text('页面加载失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
