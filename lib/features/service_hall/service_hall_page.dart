import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/actions/campus_action_executor.dart';
import '../../core/auth/cas_auth_broker.dart';
import '../../core/logging/app_logger.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class ServiceHallPage extends StatefulWidget {
  const ServiceHallPage({super.key});

  static const titleText = '服务大厅';
  static const homeUrl =
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home';

  /// service URL 统一由 [CasService] 注册表提供，不再本地硬编码。
  static final authServiceUrl = CasService.ydd.serviceUrl;
  static const authLoginDescription = '服务大厅仅支持校园网内直连访问，请连接校园网后登录统一认证';

  @override
  State<ServiceHallPage> createState() => _ServiceHallPageState();
}

class _ServiceHallPageState extends State<ServiceHallPage> {
  bool _openingInWeChat = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_openInWeChat());
    });
  }

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
      url: ServiceHallPage.homeUrl,
      serviceUrl: ServiceHallPage.authServiceUrl,
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
