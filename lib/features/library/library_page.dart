import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/protected_web_entry_preparer.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  static const titleText = '图书馆';

  /// 直连入口；WebVPN 模式下由 [prepareEntry] 改写为网关地址。
  static final libraryUrl = CasService.librarySso.serviceUrl;

  static const authLoginDescription = '图书馆经 WebVPN 访问，请先完成统一认证登录';

  /// 测试替身：跳过真实网关/CAS 网络准备。
  @visibleForTesting
  static Future<String> Function()? debugPrepareEntryOverride;

  /// 站内入口准备（PRD 0.7.0 §32）。
  ///
  /// 设备抓包（2026-09-12）显示：服务大厅内「掌上图书馆」直接跳
  /// `libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing`，校外环境
  /// `net::ERR_CONNECTION_CLOSED`；libapp 必须先建好 WebVPN 网关会话与
  /// 图书馆 CAS service 会话才能打开。
  static Future<String> prepareEntry() async {
    final override = debugPrepareEntryOverride;
    if (override != null) return override();

    return ProtectedWebEntryPreparer.prepare(
      targetUrl: libraryUrl,
      serviceUrl: CasService.librarySso.serviceUrl,
      // 设备日志：libapp 直连探测 302「可达」，但 WebView 直连必被断开
      // （net::ERR_CONNECTION_CLOSED），所以图书馆固定走 WebVPN 代理。
      forceWebVpn: true,
      gatewayTimeoutMessage: '图书馆网关暂时无法连接',
      authTimeoutMessage: '图书馆认证暂时无法连接',
    );
  }

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: titleText,
      url: libraryUrl,
      serviceUrl: CasService.librarySso.serviceUrl,
      prepareAuthenticatedUrl: prepareEntry,
      loginDescription: authLoginDescription,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
