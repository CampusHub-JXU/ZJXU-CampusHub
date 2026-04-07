import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/app_logger.dart';

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
    final lowerMessage = message.toLowerCase();

    if (lowerMessage.contains('dingtalk bridge')) {
      return;
    }

    if (!_hasShownEnvHint && lowerMessage.contains('notindingtalk')) {
      _hasShownEnvHint = true;
      AppLogger.instance.info('WebView 环境提示：$_currentUrl 需要钉钉环境');
      _showHint('当前页面依赖钉钉环境，部分功能可能受限');
      return;
    }

    final errorLike =
        consoleMessage.messageLevel == ConsoleMessageLevel.ERROR ||
        consoleMessage.messageLevel == ConsoleMessageLevel.WARNING ||
        lowerMessage.contains('error') ||
        lowerMessage.contains('exception') ||
        lowerMessage.contains('failed');

    if (errorLike) {
      AppLogger.instance.error(
        'WebView console [${consoleMessage.messageLevel}] $_currentUrl :: $message',
      );
    }

  }

  Future<void> _inspectLoadedPage(InAppWebViewController controller) async {
    try {
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
      final title = '${map['title'] ?? ''}'.trim();
      final readyState = '${map['readyState'] ?? ''}'.trim();
      final textLength = int.tryParse('${map['textLength'] ?? 0}') ?? 0;
      final childCount = int.tryParse('${map['childCount'] ?? 0}') ?? 0;

      AppLogger.instance.info(
        'WebView load stop: url=$_currentUrl readyState=$readyState title=${title.isEmpty ? '[empty]' : title} textLength=$textLength childCount=$childCount',
      );

      final isBlankLike = textLength == 0 && childCount == 0 && readyState == 'complete';
      if (!isBlankLike) return;

      AppLogger.instance.error('WebView 疑似白屏：url=$_currentUrl');

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
      AppLogger.instance.debug('WebView 页面快照失败：$_currentUrl :: $error');
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
              initialUserScripts: UnmodifiableListView([
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
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                useShouldOverrideUrlLoading: true,
                useHybridComposition: true,
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
              onLoadStart: (_, url) {
                _trackCurrentUrl(url);
                AppLogger.instance.info('WebView load start: $_currentUrl');
                setState(() {
                  _hasError = false;
                  _progress = 0;
                });
              },
              onLoadStop: (controller, url) async {
                _trackCurrentUrl(url);

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
              onReceivedHttpError: (_, request, response) {
                if (!(request.isForMainFrame ?? false)) return;

                AppLogger.instance.error(
                  'WebView HTTP 错误: ${response.statusCode} ${response.reasonPhrase ?? ''} url=${request.url}',
                );

                setState(() {
                  _hasError = true;
                  _controller = null;
                  _progress = 0;
                });
              },
              onReceivedError: (_, request, error) {
                if (!(request.isForMainFrame ?? false)) return;

                AppLogger.instance.error(
                  'WebView 加载失败: code=${error.type} desc=${error.description} url=${request.url}',
                );

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
