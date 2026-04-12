import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/webvpn_protected_webview_page.dart';

class ServiceHallPage extends StatelessWidget {
  const ServiceHallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return WebVpnProtectedWebViewPage(
      title: '服务大厅',
      url:
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
