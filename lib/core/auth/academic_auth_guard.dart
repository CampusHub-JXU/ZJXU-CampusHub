import 'package:dio/dio.dart';

import '../logging/app_logger.dart';
import 'connect_mode_resolver.dart';
import 'zhengfang_auth.dart';

/// 教务会话过期时由 [AcademicAuthGuard] 抛出的统一异常。
class AcademicAuthExpiredException implements Exception {
  const AcademicAuthExpiredException();
  @override
  String toString() => '登录状态已过期，请重新登录';
}

/// 封装教务业务请求的"认证过期识别 + 会话恢复 + 自动重试一次"链路（PRD FR-2）。
///
/// 供 exam/grades/schedule 等教务依赖模块复用，避免每个 service 各自重复
/// 302/403/登录页重定向识别与 `markLoggedOut` 逻辑。
class AcademicAuthGuard {
  const AcademicAuthGuard._();

  /// 执行 [request]，若响应命中认证过期则尝试恢复会话后重试一次。
  ///
  /// - 首次命中过期 → 调用 [ConnectModeResolver] 判定模式并恢复会话
  ///   （WebVPN 模式走 `ensureWebVpnGatewaySession`，直连走 `validateSession`）。
  /// - 恢复成功 → 重试原请求；重试仍命中过期 → 抛 [authExpiredException]。
  /// - 恢复失败 → 直接抛 [authExpiredException]。
  ///
  /// 自动重试仅一次，避免循环。失败时统一 `markLoggedOut` 以同步登录态。
  static Future<Response<T>> guardRequest<T>({
    required Future<Response<T>> Function() request,
    Object authExpiredException = const AcademicAuthExpiredException(),
  }) async {
    final resp = await _safeRequest(request);
    if (!_isAuthExpired<T>(resp)) return resp;

    AppLogger.instance.auth(LogLevel.warn, '教务请求命中认证过期，尝试恢复会话后重试一次');
    final recovered = await _attemptRecovery();
    if (!recovered) {
      await ZhengfangAuth.instance.markLoggedOut();
      throw authExpiredException;
    }

    final retry = await _safeRequest(request);
    if (!_isAuthExpired<T>(retry)) return retry;

    AppLogger.instance.auth(LogLevel.warn, '教务请求重试后仍命中认证过期，标记登出');
    await ZhengfangAuth.instance.markLoggedOut();
    throw authExpiredException;
  }

  static Future<Response<T>> _safeRequest<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (e) {
      // 业务接口配置 validateStatus < 400，302 不会抛；但 403/网络异常可能抛。
      // 403 视为认证过期，封装为可识别的响应。
      if (e.response?.statusCode == 403 || e.response?.statusCode == 302) {
        return e.response as Response<T>;
      }
      rethrow;
    }
  }

  static bool _isAuthExpired<T>(Response<T>? resp) {
    if (resp == null) return false;
    final code = resp.statusCode ?? 0;
    if (code == 302 || code == 303 || code == 401 || code == 403) {
      final location = resp.headers.value('location') ?? '';
      // 业务接口不应重定向；任何 302/303 都视为登录态失效。
      if (location.isEmpty ||
          isZhengfangLoginEntryUrl(location) ||
          isZhengfangGatewayLoginUrl(location)) {
        return true;
      }
      return true;
    }
    if (code == 200) {
      final data = resp.data;
      if (data is String && looksLikeZhengfangLoginHtml(data)) return true;
    }
    return false;
  }

  static Future<bool> _attemptRecovery() async {
    try {
      final mode = await ConnectModeResolver.instance.resolve();
      if (mode == ZhengfangMode.webVpn) {
        final ok = await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
          syncWebViewCookies: false,
        );
        return ok == true;
      }
      if (mode == ZhengfangMode.direct) {
        final ok = await ZhengfangAuth.instance.validateSession();
        return ok == true;
      }
      return false;
    } catch (e, s) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务会话恢复失败',
        error: e,
        stackTrace: s,
      );
      return false;
    }
  }
}
