import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/protected_web_entry_preparer.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'library_service.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  static const titleText = '图书馆';

  /// 图书馆站点根；校外由 [prepareEntry] 改写为 WebVPN 网关地址。
  ///
  /// 不再使用 `Info/Thirdparty/ssoFromDingDing`：该入口面向钉钉工作台，
  /// 依赖 `dd.runtime.permission.requestAuthCode` 返回真实 authCode，非钉钉
  /// 容器无法满足——App 注入的 dd mock 会直接 onFail，页面随即提示
  /// `{"errorCode":3,"not supported"}`（该文案是 App 自己造的，不是服务端拒绝）。
  /// 设备实测（2026-09-12）：`https://webvpn.zjxu.edu.cn/https/<libapp>/`
  /// 可直接打开图书馆站点（标题「嘉兴大学图书馆」，自带一卡通/密码登录页）。
  static const libraryUrl = 'https://libapp.zjxu.edu.cn/';

  static const authLoginDescription = '图书馆经 WebVPN 访问，请先完成统一认证登录';

  /// 测试替身：跳过真实网关/CAS 网络准备。
  @visibleForTesting
  static Future<String> Function()? debugPrepareEntryOverride;

  /// 站内入口准备（PRD 0.7.0 §32）。
  ///
  /// 设备实验（2026-09-12）：`ssoFromDingDing` 入口必须返回真实钉钉 authCode
  /// 才继续，非钉钉容器无解；而 WebVPN 网关下的站点根可直接打开图书馆并进入
  /// 其自带的一卡通/密码登录页，因此入口改为站点根 + 固定走 WebVPN 代理。
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
      enableLoginQuickFill: true,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
      // 书目详情改由原生页接管（PRD 0.7.0 §34）：汇图接口免登录即可给出
      // 索书号、馆藏位置与可借册数，比 H5 页面更直接。
      onNavigationRequest: (controller, uri) async {
        final bid = LibraryService.bidFromDetailUrl(uri);
        if (bid == null) return null;
        await context.pushNamed(
          'library-book',
          pathParameters: <String, String>{'bid': bid},
        );
        return NavigationActionPolicy.CANCEL;
      },
    );
  }
}
