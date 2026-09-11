import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/actions/campus_action_executor.dart';
import '../../core/logging/app_logger.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class ServiceHallPage extends StatefulWidget {
  const ServiceHallPage({super.key});

  static const titleText = '服务大厅';
  static const homeUrl =
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home';

  /// 站内 WebView 入口：PRD 0.7.0 §27 审计（2026-09-12）发现直连
  /// mobilehall 一律 302 到 WebVPN 网关，旧 CAS service 已失效，因此站内
  /// 必须走 WebVPN 代理地址 + 资源预热建立 wengine/CAS 凭据。
  static const webVpnHomeUrl =
      'https://webvpn.zjxu.edu.cn/http/77726476706e69737468656265737421fdf843952b3560517204c7b6924d367bdd166b13aa07/mportal/start/index.html#/business/ydd/portal/home';
  static const authLoginDescription = '服务大厅经 WebVPN 访问，请先完成统一认证登录';

  @override
  State<ServiceHallPage> createState() => _ServiceHallPageState();
}

class _ServiceHallPageState extends State<ServiceHallPage> {
  bool _openingInWeChat = false;

  // PRD 0.7.0 §27：移除进入只即自动拉起微信，微信入口改为用户明确点击。
  Future<void> _openInWeChat() async {
    if (_openingInWeChat) return;
    setState(() {
      _openingInWeChat = true;
    });

    AppLogger.instance.webview(
      LogLevel.info,
      '服务大厅尝试在微信中打开: ${ServiceHallPage.homeUrl}',
    );

    await CampusActionExecutor.instance.executeWechat(
      context,
      url: ServiceHallPage.homeUrl,
      title: '服务大厅',
      successMessage: '已打开微信，请在学校公众号服务中继续',
    );
    if (!mounted) return;

    setState(() {
      _openingInWeChat = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: ServiceHallPage.titleText,
      url: ServiceHallPage.webVpnHomeUrl,
      warmUpAsResource: true,
      loginDescription: ServiceHallPage.authLoginDescription,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
      appBarActions: [
        IconButton(
          tooltip: '在微信中打开',
          icon: const Icon(Icons.open_in_new),
          onPressed: _openingInWeChat ? null : () => unawaited(_openInWeChat()),
        ),
      ],
    );
  }
}
