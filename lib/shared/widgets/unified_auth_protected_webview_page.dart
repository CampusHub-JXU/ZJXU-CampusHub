import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/unified_auth.dart';
import 'unified_auth_login_widget.dart';
import 'webview_page.dart';

class UnifiedAuthProtectedWebViewPage extends StatefulWidget {
  const UnifiedAuthProtectedWebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.serviceUrl = UnifiedAuthService.defaultServiceUrl,
    this.loginDescription = '账号为校园一卡通号',
    this.onLoadStop,
  });

  final String title;
  final String url;
  final String serviceUrl;
  final String loginDescription;
  final WebViewLoadStopCallback? onLoadStop;

  @override
  State<UnifiedAuthProtectedWebViewPage> createState() =>
      _UnifiedAuthProtectedWebViewPageState();
}

class _UnifiedAuthProtectedWebViewPageState
    extends State<UnifiedAuthProtectedWebViewPage> {
  late bool _authenticated;

  @override
  void initState() {
    super.initState();
    _authenticated = UnifiedAuthService.instance.isLoggedIn;
  }

  void _onLoginSuccess() {
    if (!mounted) return;
    setState(() => _authenticated = true);
  }

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    final uri = Uri.tryParse(currentUrl);
    final isUnifiedAuthLogin =
        uri != null &&
        uri.host.toLowerCase() == 'newca.zjxu.edu.cn' &&
        uri.path.toLowerCase().contains('/cas/login');

    if (isUnifiedAuthLogin) {
      UnifiedAuthService.instance.markLoggedOut();
      if (mounted) {
        setState(() => _authenticated = false);
      }
      return;
    }

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
      body: UnifiedAuthLoginWidget(
        serviceUrl: widget.serviceUrl,
        title: '登录统一认证',
        description: widget.loginDescription,
        onLoginSuccess: _onLoginSuccess,
      ),
    );
  }
}
