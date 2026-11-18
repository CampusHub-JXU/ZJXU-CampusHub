import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';

import '../logging/app_logger.dart';
import '../platform/android_platform_bindings.dart';
import '../platform/safe_invoke.dart';

/// 微信拉起结果分类。
///
/// 通道返回值只代表「intent 已发出」，不代表目标网页真的被微信打开；
/// [WechatLaunchStatus.launched] 同样只到「已请求」。
enum WechatLaunchStatus {
  /// 原生侧已发出跳转 intent（页面能否在微信内直达不可确认）。
  launched,

  /// 设备未检测到微信。
  notInstalled,

  /// URL 为空或 scheme 不被支持（未调通道）。
  unsupportedUrl,

  /// 微信存在但没有可处理该 URL 的外部入口（需复制链接降级）。
  noHandler,

  /// 通道返回失败、原生报错或返回值无法识别。
  launchFailed,

  /// MethodChannel 未注册（非 Android / 单测）。
  channelUnavailable,
}

/// `openUrlInWeChat` 的结构化结果。
class WechatLaunchResult {
  const WechatLaunchResult({
    required this.status,
    required this.sanitizedUrl,
    this.route,
    this.detail,
  });

  final WechatLaunchStatus status;

  /// 剥离一次性认证参数后的链接；复制降级统一用它，避免外泄 ticket/code。
  final String sanitizedUrl;

  /// 原生侧实际采用的拉起路径（如 `action_view_wechat`），诊断用。
  final String? route;

  /// 原生状态串 / 错误信息，诊断用。
  final String? detail;

  /// 仅表示「跳转请求已发出」；不代表页面已在微信内打开。
  bool get isLaunchRequested => status == WechatLaunchStatus.launched;
}

/// 需要剥离的一次性认证参数（大小写不敏感）。
const _wechatOneTimeAuthParams = <String>{
  'ticket',
  'code',
  'state',
  'oauth_token',
  'auth_code',
};

bool _isOneTimeAuthParam(String key) =>
    _wechatOneTimeAuthParams.contains(key.toLowerCase());

/// 过滤一段 `a=1&b=2` query 串中的一次性认证参数；非键值对片段原样保留。
String _sanitizeQueryPart(String query) {
  if (query.isEmpty) return query;
  final kept = <String>[
    for (final segment in query.split('&'))
      if (segment.isNotEmpty && !_isOneTimeAuthParam(segment.split('=').first))
        segment,
  ];
  return kept.join('&');
}

/// 过滤 fragment 内部 query（`#/hd-detail?hdId=1&code=abc` → 保留 `hdId`）。
String _sanitizeFragment(String fragment) {
  final queryStart = fragment.indexOf('?');
  if (queryStart < 0) return fragment;
  final route = fragment.substring(0, queryStart);
  final query = _sanitizeQueryPart(fragment.substring(queryStart + 1));
  return query.isEmpty ? route : '$route?$query';
}

/// 剥离微信分享链接中的一次性认证参数（ticket / code / state /
/// oauth_token / auth_code），同时覆盖主 URL query 与 `#/...` 路由内部 query；
/// `hdId`、`schoolCode`、`platform`、`thirdAppid`、`_WXFTL` 等业务参数原样保留。
String sanitizeWechatShareUrl(String rawUrl) {
  final hashIndex = rawUrl.indexOf('#');
  final base = hashIndex < 0 ? rawUrl : rawUrl.substring(0, hashIndex);
  final fragment = hashIndex < 0 ? '' : rawUrl.substring(hashIndex + 1);

  var cleanedBase = base;
  final uri = Uri.tryParse(base);
  if (uri != null && uri.queryParameters.isNotEmpty) {
    cleanedBase = uri
        .replace(
          queryParameters: {
            for (final entry in uri.queryParameters.entries)
              if (!_isOneTimeAuthParam(entry.key)) entry.key: entry.value,
          },
        )
        .toString();
  }

  if (fragment.isEmpty) return cleanedBase;
  final cleanedFragment = _sanitizeFragment(fragment);
  return cleanedFragment.isEmpty
      ? cleanedBase
      : '$cleanedBase#$cleanedFragment';
}

class WechatLauncher {
  WechatLauncher._();

  static final WechatLauncher instance = WechatLauncher._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/wechat');
  static const _launchMethod = 'openUrlInWeChat';
  static const _openAppMethod = 'openWeChatApp';

  /// 结构化拉起：返回可区分的状态与「已剥认证参数」的干净链接。
  ///
  /// 传给原生 / 用户复制的都是 [sanitizeWechatShareUrl] 的结果，避免一次性
  /// ticket / code 离开 App 或落进剪贴板。
  Future<WechatLaunchResult> openUrlDetailed(String url) async {
    final trimmedUrl = url.trim();
    final uri = trimmedUrl.isEmpty ? null : Uri.tryParse(trimmedUrl);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (uri == null ||
        (scheme != 'http' && scheme != 'https' && scheme != 'weixin')) {
      return WechatLaunchResult(
        status: WechatLaunchStatus.unsupportedUrl,
        sanitizedUrl: trimmedUrl,
        detail: 'unsupported scheme: ${scheme.isEmpty ? '<none>' : scheme}',
      );
    }

    final sanitized = sanitizeWechatShareUrl(trimmedUrl);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final jniResult = _openUrlViaJni(sanitized);
      if (jniResult != null) return jniResult;
    }

    return safeInvoke<Object?, WechatLaunchResult>(
      _channel,
      _launchMethod,
      arguments: {'url': sanitized},
      map: (raw) => _parseNativeResult(raw, sanitized),
      missing: WechatLaunchResult(
        status: WechatLaunchStatus.channelUnavailable,
        sanitizedUrl: sanitized,
      ),
      failed: WechatLaunchResult(
        status: WechatLaunchStatus.launchFailed,
        sanitizedUrl: sanitized,
      ),
      label: '打开微信网页',
      category: LogCategory.webview,
    );
  }

  /// 只拉起微信 App 本体（不带 URL）。用于 `noHandler` 降级：目标网页在微信
  /// 内没有外部入口时，先复制干净链接，再把微信请到前台由用户粘贴打开。
  ///
  /// 返回值同样只代表「intent 已发出」，不代表微信真的切到前台。
  Future<WechatLaunchResult> openWeChatApp() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final jniResult = _openAppViaJni();
      if (jniResult != null) return jniResult;
    }

    return safeInvoke<Object?, WechatLaunchResult>(
      _channel,
      _openAppMethod,
      map: (raw) => _parseNativeResult(raw, ''),
      missing: const WechatLaunchResult(
        status: WechatLaunchStatus.channelUnavailable,
        sanitizedUrl: '',
      ),
      failed: const WechatLaunchResult(
        status: WechatLaunchStatus.launchFailed,
        sanitizedUrl: '',
      ),
      label: '拉起微信',
      category: LogCategory.webview,
    );
  }

  WechatLaunchResult? _openUrlViaJni(String sanitized) {
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) return null;
    try {
      return using((arena) {
        final rawActivity = androidActivity(engineId);
        if (rawActivity == null) return null;
        final activity = rawActivity.as(Activity.type, releaseOriginal: true)
          ..releasedBy(arena);
        final handler = WeChatChannelHandler(activity)..releasedBy(arena);
        final jUrl = sanitized.toJString()..releasedBy(arena);
        final res = handler.openUrlInWeChatJni(jUrl)..releasedBy(arena);
        return _fromJniResult(res, sanitized, arena);
      });
    } catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.webview,
        'JNI 打开微信网页失败: $error',
      );
      return WechatLaunchResult(
        status: WechatLaunchStatus.launchFailed,
        sanitizedUrl: sanitized,
      );
    }
  }

  WechatLaunchResult? _openAppViaJni() {
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) return null;
    try {
      return using((arena) {
        final rawActivity = androidActivity(engineId);
        if (rawActivity == null) return null;
        final activity = rawActivity.as(Activity.type, releaseOriginal: true)
          ..releasedBy(arena);
        final handler = WeChatChannelHandler(activity)..releasedBy(arena);
        final res = handler.openWeChatAppJni()..releasedBy(arena);
        return _fromJniResult(res, '', arena);
      });
    } catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.webview,
        'JNI 拉起微信失败: $error',
      );
      return const WechatLaunchResult(
        status: WechatLaunchStatus.launchFailed,
        sanitizedUrl: '',
      );
    }
  }

  static WechatLaunchResult _fromJniResult(
    WeChatJniResult res,
    String sanitizedUrl,
    Arena arena,
  ) {
    final statusStr = (res.status..releasedBy(arena)).toDartString();
    final jRoute = res.route;
    final jDetail = res.detail;
    if (jRoute != null) jRoute.releasedBy(arena);
    if (jDetail != null) jDetail.releasedBy(arena);
    final route = jRoute?.toDartString();
    final detail = jDetail?.toDartString() ?? statusStr;
    return WechatLaunchResult(
      status: _mapWechatStatus(statusStr),
      sanitizedUrl: sanitizedUrl,
      route: route,
      detail: detail,
    );
  }

  /// True means a URL intent was launched, not that the webpage finished loading.
  Future<bool> openUrl(String url) async {
    final result = await openUrlDetailed(url);
    return result.isLaunchRequested;
  }
}

/// 兼容两类通道返回值：
/// - `Map`：新版原生按 `status` 字段上报（`launched` / `not_installed` /
///   `unsupported_url` / `no_handler` / `launch_failed`），可附 `route` /
///   `detail` 诊断字段；
/// - `bool`：旧实现与旧测试 mock，`true` → launched，`false` → launchFailed。
/// 无法识别的形态一律按 `launchFailed` 处理（保守视为未拉起）。
WechatLaunchStatus _mapWechatStatus(Object? rawStatus) => switch (rawStatus) {
  'launched' => WechatLaunchStatus.launched,
  'not_installed' => WechatLaunchStatus.notInstalled,
  'unsupported_url' => WechatLaunchStatus.unsupportedUrl,
  'no_handler' => WechatLaunchStatus.noHandler,
  'launch_failed' => WechatLaunchStatus.launchFailed,
  _ => WechatLaunchStatus.launchFailed,
};

WechatLaunchResult _parseNativeResult(Object? raw, String sanitizedUrl) {
  switch (raw) {
    case bool opened:
      return WechatLaunchResult(
        status: opened
            ? WechatLaunchStatus.launched
            : WechatLaunchStatus.launchFailed,
        sanitizedUrl: sanitizedUrl,
      );
    case Map response:
      return WechatLaunchResult(
        status: _mapWechatStatus(response['status']),
        sanitizedUrl: sanitizedUrl,
        route: response['route'] as String?,
        detail: response['detail'] as String? ?? response['status']?.toString(),
      );
    default:
      return WechatLaunchResult(
        status: WechatLaunchStatus.launchFailed,
        sanitizedUrl: sanitizedUrl,
        detail: 'unrecognized channel reply: ${raw.runtimeType}',
      );
  }
}
