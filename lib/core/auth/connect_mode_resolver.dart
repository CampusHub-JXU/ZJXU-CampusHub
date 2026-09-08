import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../network/network_settings.dart';
import '../network/proxy_mode.dart';
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

/// 统一编排连接模式判定。
///
/// 默认 [resolve] 仍探测教务 `jwzx`，保持现有教务选路兼容。
/// 传入 [targetUrl] 时按规范化 origin 分别缓存 / 去重，避免一卡通等业务
/// 被教务可达性误伤，也避免路径级资源交叉缓存。
class ConnectModeResolver {
  ConnectModeResolver._();
  static final ConnectModeResolver instance = ConnectModeResolver._();

  static const _cacheTtl = Duration(seconds: 60);
  static const _probeTimeout = Duration(seconds: 4);
  static const _defaultCacheKey = '';
  static const _webVpnHost = 'webvpn.zjxu.edu.cn';

  final Map<String, _CachedMode> _cache = {};
  final Map<String, Future<ZhengfangMode?>> _inflight = {};
  int _generation = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _started = false;

  /// 直连探测钩子（默认 jwzx），测试可注入。
  @visibleForTesting
  Future<bool> Function()? directReachabilityChecker;

  /// WebVPN 探测钩子，测试可注入。
  @visibleForTesting
  Future<bool> Function()? webVpnReachabilityChecker;

  /// 目标直连探测钩子，测试可注入以免真实联网。
  @visibleForTesting
  Future<bool> Function(String targetUrl)? targetDirectReachabilityChecker;

  /// 开始监听网络变化以失效缓存。在 App 启动时调用一次即可。
  void start() {
    if (_started) return;
    _started = true;
    try {
      _connectivitySub = Connectivity().onConnectivityChanged.listen(
        (_) => invalidate(),
        onError: (_) => invalidate(),
      );
    } catch (e, s) {
      AppLogger.instance.network(
        LogLevel.warn,
        '连接模式监听网络变化失败',
        error: e,
        stackTrace: s,
      );
    }
  }

  /// 失效缓存的探测结果，并丢弃进行中的旧探测回写资格。
  void invalidate() {
    _generation++;
    _cache.clear();
    _inflight.clear();
  }

  /// 按优先级解析当前应使用的连接模式。
  ///
  /// 未传 [targetUrl] 时保持教务 `jwzx` 探测：
  /// 1. 直连 `jwzx` 可达且不被重定向到 WebVPN → [ZhengfangMode.direct]。
  /// 2. 否则 WebVPN 可达 → [ZhengfangMode.webVpn]。
  /// 3. 两者都不可达 → `null`（调用方决定是否提示）。
  ///
  /// 传入 [targetUrl] 时按该目标 origin 独立判定；结果缓存 60 秒，
  /// [forceRefresh] 或网络变化时重新探测。`null` 不缓存。
  Future<ZhengfangMode?> resolve({
    bool forceRefresh = false,
    String? targetUrl,
  }) async {
    final key = _cacheKey(targetUrl);
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
        return cached.mode;
      }
    }

    final existing = _inflight[key];
    if (existing != null) return existing;

    final gen = _generation;
    final future = _probe(targetUrl: targetUrl);
    _inflight[key] = future;
    try {
      final mode = await future;
      if (gen == _generation && mode != null) {
        _cache[key] = _CachedMode(mode, DateTime.now());
      }
      return mode;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  Future<ZhengfangMode?> _probe({String? targetUrl}) async {
    final raw = targetUrl?.trim() ?? '';
    if (raw.isEmpty) return _probeDefaultJwzx();
    return _probeTarget(raw);
  }

  Future<ZhengfangMode?> _probeDefaultJwzx() async {
    final direct =
        await (directReachabilityChecker?.call() ??
            ZhengfangAuth.checkDirectReachable());
    if (direct) return ZhengfangMode.direct;

    final webVpn =
        await (webVpnReachabilityChecker?.call() ??
            ZhengfangAuth.checkWebVpnReachable());
    return webVpn ? ZhengfangMode.webVpn : null;
  }

  Future<ZhengfangMode?> _probeTarget(String targetUrl) async {
    final direct =
        await (targetDirectReachabilityChecker?.call(targetUrl) ??
            _probeTargetDirect(targetUrl));
    if (direct) return ZhengfangMode.direct;

    final webVpn =
        await (webVpnReachabilityChecker?.call() ??
            ZhengfangAuth.checkWebVpnReachable());
    return webVpn ? ZhengfangMode.webVpn : null;
  }

  Future<bool> _probeTargetDirect(String targetUrl) async {
    final probeUrl = _probeUrl(targetUrl);
    final requestUri = Uri.tryParse(probeUrl);
    if (requestUri == null ||
        !requestUri.hasScheme ||
        requestUri.host.isEmpty) {
      return false;
    }

    final token = CancelToken();
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        sendTimeout: const Duration(seconds: 3),
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status != null && status < 1000,
      ),
    );
    applyProxyModeToDio(
      dio,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );

    try {
      final response = await dio
          .get<String>(probeUrl, cancelToken: token)
          .timeout(
            _probeTimeout,
            onTimeout: () {
              if (!token.isCancelled) {
                token.cancel('connect-mode probe timeout');
              }
              throw TimeoutException('connect-mode probe timeout');
            },
          );
      final reachable = classifyDirectReachable(
        statusCode: response.statusCode ?? 0,
        location: response.headers.value('location') ?? '',
        requestUri: requestUri,
      );
      AppLogger.instance.auth(
        LogLevel.info,
        '目标直连探测 ${requestUri.origin}: '
        '${reachable ? "可达" : "不可达"} (${response.statusCode})',
      );
      return reachable;
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '目标直连探测失败 ${requestUri.origin}: ${e.type} ${e.message}',
      );
      return false;
    } catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '目标直连探测失败 ${requestUri.origin}: $e',
      );
      return false;
    } finally {
      if (!token.isCancelled) {
        token.cancel('connect-mode probe closed');
      }
      dio.close(force: true);
    }
  }

  /// 直连探测只判断可达，不判断已认证。
  ///
  /// - 目标自身的正常 HTTP（含 4xx/5xx）→ 可达
  /// - 跳到真实 CAS 登录页 → 可达（未登录）
  /// - 跳到 WebVPN → 不可达（应由 WebVPN 承接）
  /// - 跳到任意未知站点 → 不可达，防止 3xx 误判
  @visibleForTesting
  static bool classifyDirectReachable({
    required int statusCode,
    String location = '',
    required Uri requestUri,
  }) {
    if (statusCode >= 200 && statusCode < 300) return true;
    if (statusCode == 304) return true;
    if (statusCode >= 400 && statusCode < 600) return true;
    if (statusCode < 300 || statusCode >= 400) return false;

    final rawLocation = location.trim();
    if (rawLocation.isEmpty) return false;

    final resolved = requestUri.resolve(rawLocation);
    if (isUnifiedAuthLoginEntryUrl(resolved.toString())) return true;
    if (resolved.host.toLowerCase() == _webVpnHost) return false;
    if (_isSameOrigin(requestUri, resolved)) return true;
    return false;
  }

  static bool _isSameOrigin(Uri a, Uri b) {
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
  }

  static String _cacheKey(String? targetUrl) {
    final raw = targetUrl?.trim() ?? '';
    if (raw.isEmpty) return _defaultCacheKey;
    return _originKey(raw);
  }

  static String _originKey(String targetUrl) {
    final uri = Uri.tryParse(targetUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return targetUrl.trim();
    }
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
  }

  static String _probeUrl(String targetUrl) {
    final uri = Uri.tryParse(targetUrl.trim());
    if (uri == null) return targetUrl.trim();
    return uri.replace(fragment: '').toString();
  }

  @visibleForTesting
  void debugReset() {
    invalidate();
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _started = false;
    directReachabilityChecker = null;
    webVpnReachabilityChecker = null;
    targetDirectReachabilityChecker = null;
  }
}

class _CachedMode {
  const _CachedMode(this.mode, this.at);

  final ZhengfangMode mode;
  final DateTime at;
}
