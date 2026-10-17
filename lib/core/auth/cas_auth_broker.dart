import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../network/cancel_token_x.dart';
import '../network/dio_client.dart';
import 'login_page_detection.dart' as login_detection;
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

/// 统一认证（newca CAS）业务接入注册表。
///
/// 全 App 所有通过统一身份认证 CAS 的业务 service 收敛于此，业务层禁止
/// 再散落 service URL 常量或手写 CAS 登录页判定（此前默认 URL 曾在
/// service_hall_page 重复硬编码、失效判定在 notice/epay 等处各写一份）。
///
/// service 是服务端注册的 ticket 回调，不一定是业务资源 URL。
/// 通知等资源应使用 [CasAuthBroker.getResource]，跟随站点提供的真实回调。
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

  /// 图书馆移动端 SSO 入口（目标 URL 本身即 service）。
  librarySso('https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing'),

  /// 体测服务（学生服务平台）CAS 回调：ticket 校验后建立该站业务会话。
  /// 资源页（`/weixin/main.jsp`、`/spQuery`）不是 service，禁止传给
  /// [CasSession.ensure]。
  physicalTest('http://jkjy.zjxu.edu.cn/weixin/login.jsp'),

  /// 畅行嘉大（zhx）CAS 回调：ticket 校验后站点签发一次性 tokenId。
  /// 资源入口（`/api/cas_wap_login`、`/api/*`）不是 service，禁止传给
  /// [CasSession.ensure]；WebVPN 路由经 `zhx.zjxu.edu.cn` host 映射
  /// （端口段 `-8443`）改写。
  changxing('http://zhx.zjxu.edu.cn:8443/api/wap/cas_login_back'),

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

  static const Duration defaultResourceBudget = Duration(seconds: 20);

  /// 用统一认证 CookieJar 获取资源，逐跳兑换 ticket 并保存业务 Cookie。
  /// 不提交凭据、不调用 WebView，也不因单个业务失败清除全局 CAS 状态。
  /// [dio] 仅用于注入测试传输；生产调用使用共享 unifiedAuthDio。
  ///
  /// [timeout] 是整条跳转链的总预算（默认 20s）。到期会 cancel 底层
  /// Dio 请求，而不是只丢弃 Future。[cancelToken] 贯穿每跳，调用方可
  /// 在 dispose 时取消。调用方已选好的 [resourceUrl] 原样跟随；本入口
  /// 不做业务 WebVPN 回退。
  ///
  /// [stopAtRedirect] 可选：某一跳 3xx 的解析后 Location 命中时，直接返回
  /// 该 3xx 响应（调用方自行读 `location` 头），不再跟随。
  @visibleForTesting
  static Future<Response<List<int>>> Function(
    String resourceUrl, {
    Dio? dio,
    bool Function(Response<List<int>>)? needsLogin,
    CancelToken? cancelToken,
    Duration? timeout,
    DateTime? deadline,
  })?
  debugGetResourceOverride;

  static Future<Response<List<int>>> getResource(
    String resourceUrl, {
    Dio? dio,
    bool Function(Response<List<int>>)? needsLogin,
    CancelToken? cancelToken,
    Duration timeout = defaultResourceBudget,
    DateTime? deadline,
    bool Function(Uri nextLocation)? stopAtRedirect,
  }) async {
    final override = debugGetResourceOverride;
    if (override != null) {
      return override(
        resourceUrl,
        dio: dio,
        needsLogin: needsLogin,
        cancelToken: cancelToken,
        timeout: timeout,
        deadline: deadline,
      );
    }
    if (dio == null) await DioClient.instance.ensureInitialized();
    final client = dio ?? DioClient.instance.unifiedAuthDio;
    final resource = Uri.parse(resourceUrl);
    var current = resource;
    var completedCasExchange = false;
    var retriedResource = false;
    final budgetEnds = deadline ?? DateTime.now().add(timeout);
    final token = cancelToken ?? CancelToken();
    Timer? budgetTimer;
    if (!token.isCancelled) {
      final remaining = budgetEnds.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        token.cancel('resource budget exceeded');
      } else {
        budgetTimer = Timer(remaining, () {
          if (!token.isCancelled) token.cancel('resource budget exceeded');
        });
      }
    }
    try {
      for (var hop = 0; hop < 16; hop++) {
        token.throwIfCancelled();
        // WebVPN 的 CAS 代理域没有 newca 的 SSO Cookie；回到真实 CAS 域，
        // 保留网关提供的 service 参数，再由其回调建立 WebVPN 会话。
        final proxiedCas = Uri.parse(
          ZhengfangAuth.instance.buildWebVpnProxyUrl(
            'http://newca.zjxu.edu.cn/cas/login',
          ),
        );
        if (current.host == proxiedCas.host &&
            current.path == proxiedCas.path) {
          current = Uri.https(
            'newca.zjxu.edu.cn',
            '/cas/login',
          ).replace(query: current.query);
        }
        final response = await client.getUri<List<int>>(
          current,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
        );
        final status = response.statusCode ?? 0;
        final location = response.headers.value('location');
        if ([301, 302, 303, 307, 308].contains(status)) {
          if (location == null || location.isEmpty) {
            throw StateError('认证重定向缺少目标地址');
          }
          // 必须访问 CAS 登录入口：已有 SSO Cookie 时它会直接签发 ticket。
          // 不能仅凭 URL 含 /cas/login 就判定会话已失效。
          completedCasExchange |= isUnifiedAuthLoginEntryUrl(
            current.toString(),
          );
          final next = current.resolve(location);
          if (next.scheme != 'http' && next.scheme != 'https') {
            throw StateError('认证重定向协议不受支持');
          }
          // 调用方只需要某一跳的 Location（如业务回调把一次性 tokenId 放在
          // 重定向里）：命中即原样返回该 3xx 响应，不再请求下一跳，避免
          // 额外消费 ticket / 一次性参数。
          if (stopAtRedirect?.call(next) ?? false) return response;
          current = next;
          continue;
        }
        final html = utf8.decode(
          response.data ?? const [],
          allowMalformed: true,
        );
        final loginRequired =
            needsLogin?.call(response) ??
            isCasLoginExchange(realUrl: current.toString(), html: html);
        if (loginRequired) throw const CasAuthExpiredException();
        // CMS 回调可能返回 200 + JS location.href。HTTP 层不执行脚本：
        // Cookie 已落盘后重取原资源，业务解析器不会收到回调占位页面。
        if (completedCasExchange && current != resource && !retriedResource) {
          retriedResource = true;
          current = resource;
          continue;
        }
        return response;
      }
      throw StateError('认证重定向次数超限');
    } finally {
      budgetTimer?.cancel();
    }
  }

  /// 判定一次 HTTP 交换是否命中统一认证登录页/登录跳转。
  ///
  /// 判据唯一实现在 `login_page_detection.dart` 的 [isCasLoginExchange]：依次检查
  /// 最终落地 URL、302/303 的 location（相对 [requestUri] 解析）、响应体 HTML，
  /// 同时识别 WebVPN 代理形态的登录页。[html] 传 null 时跳过响应体检查（调用方
  /// 需要先行解码或做业务侧前置判断时使用，如 sjjx 的列表页预检）。
  static bool isCasLoginExchange({
    String? realUrl,
    int? statusCode,
    String? location,
    Uri? requestUri,
    String? html,
  }) => login_detection.isCasLoginExchange(
    realUrl: realUrl,
    statusCode: statusCode,
    location: location,
    requestUri: requestUri,
    html: html,
  );
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
