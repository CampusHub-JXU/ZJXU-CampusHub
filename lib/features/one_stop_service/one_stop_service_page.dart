import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';

/// 校务服务（PRD 0.7.0 §28）。
///
/// 与「服务大厅」是两个并列入口，互不合并。0.7 首版经 WebVPN 的受保护
/// WebView 访问；后续再评估原生化。
class OneStopServicePage extends StatelessWidget {
  const OneStopServicePage({super.key});

  static const titleText = '校务服务';
  static const homeUrl =
      'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421e3e05b84692a62486b468ca88d1b203b/';
  static const loginDescription = '校务服务经 WebVPN 访问，请先完成统一认证登录';

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: titleText,
      url: homeUrl,
      serviceUrl: homeUrl,
      loginDescription: loginDescription,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
