import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

typedef WebViewLoadStopCallback =
    Future<void> Function(InAppWebViewController controller, String currentUrl);

/// Reusable full-screen WebView page with progress bar and error handling.
class WebViewPage extends StatefulWidget {
  const WebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.onLoadStop,
  });

  final String title;
  final String url;
  final WebViewLoadStopCallback? onLoadStop;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  static const _serviceHallHomeUrl =
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home';
  static const _serviceHallHost = 'mobilehall.zjxu.edu.cn';

  double _progress = 0;
  bool _hasError = false;
  bool _hasShownEnvHint = false;
  bool _hasFallbackToHome = false;
  late String _currentUrl;
  InAppWebViewController? _controller;

  bool get _isCampusCardDeepLink =>
      widget.url.contains('/business/ydd/wfw/id=');

  bool get _isCurrentCampusCardPage {
    final uri = Uri.tryParse(_currentUrl);
    if (uri == null) return false;
    if (uri.host.toLowerCase() != _serviceHallHost) return false;
    return _currentUrl.contains('/business/ydd/wfw');
  }

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
  }

  void _trackCurrentUrl(WebUri? url) {
    final value = url?.toString();
    if (value == null || value.isEmpty) return;

    _currentUrl = value;
  }

  Future<void> _injectDingTalkBridge(InAppWebViewController controller) async {
    await controller.evaluateJavascript(
      source: '''
      window.dd = window.dd || {};
      window.dd.biz = window.dd.biz || {};
      window.dd.ready = function(callback) {
        if (callback) callback();
      };
      window.dd.error = function(callback) {};
      window.dd.biz.navigation = window.dd.biz.navigation || {};
      window.dd.biz.navigation.setTitle = function() {};
      window.dd.biz.util = window.dd.biz.util || {};
      window.dd.biz.util.openLink = function() {};
      window.dd.device = window.dd.device || {};
      window.dd.device.notification = window.dd.device.notification || {};
      window.dd.device.notification.alert = function() {};
      console.log('[DingTalk Bridge] Injected');
    ''',
    );
  }

  void _showHint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _reloadCurrentPage() async {
    if (_hasError) {
      setState(() {
        _hasError = false;
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

    debugPrint('WebView console [${consoleMessage.messageLevel}]: $message');

    if (!_hasShownEnvHint && message.contains('notInDingTalk')) {
      _hasShownEnvHint = true;
      _showHint('当前页面依赖钉钉环境，部分功能可能受限');
    }

    final lowerMessage = message.toLowerCase();

    if (_isCampusCardDeepLink &&
        !_hasFallbackToHome &&
        _isCurrentCampusCardPage &&
        lowerMessage.contains('syntaxerror') &&
        lowerMessage.contains("unexpected token ')")) {
      _fallbackToServiceHallHome(controller, '校园卡页面脚本异常，已切换到服务大厅首页');
      return;
    }

    if (_isCampusCardDeepLink &&
        !_hasFallbackToHome &&
        _isCurrentCampusCardPage &&
        lowerMessage.contains('laytpl error') &&
        lowerMessage.contains('no data')) {
      _fallbackToServiceHallHome(controller, '校园卡入口返回空数据，已切换到服务大厅首页');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reloadCurrentPage,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_hasError)
            _buildError()
          else
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                useShouldOverrideUrlLoading: true,
                allowsInlineMediaPlayback: true,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                thirdPartyCookiesEnabled: true,
                supportMultipleWindows: false,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                applicationNameForUserAgent: ' DingTalk/7.0.0',
              ),
              onWebViewCreated: (c) {
                _controller = c;
                c.addJavaScriptHandler(
                  handlerName: 'ddReady',
                  callback: (args) => {'success': true},
                );
              },
              onLoadStart: (_, url) => _trackCurrentUrl(url),
              onLoadStop: (controller, url) async {
                _trackCurrentUrl(url);
                await _injectDingTalkBridge(controller);

                final callback = widget.onLoadStop;
                if (callback != null) {
                  await callback(controller, _currentUrl);
                }
              },
              onUpdateVisitedHistory: (_, url, _) => _trackCurrentUrl(url),
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url?.uriValue;
                if (uri == null) return NavigationActionPolicy.ALLOW;

                final scheme = uri.scheme.toLowerCase();
                if (scheme == 'http' || scheme == 'https') {
                  return NavigationActionPolicy.ALLOW;
                }

                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                return NavigationActionPolicy.CANCEL;
              },
              onConsoleMessage: (controller, consoleMessage) {
                _handleConsoleMessage(controller, consoleMessage);
              },
              onProgressChanged: (_, p) {
                setState(() => _progress = p / 100);
              },
              onReceivedError: (_, request, _) {
                if (!(request.isForMainFrame ?? false)) return;
                setState(() {
                  _hasError = true;
                  _controller = null;
                  _progress = 0;
                });
              },
            ),
          if (_progress < 1 && !_hasError)
            LinearProgressIndicator(value: _progress),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('页面加载失败'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _reloadCurrentPage, child: const Text('重试')),
        ],
      ),
    );
  }
}
