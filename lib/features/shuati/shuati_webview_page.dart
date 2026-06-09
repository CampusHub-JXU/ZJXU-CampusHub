import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/shortcut/app_shortcut_service.dart';
import 'shuati_asset_service.dart';

class ShuatiWebViewPage extends StatefulWidget {
  const ShuatiWebViewPage({super.key});

  @override
  State<ShuatiWebViewPage> createState() => _ShuatiWebViewPageState();
}

enum _ShuatiWebViewMenuAction { addShortcut }

class _ShuatiWebViewPageState extends State<ShuatiWebViewPage> {
  final _assetService = ShuatiAssetService();

  InAppWebViewController? _controller;
  double _progress = 0;
  bool _hasError = false;
  bool _canWebViewGoBack = false;
  String? _errorMessage;

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _hasError = false;
      _progress = 0;
    });
    await controller.reload();
  }

  Future<void> _handleBackPressed() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      await _refreshBackState(controller);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).maybePop();
  }

  Future<void> _refreshBackState([InAppWebViewController? controller]) async {
    final target = controller ?? _controller;
    if (target == null) return;
    final canGoBack = await target.canGoBack();
    if (!mounted || canGoBack == _canWebViewGoBack) return;
    setState(() {
      _canWebViewGoBack = canGoBack;
    });
  }

  Future<void> _requestShortcut() async {
    final result = await AppShortcutService.instance
        .requestShuatiShortcutResult();
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.message),
        action: result.canOpenPermissionSettings
            ? SnackBarAction(
                label: '去设置',
                onPressed: () {
                  AppShortcutService.instance.openShortcutPermissionSettings();
                },
              )
            : null,
      ),
    );
  }

  void _handleMainFrameError(String message) {
    if (!mounted) return;
    setState(() {
      _hasError = true;
      _errorMessage = message;
      _progress = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final routeCanPop = Navigator.of(context).canPop();
    final leadingButtonCount = routeCanPop ? 2 : 1;
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;

    return PopScope<void>(
      canPop: !_canWebViewGoBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_handleBackPressed());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('刷题助手'),
          automaticallyImplyLeading: false,
          leadingWidth: leadingButtonCount * 48,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (routeCanPop)
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回',
                  onPressed: _handleBackPressed,
                ),
              IconButton(
                icon: const Icon(Icons.home_outlined),
                tooltip: '返回主页',
                onPressed: () => context.goNamed('home'),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: _reload,
            ),
            if (isAndroid)
              PopupMenuButton<_ShuatiWebViewMenuAction>(
                tooltip: '更多操作',
                onSelected: (action) {
                  switch (action) {
                    case _ShuatiWebViewMenuAction.addShortcut:
                      _requestShortcut();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<_ShuatiWebViewMenuAction>(
                    value: _ShuatiWebViewMenuAction.addShortcut,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.add_to_home_screen_outlined),
                      title: Text('添加到桌面'),
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: ShuatiAssetService.initialWebUri,
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                cacheEnabled: true,
                useShouldInterceptRequest: true,
                useShouldOverrideUrlLoading: true,
                useHybridComposition: true,
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
                supportMultipleWindows: false,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                unawaited(_refreshBackState(controller));
              },
              onLoadStart: (controller, url) {
                if (!mounted) return;
                setState(() {
                  _hasError = false;
                  _errorMessage = null;
                  _progress = 0;
                });
                unawaited(_refreshBackState(controller));
              },
              onLoadStop: (controller, url) {
                if (!mounted) return;
                setState(() {
                  _progress = 1;
                });
                unawaited(_refreshBackState(controller));
              },
              onUpdateVisitedHistory: (controller, url, _) {
                unawaited(_refreshBackState(controller));
              },
              onProgressChanged: (_, progress) {
                if (!mounted) return;
                setState(() {
                  _progress = progress / 100;
                });
              },
              shouldInterceptRequest: (controller, request) {
                return _assetService.responseForRequest(request);
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url?.uriValue;
                if (uri == null) {
                  return NavigationActionPolicy.ALLOW;
                }
                if (ShuatiAssetService.isInternalUri(uri)) {
                  return NavigationActionPolicy.ALLOW;
                }
                final scheme = uri.scheme.toLowerCase();
                if (scheme == 'http' || scheme == 'https') {
                  return NavigationActionPolicy.ALLOW;
                }
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                return NavigationActionPolicy.CANCEL;
              },
              onReceivedError: (controller, request, error) {
                if (request.isForMainFrame == false) return;
                _handleMainFrameError(error.description);
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                if (request.isForMainFrame == false) return;
                final statusCode = errorResponse.statusCode;
                _handleMainFrameError('页面加载失败：HTTP $statusCode');
              },
            ),
            if (_progress > 0 && _progress < 1)
              Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(value: _progress),
              ),
            if (_hasError)
              Positioned.fill(
                child: _ShuatiWebViewErrorState(
                  message: _errorMessage ?? '页面加载失败',
                  onRetry: _reload,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ShuatiWebViewErrorState extends StatelessWidget {
  const _ShuatiWebViewErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.web_asset_off_outlined,
                size: 42,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                '刷题助手暂时无法打开',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
