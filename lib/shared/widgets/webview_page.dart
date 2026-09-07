import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/credential_store.dart';
import '../../core/logging/app_logger.dart';
import 'external_url_launcher.dart';
import 'qr_scanner_page.dart';
import './app_app_bar.dart';

part 'webview_page_helpers.dart';
part 'webview_page_build.dart';

typedef WebViewLoadStopCallback = Future<void> Function(
  InAppWebViewController controller,
  String currentUrl,
);
typedef WebViewNavigationRequestCallback =
    Future<NavigationActionPolicy?> Function(
      InAppWebViewController controller,
      Uri uri,
    );
typedef _WebViewPageSnapshot = ({
  String title,
  String readyState,
  int textLength,
  int childCount,
});

enum _WebViewMenuAction { refresh, openExternal }

/// Reusable full-screen WebView page with progress bar and error handling.
class WebViewPage extends StatefulWidget {
  const WebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.initialHeaders = const {},
    this.onLoadStop,
    this.onNavigationRequest,
    this.enableLoginQuickFill = false,
    this.emulateDingTalkEnvironment = true,
    this.emulateWeChatEnvironment = false,
    this.showWebViewBottomBackButton = false,
    this.onHomePressed,
    this.appBarActions = const [],
  });

  final String title;
  final String url;
  final Map<String, String> initialHeaders;
  final WebViewLoadStopCallback? onLoadStop;
  final WebViewNavigationRequestCallback? onNavigationRequest;
  final bool enableLoginQuickFill;
  final bool emulateDingTalkEnvironment;
  final bool emulateWeChatEnvironment;
  final bool showWebViewBottomBackButton;
  final VoidCallback? onHomePressed;
  final List<Widget> appBarActions;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  double _progress = 0;
  bool _hasError = false;
  bool _hasShownEnvHint = false;
  bool _hasFallbackToHome = false;
  bool _allowRoutePop = false;
  bool _canGoBackInWebView = false;
  late String _currentUrl;
  InAppWebViewController? _controller;
  (String, String)? _savedZhengfangCredentials;
  (String, String)? _savedUnifiedCredentials;
  WebViewQuickFillKind? _quickFillKind;
  bool _quickFillBusy = false;

  LogConfig get _logConfig => AppLogger.instance.config.value;

  bool get _webViewLifecycleLoggingEnabled =>
      _logConfig.webviewLifecycleEnabled;

  bool get _webViewConsoleLoggingEnabled => _logConfig.webviewConsoleEnabled;

  void _logWebViewLifecycle(String message) {
    if (!_webViewLifecycleLoggingEnabled) return;
    AppLogger.instance.webview(LogLevel.debug, message);
  }

  bool _isNoisyConsoleMessage(String lowerMessage) {
    return _webViewConsoleNoiseKeywords.any(lowerMessage.contains);
  }

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    if (widget.enableLoginQuickFill) {
      _restoreSavedCredentials();
      _quickFillKind = detectWebViewQuickFillKind(widget.url);
    }
  }

  void _trackCurrentUrlValue(String? value) {
    if (value == null || value.isEmpty) return;

    _currentUrl = value;
    if (!widget.enableLoginQuickFill) return;

    final nextKind = detectWebViewQuickFillKind(value);
    if (nextKind != _quickFillKind && mounted) {
      setState(() => _quickFillKind = nextKind);
    } else {
      _quickFillKind = nextKind;
    }
  }

  void _trackCurrentUrl(WebUri? url) {
    _trackCurrentUrlValue(url?.toString());
  }

  Future<String> _resolveLoadedUrl(
    InAppWebViewController controller,
    WebUri? reportedUrl,
  ) async {
    final reportedValue = reportedUrl?.toString();
    try {
      final controllerValue = (await controller.getUrl())?.toString();
      final resolved = selectLoadedWebViewUrl(
        fallbackUrl: _currentUrl,
        reportedUrl: reportedValue,
        controllerUrl: controllerValue,
      );
      if (reportedValue != null &&
          reportedValue.isNotEmpty &&
          controllerValue != null &&
          controllerValue.isNotEmpty &&
          reportedValue != controllerValue) {
        _logWebViewLifecycle(
          'WebView load stop URL 修正: reported=$reportedValue actual=$controllerValue',
        );
      }
      return resolved;
    } catch (error) {
      _logWebViewLifecycle('获取 WebView 当前 URL 失败：$error');
      return selectLoadedWebViewUrl(
        fallbackUrl: _currentUrl,
        reportedUrl: reportedValue,
      );
    }
  }

  Future<void> _restoreSavedCredentials() async {
    final zhengfangCredentials = await CredentialStore.instance
        .loadCredentials();
    final unifiedCredentials = await CredentialStore.instance
        .loadUnifiedAuthCredentials();
    if (!mounted) return;

    setState(() {
      _savedZhengfangCredentials = zhengfangCredentials;
      _savedUnifiedCredentials = unifiedCredentials;
    });
  }

  void _showHint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _setQuickFillBusy(bool value) {
    if (mounted) {
      setState(() => _quickFillBusy = value);
    } else {
      _quickFillBusy = value;
    }
  }

  Future<bool> _goBackInWebViewIfPossible() async {
    final controller = _controller;
    if (controller == null || _hasError) return false;

    try {
      final canGoBack = await controller.canGoBack();
      if (!canGoBack) {
        if (_canGoBackInWebView && mounted) {
          setState(() => _canGoBackInWebView = false);
        } else {
          _canGoBackInWebView = false;
        }
        return false;
      }
      await controller.goBack();
      unawaited(_refreshWebViewBackState(controller));
      return true;
    } catch (error) {
      AppLogger.instance.webview(
        LogLevel.warn,
        'WebView 返回上一页失败：$_currentUrl :: $error',
      );
      return false;
    }
  }

  Future<void> _handleAppBackPressed() async {
    if (!mounted) return;
    final didGoBack = await _goBackInWebViewIfPossible();
    if (didGoBack) return;
    if (!mounted) return;
    await _popRoute();
  }

  Future<void> _refreshWebViewBackState([
    InAppWebViewController? controller,
  ]) async {
    final activeController = controller ?? _controller;
    if (activeController == null || _hasError) {
      if (_canGoBackInWebView && mounted) {
        setState(() => _canGoBackInWebView = false);
      } else {
        _canGoBackInWebView = false;
      }
      return;
    }

    try {
      final canGoBack = await activeController.canGoBack();
      if (!mounted) {
        _canGoBackInWebView = canGoBack;
        return;
      }
      if (_canGoBackInWebView != canGoBack) {
        setState(() => _canGoBackInWebView = canGoBack);
      }
    } catch (_) {
      if (_canGoBackInWebView && mounted) {
        setState(() => _canGoBackInWebView = false);
      } else {
        _canGoBackInWebView = false;
      }
    }
  }

  Future<void> _popRoute() async {
    if (!mounted) return;

    setState(() => _allowRoutePop = true);
    final didPop = await Navigator.of(context).maybePop();
    if (!mounted) return;

    if (!didPop) {
      setState(() => _allowRoutePop = false);
      widget.onHomePressed?.call();
    }
  }

  Future<void> _reloadCurrentPage() async {
    if (_hasError) {
      setState(() {
        _hasError = false;
        _canGoBackInWebView = false;
        _progress = 0;
      });
      return;
    }

    final controller = _controller;
    if (controller == null) return;

    try {
      await controller.reload();
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _hasError = false;
        _canGoBackInWebView = false;
        _controller = null;
        _progress = 0;
      });
    }
  }

  void _fallbackToServiceHallHome(
    InAppWebViewController controller,
    String hint,
  ) {
    _hasFallbackToHome = true;
    _showHint(hint);
    controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(_serviceHallHomeUrl)),
    );
  }

  void _handleConsoleMessage(
    InAppWebViewController controller,
    ConsoleMessage consoleMessage,
  ) {
    final message = consoleMessage.message;
    final lowerMessage = message.toLowerCase();

    if (_isNoisyConsoleMessage(lowerMessage)) {
      return;
    }

    if (!_hasShownEnvHint && lowerMessage.contains('notindingtalk')) {
      _hasShownEnvHint = true;
      AppLogger.instance.webview(
        LogLevel.info,
        'WebView 环境提示：$_currentUrl 需要钉钉环境',
      );
      _showHint('当前页面依赖钉钉环境，部分功能可能受限');
      return;
    }

    final isErrorLevel =
        consoleMessage.messageLevel == ConsoleMessageLevel.ERROR;
    final isWarningLevel =
        consoleMessage.messageLevel == ConsoleMessageLevel.WARNING;

    if (isErrorLevel || isWarningLevel) {
      if (!_webViewConsoleLoggingEnabled && !isErrorLevel) {
        return;
      }
      AppLogger.instance.webview(
        isErrorLevel ? LogLevel.error : LogLevel.warn,
        'WebView console [${consoleMessage.messageLevel}] $_currentUrl :: $message',
      );
      return;
    }

    if (_webViewConsoleLoggingEnabled) {
      AppLogger.instance.webview(
        LogLevel.debug,
        'WebView console [${consoleMessage.messageLevel}] $_currentUrl :: $message',
      );
    }
  }

  Future<void> _inspectLoadedPage(InAppWebViewController controller) async {
    try {
      final snapshot = await _capturePageSnapshot(controller);
      if (snapshot == null) return;

      _logWebViewLifecycle(
        'WebView load stop: url=$_currentUrl readyState=${snapshot.readyState} title=${snapshot.title.isEmpty ? '[empty]' : snapshot.title} textLength=${snapshot.textLength} childCount=${snapshot.childCount}',
      );

      final isBlankLike = _isBlankLikeSnapshot(snapshot);
      if (!isBlankLike) return;

      final inspectedUrl = _currentUrl;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || _currentUrl != inspectedUrl) return;

      final retrySnapshot = await _capturePageSnapshot(controller);
      if (retrySnapshot == null || !_isBlankLikeSnapshot(retrySnapshot)) {
        return;
      }

      AppLogger.instance.webview(
        LogLevel.error,
        'WebView 疑似白屏：url=$_currentUrl',
      );

      final uri = Uri.tryParse(_currentUrl);
      final isServiceHallEntry =
          uri != null &&
          uri.host.toLowerCase() == _serviceHallHost &&
          uri.path == '/mportal/start/index.html' &&
          uri.fragment.isEmpty;

      if (isServiceHallEntry && !_hasFallbackToHome) {
        _fallbackToServiceHallHome(controller, '服务大厅入口未渲染，已尝试切换到首页');
      }
    } catch (error) {
      _logWebViewLifecycle('WebView 页面快照失败：$_currentUrl :: $error');
    }
  }

  Future<_WebViewPageSnapshot?> _capturePageSnapshot(
    InAppWebViewController controller,
  ) async {
    final snapshot = await controller.evaluateJavascript(
      source: '''
        (() => {
          const title = document.title || '';
          const readyState = document.readyState || '';
          const bodyText = document.body?.innerText?.trim() || '';
          const childCount = document.body?.children?.length || 0;
          return {
            title,
            readyState,
            textLength: bodyText.length,
            childCount,
          };
        })();
      ''',
    );

    final map = snapshot is Map
        ? Map<Object?, Object?>.from(snapshot)
        : const {};
    return (
      title: '${map['title'] ?? ''}'.trim(),
      readyState: '${map['readyState'] ?? ''}'.trim(),
      textLength: int.tryParse('${map['textLength'] ?? 0}') ?? 0,
      childCount: int.tryParse('${map['childCount'] ?? 0}') ?? 0,
    );
  }

  bool _isBlankLikeSnapshot(_WebViewPageSnapshot snapshot) {
    return snapshot.textLength == 0 &&
        snapshot.childCount == 0 &&
        snapshot.readyState == 'complete';
  }

  @override
  Widget build(BuildContext context) {
    final canPopRoute = Navigator.of(context).canPop();
    final showHomeButton = widget.onHomePressed != null;
    final showHistoryBackButton = _canGoBackInWebView;
    final showRouteBackButton = canPopRoute;
    final showBackButton = showRouteBackButton || showHistoryBackButton;
    final showCloseButton = _canGoBackInWebView && canPopRoute;
    final hasCustomLeading =
        showBackButton || showCloseButton || showHomeButton;
    final leadingButtonCount = [
      if (showBackButton) true,
      if (showCloseButton) true,
      if (showHomeButton) true,
    ].length;

    return PopScope<void>(
      canPop: _allowRoutePop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _allowRoutePop) return;
        _handleAppBackPressed();
      },
      child: Scaffold(
        appBar: AppAppBar(
          automaticallyImplyLeading: !hasCustomLeading,
          leadingWidth: hasCustomLeading ? leadingButtonCount * 48 : null,
          leading: hasCustomLeading
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showBackButton)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: _canGoBackInWebView ? '后退' : '返回',
                        onPressed: _handleAppBackPressed,
                      ),
                    if (showCloseButton)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '关闭',
                        onPressed: _popRoute,
                      ),
                    if (showHomeButton)
                      IconButton(
                        icon: const Icon(Icons.home_outlined),
                        tooltip: '返回主页',
                        onPressed: widget.onHomePressed,
                      ),
                  ],
                )
              : null,
          title: Text(widget.title),
          actions: [...widget.appBarActions, _buildWebViewPopupMenu()],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (_hasError)
                    _buildError()
                  else
                    InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(widget.url),
                        headers: widget.initialHeaders.isEmpty
                            ? null
                            : Map<String, String>.from(widget.initialHeaders),
                      ),
                      initialUserScripts: widget.emulateDingTalkEnvironment
                          ? UnmodifiableListView([
                              UserScript(
                                source: '''
(function() {
  var ddMock = {
    ready: function(cb) { if (typeof cb === 'function') setTimeout(cb, 0); },
    error: function(cb) {},
    config: function() {},
    biz: {
      navigation: {
        setTitle: function() {},
        setRight: function() {},
        close: function() {}
      },
      util: {
        openLink: function(opts) {
          if (opts && opts.url) { window.location.href = opts.url; }
        }
      }
    },
    permission: {
      requestAuthCode: function(opts) {
        if (opts && typeof opts.onFail === 'function') {
          opts.onFail({ errorCode: 3, errorMessage: 'not supported' });
        }
      }
    },
    runtime: {
      permission: {
        requestAuthCode: function(opts) {
          if (opts && typeof opts.onFail === 'function') {
            opts.onFail({ errorCode: 3, errorMessage: 'not supported' });
          }
        }
      }
    },
    device: {
      notification: {
        alert: function(opts) {
          if (opts && typeof opts.onSuccess === 'function') opts.onSuccess();
        }
      }
    },
    env: { platform: 'notInDingTalk' },
    version: '7.0.0'
  };
  try {
    Object.defineProperty(window, 'dd', {
      get: function() { return ddMock; },
      set: function() {},
      configurable: false
    });
  } catch(e) {
    window.dd = ddMock;
  }
})();
''',
                                injectionTime:
                                    UserScriptInjectionTime.AT_DOCUMENT_START,
                              ),
                            ])
                          : null,
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        useShouldOverrideUrlLoading: true,
                        useShouldInterceptRequest: true,
                        useHybridComposition: true,
                        allowsInlineMediaPlayback: true,
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                        thirdPartyCookiesEnabled: true,
                        supportMultipleWindows: false,
                        useWideViewPort: true,
                        loadWithOverviewMode: true,
                        userAgent: widget.emulateWeChatEnvironment
                            ? buildEmbeddedWeChatUserAgent(
                                Theme.of(context).platform,
                              )
                            : null,
                        applicationNameForUserAgent:
                            widget.emulateWeChatEnvironment
                            ? null
                            : widget.emulateDingTalkEnvironment
                            ? ' DingTalk/7.0.0'
                            : null,
                      ),
                      onWebViewCreated: (c) {
                        _controller = c;
                        unawaited(_refreshWebViewBackState(c));
                        c.addJavaScriptHandler(
                          handlerName: 'ddReady',
                          callback: (args) => {'success': true},
                        );
                        c.addJavaScriptHandler(
                          handlerName: 'wxScanQRCode',
                          callback: (args) async {
                            final needResult = args.isNotEmpty
                                ? (args.first is String
                                      ? (jsonDecode(
                                              args.first as String,
                                            )['needResult'] ??
                                            0)
                                      : 0)
                                : 0;
                            AppLogger.instance.webview(
                              LogLevel.info,
                              'wxScanQRCode 被调用, needResult=$needResult',
                            );
                            if (!mounted) {
                              return jsonEncode({
                                'cancelled': true,
                                'resultStr': '',
                              });
                            }
                            final result = await Navigator.of(context)
                                .push<Map<String, dynamic>?>(
                                  MaterialPageRoute(
                                    builder: (_) => const QrScannerPage(),
                                  ),
                                );
                            if (result == null) {
                              return jsonEncode({
                                'cancelled': true,
                                'resultStr': '',
                              });
                            }
                            return jsonEncode({
                              'cancelled': false,
                              'resultStr': result['code'] as String? ?? '',
                            });
                          },
                        );
                      },
                      onLoadStart: (_, url) {
                        _trackCurrentUrl(url);
                        _logWebViewLifecycle(
                          'WebView load start: $_currentUrl',
                        );
                        if (!mounted) return;
                        setState(() {
                          _hasError = false;
                          _progress = 0;
                        });
                        unawaited(_refreshWebViewBackState());
                      },
                      onLoadStop: (controller, url) async {
                        if (!mounted) return;
                        final resolvedUrl = await _resolveLoadedUrl(
                          controller,
                          url,
                        );
                        _trackCurrentUrlValue(resolvedUrl);

                        // Service hall SSO strips the fragment id= param during redirect.
                        // Detect landing on /wfw without id and reload the original URL.
                        if (widget.url.contains('/business/ydd/wfw/id=') &&
                            _currentUrl.contains('/business/ydd/wfw') &&
                            !_currentUrl.contains('/id=')) {
                          await controller.loadUrl(
                            urlRequest: URLRequest(url: WebUri(widget.url)),
                          );
                          return;
                        }

                        await _inspectLoadedPage(controller);
                        await _refreshWebViewBackState(controller);

                        final callback = widget.onLoadStop;
                        if (callback != null) {
                          try {
                            await callback(controller, _currentUrl);
                          } on MissingPluginException {
                            // WebView 平台通道尚未就绪，跳过回调。
                          } catch (error, stackTrace) {
                            AppLogger.instance.webview(
                              LogLevel.warn,
                              'WebView load-stop 回调失败：$_currentUrl',
                              error: error,
                              stackTrace: stackTrace,
                            );
                          }
                        }
                      },
                      onUpdateVisitedHistory: (controller, url, _) {
                        _trackCurrentUrl(url);
                        unawaited(_refreshWebViewBackState(controller));
                      },
                      shouldOverrideUrlLoading: (controller, navigationAction) async {
                        final uri = navigationAction.request.url?.uriValue;
                        if (uri == null) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        final requestCallback = widget.onNavigationRequest;
                        if (requestCallback != null) {
                          final policy = await requestCallback(controller, uri);
                          if (policy != null) return policy;
                        }

                        final scheme = uri.scheme.toLowerCase();
                        if (scheme == 'http' || scheme == 'https') {
                          return NavigationActionPolicy.ALLOW;
                        }

                        if (isSafeExternalScheme(scheme)) {
                          await launchExternalUriFromWebView(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        AppLogger.instance.webview(
                          LogLevel.warn,
                          'WebView 拦截非安全或未知 Scheme 跳转: $scheme (url: ${scrubSensitiveUrl(uri.toString())})',
                        );
                        return NavigationActionPolicy.CANCEL;
                      },
                      onConsoleMessage: (controller, consoleMessage) {
                        _handleConsoleMessage(controller, consoleMessage);
                      },
                      shouldInterceptRequest: (controller, request) async {
                        final uri = request.url.uriValue;

                        if (_isDeniedWeChatSdkRequest(uri)) {
                          _logWebViewLifecycle(
                            'WebView 拦截被 WebVPN 拒绝的微信 SDK，返回兼容 stub: $uri',
                          );
                          return _buildWeChatSdkStubResponse();
                        }

                        return null;
                      },
                      onProgressChanged: (_, p) {
                        if (!mounted) return;
                        setState(() => _progress = p / 100);
                      },
                      onReceivedHttpError: (_, request, response) {
                        if (!(request.isForMainFrame ?? false)) return;

                        AppLogger.instance.webview(
                          LogLevel.error,
                          'WebView HTTP 错误: ${response.statusCode} ${response.reasonPhrase ?? ''} url=${request.url}',
                        );

                        if (!mounted) return;
                        setState(() {
                          _hasError = true;
                          _canGoBackInWebView = false;
                          _controller = null;
                          _progress = 0;
                        });
                      },
                      onReceivedError: (_, request, error) {
                        if (!(request.isForMainFrame ?? false)) return;

                        AppLogger.instance.webview(
                          LogLevel.error,
                          'WebView 加载失败: code=${error.type} desc=${error.description} url=${request.url}',
                        );

                        if (!mounted) return;
                        setState(() {
                          _hasError = true;
                          _canGoBackInWebView = false;
                          _controller = null;
                          _progress = 0;
                        });
                      },
                    ),
                  if (_progress < 1 && !_hasError)
                    LinearProgressIndicator(value: _progress),
                  _buildWebViewNavigationBar(),
                ],
              ),
            ),
            _buildQuickFillBar(),
          ],
        ),
      ),
    );
  }

  // UI helper widgets are split into a part file to keep source files under 1000 lines.
}
