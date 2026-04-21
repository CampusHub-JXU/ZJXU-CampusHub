import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class ServiceHallPage extends StatelessWidget {
  const ServiceHallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: '服务大厅',
      url:
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
      serviceUrl: 'https://newca.zjxu.edu.cn/casClient/login/ydd',
      loginDescription: '服务大厅仅支持校园网内直连访问，请连接校园网后登录统一认证',
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
