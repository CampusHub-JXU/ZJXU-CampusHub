import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';

/// 统一认证（newca CAS）业务接入注册表。
///
/// 全 App 所有通过统一身份认证 CAS 的业务 service 收敛于此，业务层禁止
/// 再散落 service URL 常量或手写 CAS 登录页判定（此前默认 URL 曾在
/// service_hall_page 重复硬编码、失效判定在 notice/epay 等处各写一份）。
///
/// 逐业务动态 service（如通知公告以文章 URL 作为 service）无法穷举进枚举，
/// 直接把 URL 传给 [CasSession.ensure] 即可，但不要另建常量。
enum CasService {
  /// 一卡通移动端默认服务：服务大厅 ydd 通道（电费、「我的」等复用）。
  ydd(UnifiedAuthService.defaultServiceUrl),

  /// 校园卡余额页（FineReport h5 表单）。
  /// CAS service 参数不能带 fragment（#/form），否则 ticket 校验时
  /// service 不匹配导致认证失败。
  campusCardStatus(
    'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form'
    '?op=h5&viewlet=xxkj%252Fmobile%252Fykt.frm',
  ),

  /// 校园卡消费码（服务大厅业务页入口）。
  campusCardPayment(
    'https://newca.zjxu.edu.cn/casClient/login/ydd'
    '?services=business%2Fydd%2Fwfw',
  ),

  /// 图书馆移动端 SSO 入口（目标 URL 本身即 service）。
  librarySso('https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing'),

  /// WebVPN 网关会话（教务两阶段登录的第一阶段，见 ZhengfangAuth）。
  webVpnGateway(ZhengfangAuth.webVpnGatewayServiceUrl);

  const CasService(this.serviceUrl);

  final String serviceUrl;
}

/// 统一认证会话三态。
enum CasSessionStatus {
  /// 会话有效（已通过目标 service 校验）。
  active,

  /// 会话明确失效（服务端返回登录页，或本地无已保存会话）。
  /// 明确失效时 [UnifiedAuthService.validateSession] 内部已标记登出。
  inactive,

  /// 校验请求本身失败（网络异常），无法下结论；调用方自行决定降级策略。
  unknown,
}

/// 统一认证会话确保入口。
///
/// 收敛各业务重复的
/// `restoreSession → isLoggedIn → validateSession → 判空降级` 样板
/// （此前在 campus_card / notice / epay / 受保护 WebView 各写一遍）。
class CasSession {
  CasSession._();

  /// 确保统一认证会话对 [serviceUrl] 可用。
  ///
  /// - [restoreFromStore]：先从安全存储恢复本地会话标记（无网络请求），
  ///   与启动 warm-up 之外直接进入受保护页面的场景兼容。
  /// - [syncWebViewCookies]：校验成功后是否把 Cookie 同步到 WebView。
  ///   需要"同步完成后再继续"的调用方（如 epay 隐藏 WebView）应传 false
  ///   并自行 `await UnifiedAuthService.instance.syncCookiesToWebView()`，
  ///   因为 validateSession 内部的同步是 fire-and-forget 的。
  ///
  /// 返回 [CasSessionStatus] 三态，绝不抛出业务异常（网络异常归入
  /// [CasSessionStatus.unknown]）。
  static Future<CasSessionStatus> ensure(
    String serviceUrl, {
    bool restoreFromStore = true,
    bool syncWebViewCookies = true,
  }) async {
    final auth = UnifiedAuthService.instance;
    if (restoreFromStore) {
      await auth.restoreSession(syncWebViewCookies: false);
    }
    if (!auth.isLoggedIn) return CasSessionStatus.inactive;

    final validated = await auth.validateSession(
      serviceUrl: serviceUrl,
      syncWebViewCookies: syncWebViewCookies,
    );
    if (validated == true) return CasSessionStatus.active;
    return validated == false
        ? CasSessionStatus.inactive
        : CasSessionStatus.unknown;
  }
}

/// 统一认证 CAS 接入的共享判定与异常。
class CasAuthBroker {
  CasAuthBroker._();

  /// 判定一次 HTTP 交换是否命中统一认证登录页/登录跳转。
  ///
  /// 依次检查：最终落地 URL、302/303 的 location（相对 [requestUri] 解析）、
  /// 响应体 HTML。[html] 传 null 时跳过响应体检查（调用方需要先行
  /// 解码或做业务侧前置判断时使用，如 sjjx 的列表页预检）。
  static bool isCasLoginExchange({
    String? realUrl,
    int? statusCode,
    String? location,
    Uri? requestUri,
    String? html,
  }) {
    if (realUrl != null && isUnifiedAuthLoginEntryUrl(realUrl)) return true;

    final code = statusCode ?? 0;
    if ((code == 302 || code == 303) &&
        location != null &&
        location.isNotEmpty) {
      final resolved = requestUri == null
          ? location
          : requestUri.resolve(location).toString();
      if (isUnifiedAuthLoginEntryUrl(resolved)) return true;
    }

    if (html != null && looksLikeUnifiedAuthLoginHtml(html)) return true;
    return false;
  }
}

/// 统一认证会话失效的统一异常。
///
/// CAS 域业务不再各自定义 `XxxAuthExpiredException`；页面层捕获后引导
/// 用户走统一认证登录弹窗即可。
class CasAuthExpiredException implements Exception {
  const CasAuthExpiredException([this.message = '统一认证登录已失效，请重新登录']);

  final String message;

  @override
  String toString() => message;
}
