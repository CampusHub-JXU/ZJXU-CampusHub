import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';

/// 体测成绩（学生服务平台）。
///
/// 学校体测系统「学生服务平台」原本藏在服务大厅深处，一学期只用两次；
/// 0.7 起作为独立入口，经 WebVPN 的受保护 WebView 访问。
///
/// 关键点（2026-09-12 设备实测）：
/// * 站点是 `POST /spQuery` + `method=<功能>` 的 JSP 应用（`healthscore` 体测
///   成绩、`bespeakRecord` 预约记录、`notTestList` 待测名单…），走 WebVPN 资源
///   预热即可打开菜单页；
/// * 它的 SSO 面向钉钉工作台：页面会调用 `dd.permission.requestAuthCode`，
///   若注入钉钉模拟（`emulateDingTalkEnvironment`）会拿到 `errorCode 3` 而卡在
///   登录中，因此这里显式关闭模拟（与官方付款码页同一策略）。
class PhysicalTestPage extends StatelessWidget {
  const PhysicalTestPage({super.key});

  static const titleText = '体测成绩';
  static const homeUrl =
      'https://webvpn.zjxu.edu.cn/http/77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b/weixin/main.jsp';
  static const loginDescription = '体测成绩经 WebVPN 访问，请先完成统一认证登录';

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: titleText,
      url: homeUrl,
      warmUpAsResource: true,
      emulateDingTalkEnvironment: false,
      loginDescription: loginDescription,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
