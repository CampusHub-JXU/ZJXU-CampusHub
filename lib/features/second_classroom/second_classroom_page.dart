import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../shared/widgets/webvpn_protected_webview_page.dart';

class SecondClassroomPage extends StatefulWidget {
  const SecondClassroomPage({super.key});

  static const authEntryUrl =
      'https://twdekt.zjxu.edu.cn/dekt/?_auth_provider_=cn.xht100.skylake.modules.dd.DingDingAuthProvider&dd_code=';
  static const initialUrl = 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0';

  @override
  State<SecondClassroomPage> createState() => _SecondClassroomPageState();
}

class _SecondClassroomPageState extends State<SecondClassroomPage> {
  static const _wechatLoginHosts = {'open.weixin.qq.com', 'wx.tenpay.com'};

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    final lowerUrl = currentUrl.toLowerCase();
    if (!lowerUrl.contains('/dekt/wx/index')) {
      return;
    }

    try {
      final userState = await controller.evaluateJavascript(
        source: '''
(() => {
  try {
    const text = document.body ? document.body.innerText || '' : '';
    return {
      href: location.href,
      hasAnonymous: text.includes('ANONYMOUS'),
      hasGuest: text.includes('游客'),
      hasMyPage: text.includes('我的'),
    };
  } catch (e) {
    return { href: location.href, hasAnonymous: false, hasGuest: false, hasMyPage: false };
  }
})();
''',
      );

      AppLogger.instance.webview(LogLevel.info, '第二课堂页面状态: $userState');
    } catch (error) {
      AppLogger.instance.webview(LogLevel.warn, '读取第二课堂页面状态失败: $error');
    }
  }

  Future<NavigationActionPolicy?> _handleNavigationRequest(
    InAppWebViewController controller,
    Uri uri,
  ) async {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isWeChatOauth =
        host == 'open.weixin.qq.com' &&
        path.contains('/connect/oauth2/authorize');

    if (isWeChatOauth || _wechatLoginHosts.contains(host)) {
      AppLogger.instance.webview(LogLevel.info, '第二课堂命中微信登录跳转: $uri');
      return NavigationActionPolicy.ALLOW;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return WebVpnProtectedWebViewPage(
      title: '第二课堂',
      url: SecondClassroomPage.authEntryUrl,
      emulateWeChatEnvironment: true,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
      onLoadStop: _handleLoadStop,
      onNavigationRequest: _handleNavigationRequest,
    );
  }
}
