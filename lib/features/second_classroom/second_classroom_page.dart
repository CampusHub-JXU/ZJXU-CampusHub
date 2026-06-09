import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../shared/widgets/webview_page.dart';
import 'second_classroom_wechat_launcher.dart';

bool isSecondClassroomWeChatAuthUri(Uri uri) {
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  final isWeChatOauth =
      host == 'open.weixin.qq.com' &&
      path.contains('/connect/oauth2/authorize');
  return isWeChatOauth || _secondClassroomWeChatLoginHosts.contains(host);
}

bool isSecondClassroomAnonymousState(Object? userState) {
  if (userState is! Map) return false;

  final hasAnonymous = userState['hasAnonymous'] == true;
  final hasGuest = userState['hasGuest'] == true;
  return hasAnonymous || hasGuest;
}

const _secondClassroomWeChatLoginHosts = {
  'open.weixin.qq.com',
  'wx.tenpay.com',
};

bool isSecondClassroomAuthProviderEntryUrl(String currentUrl) {
  final uri = Uri.tryParse(currentUrl);
  if (uri == null) return false;

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  return host == 'twdekt.zjxu.edu.cn' &&
      path == '/dekt/' &&
      uri.queryParameters.containsKey('_auth_provider_');
}

bool isSecondClassroomLandingRootUrl(String currentUrl) {
  final uri = Uri.tryParse(currentUrl);
  if (uri == null) return false;

  final host = uri.host.toLowerCase();
  final normalizedPath = uri.path.toLowerCase();
  return host == 'twdekt.zjxu.edu.cn' &&
      (normalizedPath == '/dekt/' || normalizedPath == '/dekt');
}

class SecondClassroomPage extends StatefulWidget {
  const SecondClassroomPage({super.key});

  static const authEntryUrl =
      'https://twdekt.zjxu.edu.cn/dekt/?_auth_provider_=cn.xht100.skylake.modules.dd.DingDingAuthProvider&dd_code=';
  static const initialUrl = 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0';

  @override
  State<SecondClassroomPage> createState() => _SecondClassroomPageState();
}

class _SecondClassroomPageState extends State<SecondClassroomPage> {
  bool _redirectingToWechatPage = false;
  bool _openingInWeChat = false;
  bool _hasShownWechatOauthHint = false;

  String get _wechatPageUrl => SecondClassroomPage.initialUrl;

  Future<void> _openInWeChat(
    String url, {
    String successMessage = '已打开微信，请在微信中完成第二课堂授权',
  }) async {
    if (_openingInWeChat) return;
    _openingInWeChat = true;
    AppLogger.instance.webview(LogLevel.info, '第二课堂打开微信授权页: $url');
    try {
      final opened = await SecondClassroomWechatLauncher.instance.openUrl(url);
      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(opened ? successMessage : '未能打开微信，请确认已安装微信后重试')),
      );
    } finally {
      _openingInWeChat = false;
    }
  }

  void _showWechatOauthHint() {
    if (!mounted || _hasShownWechatOauthHint) return;
    _hasShownWechatOauthHint = true;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('第二课堂需要微信网页授权，当前页面仍是匿名态'),
        action: SnackBarAction(
          label: '微信打开',
          onPressed: () {
            _openInWeChat(_wechatPageUrl);
          },
        ),
      ),
    );
  }

  bool _isProviderEntryUrl(String currentUrl) {
    return isSecondClassroomAuthProviderEntryUrl(currentUrl);
  }

  bool _isLandingRootUrl(String currentUrl) {
    return isSecondClassroomLandingRootUrl(currentUrl);
  }

  Future<void> _redirectToWechatPage(
    InAppWebViewController controller, {
    required String reason,
  }) async {
    if (_redirectingToWechatPage) return;
    _redirectingToWechatPage = true;
    AppLogger.instance.webview(LogLevel.info, '第二课堂切回微信页: $reason');
    try {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_wechatPageUrl)),
      );
    } finally {
      _redirectingToWechatPage = false;
    }
  }

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    final lowerUrl = currentUrl.toLowerCase();

    if (_isProviderEntryUrl(currentUrl) || _isLandingRootUrl(currentUrl)) {
      await _redirectToWechatPage(controller, reason: currentUrl);
      return;
    }

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

      if (isSecondClassroomAnonymousState(userState)) {
        AppLogger.instance.webview(LogLevel.warn, '第二课堂当前为匿名态，需要微信网页授权');
        _showWechatOauthHint();
      }
    } catch (error) {
      AppLogger.instance.webview(LogLevel.warn, '读取第二课堂页面状态失败: $error');
    }
  }

  Future<NavigationActionPolicy?> _handleNavigationRequest(
    InAppWebViewController controller,
    Uri uri,
  ) async {
    if (isSecondClassroomWeChatAuthUri(uri)) {
      AppLogger.instance.webview(LogLevel.info, '第二课堂命中微信 OAuth 跳转: $uri');
      await _openInWeChat(uri.toString(), successMessage: '已打开微信，请在微信中确认授权');
      return NavigationActionPolicy.CANCEL;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return WebViewPage(
      title: '第二课堂',
      url: SecondClassroomPage.initialUrl,
      emulateWeChatEnvironment: true,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
      appBarActions: [
        IconButton(
          icon: const Icon(Icons.open_in_new_rounded),
          tooltip: '在微信中打开',
          onPressed: () {
            _openInWeChat(_wechatPageUrl);
          },
        ),
      ],
      onLoadStop: _handleLoadStop,
      onNavigationRequest: _handleNavigationRequest,
    );
  }
}
