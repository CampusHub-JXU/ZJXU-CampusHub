import 'package:flutter/material.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class ServiceHallPage extends StatelessWidget {
  const ServiceHallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const UnifiedAuthProtectedWebViewPage(
      title: '服务大厅',
      url:
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
      loginDescription: '服务大厅使用统一认证登录，账号为校园一卡通号',
    );
  }
}
