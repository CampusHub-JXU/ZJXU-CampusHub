import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/academic/academic_exceptions.dart';
import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/maintenance_window.dart';
import '../../features/changxing_jiada/changxing_jiada_exceptions.dart';

/// 统一网络异常 Toast 提示（PRD FR-3）。
///
/// 按 [NetworkErrorKind] 映射文案，5 秒内同类 Toast 去重，避免刷新连击刷屏。
/// 页面层仍可保留技术错误用于调试，用户可见提示统一走本组件。
class NetworkErrorToast {
  NetworkErrorToast._();

  static const _dedupeWindow = Duration(seconds: 5);
  static final Map<NetworkErrorKind, DateTime> _lastShownAt = {};

  /// 测试用时间注入；为 null 时使用真实本地时间。
  @visibleForTesting
  static DateTime Function()? debugNow;

  static DateTime _now() => debugNow?.call() ?? DateTime.now();

  /// 根据 [error] 分类并展示对应 Toast。
  ///
  /// 当 [BuildContext] 没有 [ScaffoldMessenger] 时静默跳过（如测试或未挂载场景）。
  static void show(BuildContext context, Object? error) {
    final kind = classify(error);
    final now = _now();
    final message = resolveMessage(kind, now: now);
    final last = _lastShownAt[kind];
    if (last != null && now.difference(last) < _dedupeWindow) return;
    _lastShownAt[kind] = now;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 解析 [kind] 对应的最终文案：维护时段内对请求失败类文案追加
  /// 维护提示（见 [appendMaintenanceHint]），白天原样返回。
  ///
  /// `proxyConflict` 是用户本机环境冲突，与学校系统维护无关，不追加。
  static String resolveMessage(NetworkErrorKind kind, {DateTime? now}) {
    final message = _messageOf(kind);
    if (kind == NetworkErrorKind.proxyConflict) return message;
    return appendMaintenanceHint(message, now: now);
  }

  /// 将异常分类为 [NetworkErrorKind]，便于测试与复用。
  static NetworkErrorKind classify(Object? error) {
    if (error == null) return NetworkErrorKind.generic;

    if (error is DioException) {
      final message = (error.message ?? '').toLowerCase();
      if (message.contains('proxy') ||
          message.contains('代理') ||
          error.type == DioExceptionType.unknown && message.contains('socks')) {
        return NetworkErrorKind.proxyConflict;
      }
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
        case DioExceptionType.badCertificate:
          return NetworkErrorKind.network;
        case DioExceptionType.badResponse:
          return NetworkErrorKind.network;
        case DioExceptionType.cancel:
          return NetworkErrorKind.generic;
      }
    }

    // Release builds obfuscate Dart type names; use actual types instead.
    final text = error.toString();
    if (error is AcademicSessionExpired ||
        error is CasAuthExpiredException ||
        error is ChangxingAuthExpiredException ||
        text.contains('WebVPN 认证已过期') ||
        text.contains('登录已过期') ||
        text.contains('登录状态已过期')) {
      return NetworkErrorKind.academicAuthExpired;
    }
    if (error is ChangxingNeedUnifiedAuthException || text.contains('一卡通认证')) {
      return NetworkErrorKind.unifiedAuthExpired;
    }
    if (text.contains('WebVPN 网关不可用')) {
      return NetworkErrorKind.webVpnUnavailable;
    }
    if (error is CaptchaException || error is UnifiedAuthCaptchaException) {
      return NetworkErrorKind.academicAuthExpired;
    }
    return NetworkErrorKind.generic;
  }

  static String _messageOf(NetworkErrorKind kind) {
    switch (kind) {
      case NetworkErrorKind.network:
        return '网络异常，请检查网络连接或切换 WLAN/流量后重试';
      case NetworkErrorKind.proxyConflict:
        return '检测到系统代理，请在代理软件中将 *.zjxu.edu.cn 设为直连';
      case NetworkErrorKind.academicAuthExpired:
        return '登录已过期，请重新登录教务系统';
      case NetworkErrorKind.unifiedAuthExpired:
        return '一卡通认证已过期，请重新登录';
      case NetworkErrorKind.webVpnUnavailable:
        return 'WebVPN 网关不可用，请切换到校园网或检查网络';
      case NetworkErrorKind.generic:
        return '网络异常，请稍后重试';
    }
  }

  /// 重置去重状态，测试用。
  static void resetDedupe() => _lastShownAt.clear();
}

/// 网络异常分类（PRD 5.3 表格）。
enum NetworkErrorKind {
  /// 连接超时/无网络。
  network,

  /// 系统代理冲突。
  proxyConflict,

  /// 教务会话过期。
  academicAuthExpired,

  /// 一卡通会话过期。
  unifiedAuthExpired,

  /// WebVPN 网关不可用。
  webVpnUnavailable,

  /// 其他异常。
  generic,
}
