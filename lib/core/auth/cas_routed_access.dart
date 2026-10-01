import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'cas_auth_broker.dart';
import 'connect_mode_resolver.dart';
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

/// 一次业务访问选定的路由：直连或 WebVPN，以及据此重建 URL 的方式。
///
/// 只描述「这一次」选路，不读、不写全局 [ZhengfangAuth.mode]。
@immutable
class CasRoute {
  const CasRoute(this.mode);

  final ZhengfangMode mode;

  bool get isWebVpn => mode == ZhengfangMode.webVpn;

  /// 把直连形态的资源 URL 重建为本次路由的实际请求地址。
  /// WebVPN 下按 `ZhengfangAuth` 的 host 映射改写；无映射的 host 原样返回。
  String url(String directUrl) => isWebVpn
      ? ZhengfangAuth.instance.buildWebVpnProxyUrl(directUrl)
      : directUrl;
}

/// 「统一认证 CAS 业务接入」的共享选路入口。
///
/// 业务服务不再各自拼「`CasSession.ensure` → 选路 → 补 WebVPN 网关」：
/// 1. [prepare]：用注册的 [CasService] 确认统一认证主会话，按**目标 origin**
///    经 [ConnectModeResolver] 选直连 / WebVPN，WebVPN 时用
///    [CasService.webVpnGateway] 的真实逐跳 CAS 回调链补网关会话；
/// 2. 业务请求用 [CasRoute.url] 重建地址，自行用统一认证 Dio 发送；
/// 3. 命中登录 bounce 时调 [recover] 重验（调用方负责「至多重试一次」）。
///
/// 不变量：不写全局 `ZhengfangAuth.mode`、不 `markLoggedOut`、不清统一认证
/// CookieJar；明确失效抛 [CasAuthExpiredException]，网络不确定抛
/// [TimeoutException]（调用方不得据此判定登录过期）。
class CasRoutedAccess {
  CasRoutedAccess._();

  /// 网关会话补建钩子，测试可注入以免真实联网。
  @visibleForTesting
  static Future<void> Function(CancelToken? token, DateTime? deadline)?
  debugGatewayEnsurer;

  /// 会话确认 + 选路 + （WebVPN 时）网关会话。
  static Future<CasRoute> prepare({
    required CasService service,
    required String targetUrl,
    CancelToken? cancelToken,
    DateTime? deadline,
  }) async {
    await _ensureCasSession(service);
    final mode = await ConnectModeResolver.instance.resolve(
      targetUrl: targetUrl,
    );
    if (mode == null) {
      throw TimeoutException('服务暂时无法连接，请检查网络后重试');
    }
    final route = CasRoute(mode);
    if (route.isWebVpn) {
      await _ensureGateway(cancelToken, deadline);
    }
    return route;
  }

  /// 业务 bounce 后的一次恢复：重建网关会话（WebVPN）并重验 CAS service。
  /// 绝不 `markLoggedOut`、不清全局会话。
  static Future<void> recover(
    CasRoute route, {
    required CasService service,
    CancelToken? cancelToken,
    DateTime? deadline,
  }) async {
    if (route.isWebVpn) {
      await _ensureGateway(cancelToken, deadline);
    }
    await _ensureCasSession(service, restoreFromStore: false);
  }

  /// 「attempt → 命中 [CasAuthExpiredException] → [recover] → 仅再试一次」。
  ///
  /// 第二次仍抛 [CasAuthExpiredException] 时原样上抛，由调用方映射为业务
  /// 异常（不清全局会话）。[beforeRecover] / [afterRecover] 供调用方在恢复前后
  /// 复核身份（抛出的异常原样上抛）；本方法不做任何 guard 判断。
  static Future<T> withRecoverOnce<T>({
    required CasRoute route,
    required CasService service,
    required Future<T> Function() attempt,
    CancelToken? cancelToken,
    DateTime? deadline,
    void Function()? beforeRecover,
    void Function()? afterRecover,
  }) async {
    try {
      return await attempt();
    } on CasAuthExpiredException {
      beforeRecover?.call();
      await recover(
        route,
        service: service,
        cancelToken: cancelToken,
        deadline: deadline,
      );
      afterRecover?.call();
      return attempt();
    }
  }

  static Future<void> _ensureCasSession(
    CasService service, {
    bool restoreFromStore = true,
  }) async {
    final status = await CasSession.ensure(
      service.serviceUrl,
      restoreFromStore: restoreFromStore,
      syncWebViewCookies: false,
    );
    switch (status) {
      case CasSessionStatus.active:
        return;
      case CasSessionStatus.inactive:
        throw const CasAuthExpiredException();
      case CasSessionStatus.unknown:
        throw TimeoutException('统一认证暂时无法连接，请稍后重试');
    }
  }

  static Future<void> _ensureGateway(
    CancelToken? cancelToken,
    DateTime? deadline,
  ) async {
    final hook = debugGatewayEnsurer;
    try {
      if (hook != null) {
        await hook(cancelToken, deadline);
        return;
      }
      await CasAuthBroker.getResource(
        CasService.webVpnGateway.serviceUrl,
        cancelToken: cancelToken,
        deadline: deadline,
        needsLogin: webVpnGatewayResponseNeedsLogin,
      );
    } on CasAuthExpiredException {
      rethrow;
    } on StateError catch (error) {
      // 逐跳链路异常（重定向超限 / 缺 Location）：网关状态不确定，非登录过期。
      AppLogger.instance.auth(
        LogLevel.warn,
        'WebVPN 网关会话建立失败（链路异常）: ${error.message}',
      );
      throw TimeoutException('WebVPN 网关暂时无法连接，请稍后重试');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      AppLogger.instance.auth(
        LogLevel.warn,
        'WebVPN 网关会话建立失败（网络异常）: ${error.type}',
      );
      throw TimeoutException('WebVPN 网关暂时无法连接，请稍后重试');
    }
  }
}

/// WebVPN 网关登录落地页 / CAS 登录页判定（纯函数）：[realUrl] 为最终落地
/// URL，[html] 为解码后的正文。教务 H5 入口与 [CasRoutedAccess] 共用同一判据。
bool isWebVpnGatewayLoginBounce(String realUrl, String html) {
  if (isZhengfangGatewayLoginUrl(realUrl) ||
      isZhengfangLoginEntryUrl(realUrl)) {
    return true;
  }
  return looksLikeUnifiedAuthLoginHtml(html);
}

/// [CasAuthBroker.getResource] 的 `needsLogin` 适配：对响应应用
/// [isWebVpnGatewayLoginBounce]。
bool webVpnGatewayResponseNeedsLogin(Response<List<int>> response) =>
    isWebVpnGatewayLoginBounce(
      response.realUri.toString(),
      utf8.decode(response.data ?? const [], allowMalformed: true),
    );
