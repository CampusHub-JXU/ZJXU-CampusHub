import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import 'login_widget.dart';
import 'webview_page.dart';

bool isZhengfangLoginUrl(String currentUrl) {
  final normalizedUrl = currentUrl.trim().toLowerCase();
  if (normalizedUrl.isEmpty) return false;
  return normalizedUrl.contains('/xtgl/login_slogin.html');
}

class ZhengfangProtectedWebViewPage extends StatefulWidget {
  const ZhengfangProtectedWebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.loginDescription = '账号为学号',
    this.onLoadStop,
  });

  final String title;
  final String url;
  final String loginDescription;
  final WebViewLoadStopCallback? onLoadStop;

  @override
  State<ZhengfangProtectedWebViewPage> createState() =>
      _ZhengfangProtectedWebViewPageState();
}

class _ZhengfangProtectedWebViewPageState
    extends State<ZhengfangProtectedWebViewPage> {
  late bool _authenticated;
  bool _resyncing = false;

  @override
  void initState() {
    super.initState();
    _authenticated = ZhengfangAuth.instance.isLoggedIn;
  }

  Future<void> _onLoginSuccess() async {
    await ZhengfangAuth.instance.syncCookiesToWebView();
    if (!mounted) return;
    setState(() {
      _authenticated = true;
      _resyncing = false;
    });
  }

  Future<void> _showNativeLogin() async {
    ZhengfangAuth.instance.markLoggedOut();
    if (!mounted) return;
    setState(() {
      _authenticated = false;
      _resyncing = false;
    });
  }

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (isZhengfangLoginUrl(currentUrl)) {
      AppLogger.instance.debug('WebView 跳转到教务登录页，尝试恢复会话');

      if (_resyncing || !ZhengfangAuth.instance.isLoggedIn) {
        AppLogger.instance.info('教务 WebView 会话恢复失败，切换为应用内登录');
        await _showNativeLogin();
        return;
      }

      _resyncing = true;
      try {
        await ZhengfangAuth.instance.syncCookiesToWebView();
        AppLogger.instance.debug('教务 Cookie 重同步完成，重新加载 WebView');
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(widget.url)),
        );
      } catch (error) {
        AppLogger.instance.error('教务 Cookie 重同步失败: $error');
        await _showNativeLogin();
      }
      return;
    }

    _resyncing = false;
    final callback = widget.onLoadStop;
    if (callback != null) {
      await callback(controller, currentUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_authenticated) {
      return WebViewPage(
        title: widget.title,
        url: widget.url,
        onLoadStop: _handleLoadStop,
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: LoginWidget(onLoginSuccess: _onLoginSuccess),
    );
  }
}
