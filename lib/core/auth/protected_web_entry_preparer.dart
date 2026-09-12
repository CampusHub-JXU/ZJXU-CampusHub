import 'dart:async';

import '../network/dio_client.dart';
import 'cas_auth_broker.dart';
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

/// 受保护 Web 入口的统一准备流程（PRD 0.7.0 §27 / §32）。
///
/// 校外访问校内业务页时，CAS 主会话、WebVPN（wengine）网关会话、业务侧
/// CAS service 三者缺一不可：只有三者都就绪，页面自身的 SSO 跳转才会直接
/// 带票回跳，否则会停在登录页（服务大厅曾因此报 `{"errorCode":3,"not supported"}`）。
///
/// 与校园卡账单页 `CampusCardService.prepareStatusPage` 同一套顺序；
/// 目标 URL 绝不能再当作 CAS service 传给 [CasSession.ensure]。
class ProtectedWebEntryPreparer {
  ProtectedWebEntryPreparer._();

  static Future<String> prepare({
    required String targetUrl,
    required String serviceUrl,
    String gatewayTimeoutMessage = '网关暂时无法连接',
    String authTimeoutMessage = '统一认证暂时无法连接',
  }) async {
    await DioClient.instance.ensureInitialized();
    await UnifiedAuthService.instance.restoreSession(syncWebViewCookies: false);
    if (!UnifiedAuthService.instance.isLoggedIn) {
      throw const CasAuthExpiredException();
    }

    final gateway = await ZhengfangAuth.instance
        .ensureWebVpnGatewaySessionResult(
          syncWebViewCookies: true,
          targetUrl: targetUrl,
        );
    if (gateway.ready == false) throw const CasAuthExpiredException();
    if (gateway.ready == null) throw TimeoutException(gatewayTimeoutMessage);

    final sessionStatus = await CasSession.ensure(
      serviceUrl,
      syncWebViewCookies: false,
    );
    if (sessionStatus == CasSessionStatus.inactive) {
      throw const CasAuthExpiredException();
    }
    if (sessionStatus == CasSessionStatus.unknown) {
      throw TimeoutException(authTimeoutMessage);
    }

    final url = gateway.selectedMode == ZhengfangMode.webVpn
        ? ZhengfangAuth.instance.buildWebVpnProxyUrl(targetUrl)
        : targetUrl;
    await UnifiedAuthService.instance.syncCookiesToWebViewForUrl(url);
    return url;
  }
}
