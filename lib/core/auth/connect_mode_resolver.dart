import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../network/network_settings.dart';
import '../network/proxy_mode.dart';
import '../network/route_failure.dart';
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

enum RouteVerdict { direct, webVpnRedirected, unreachable, unknownRedirect }

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
  static const _webVpnHost = 'webvpn.zjxu.edu.cn';

  final Map<String, (ZhengfangMode, DateTime)> _cache = {};
  final Map<String, Future<ZhengfangMode>> _inflight = {};
  final Map<String, int> _observations = {};
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

  @visibleForTesting
  Future<RouteVerdict> Function(Uri target)? directVerdictChecker;

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
    _observations.clear();
  }

  (int, int) routeVersion(Uri target) =>
      (_generation, _observations[target.origin] ?? 0);

  bool hasCachedMode(Uri target) {
    final cached = _cache[target.origin];
    return cached != null && DateTime.now().difference(cached.$2) < _cacheTtl;
  }

  /// 业务响应已经证实出口被改道，不再重复发一条直连探测。
  void markWebVpnRedirected(Uri target) {
    _recordObservedMode(target, ZhengfangMode.webVpn);
  }

  /// 调用方已在 WebVPN 失败后重新探测并证明直连可达。
  void markDirectReachable(Uri target) {
    _recordObservedMode(target, ZhengfangMode.direct);
  }

  void _recordObservedMode(Uri target, ZhengfangMode mode) {
    final origin = target.origin;
    final previous = _cache[origin];
    if (previous == null ||
        previous.$1 != mode ||
        _inflight.containsKey(origin)) {
      _observations.update(
        origin,
        (revision) => revision + 1,
        ifAbsent: () => 1,
      );
    }
    _cache[origin] = (mode, DateTime.now());
    _inflight.remove(origin);
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
    try {
      return await resolveOrThrow(
        Uri.parse(
          targetUrl?.trim().isNotEmpty == true
              ? targetUrl!.trim()
              : ZhengfangAuth.directAcademicServiceUrl,
        ),
        forceRefresh: forceRefresh,
      );
    } on RouteFailure {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<ZhengfangMode> resolveOrThrow(
    Uri target, {
    bool forceRefresh = false,
  }) async {
    if ((target.scheme != 'http' && target.scheme != 'https') ||
        target.host.isEmpty) {
      throw RouteFailure(RouteFailureReason.connectionFailed);
    }
    final key = target.origin;
    final existing = _inflight[key];
    if (existing != null) return existing;
    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.$2) < _cacheTtl) {
      return cached.$1;
    }

    final version = routeVersion(target);
    final future = _select(target, version);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  Future<ZhengfangMode> _select(Uri target, (int, int) version) async {
    final verdict = await probeDirect(target);
    final ZhengfangMode mode;
    if (verdict == RouteVerdict.direct) {
      mode = ZhengfangMode.direct;
    } else {
      if (verdict != RouteVerdict.webVpnRedirected) {
        final hook = webVpnReachabilityChecker;
        final failure = hook != null
            ? (await hook() ? null : RouteFailureReason.connectionFailed)
            : await ZhengfangAuth.probeWebVpnFailure();
        if (failure != null) {
          throw RouteFailure(
            verdict == RouteVerdict.unknownRedirect
                ? RouteFailureReason.unknownRedirect
                : failure,
          );
        }
      }
      mode = ZhengfangMode.webVpn;
    }
    if (routeVersion(target) == version &&
        verdict != RouteVerdict.unknownRedirect) {
      final lastMode = _cache[target.origin]?.$1;
      if (lastMode != null && lastMode != mode) {
        _observations.update(
          target.origin,
          (revision) => revision + 1,
          ifAbsent: () => 1,
        );
      }
      _cache[target.origin] = (mode, DateTime.now());
    }
    return mode;
  }

  /// Fresh direct probe for a reverse fallback. It bypasses the route cache.
  Future<RouteVerdict> probeDirect(Uri target) async {
    final verdictCheck = directVerdictChecker;
    if (verdictCheck != null) return verdictCheck(target);
    final academicCheck = directReachabilityChecker;
    final targetCheck = targetDirectReachabilityChecker;
    final academicTarget =
        target.origin ==
        Uri.parse(ZhengfangAuth.directAcademicServiceUrl).origin;
    if (academicTarget && academicCheck != null) {
      return await academicCheck()
          ? RouteVerdict.direct
          : RouteVerdict.unreachable;
    }
    if (targetCheck != null) {
      return await targetCheck(target.toString())
          ? RouteVerdict.direct
          : RouteVerdict.unreachable;
    }
    final requestUri = target.removeFragment();

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
          .get<String>(requestUri.toString(), cancelToken: token)
          .timeout(
            _probeTimeout,
            onTimeout: () {
              if (!token.isCancelled) {
                token.cancel('connect-mode probe timeout');
              }
              throw TimeoutException('connect-mode probe timeout');
            },
          );
      final location = response.headers.value('location') ?? '';
      final verdict = classifyDirectReachable(
        statusCode: response.statusCode ?? 0,
        location: location,
        requestUri: requestUri,
      );
      final redirectHost = _redirectHostForLog(requestUri, location);
      AppLogger.instance.auth(
        LogLevel.info,
        '目标直连探测 ${requestUri.origin}: '
        '${verdict.name} (${response.statusCode}$redirectHost)',
      );
      return verdict;
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '目标直连探测失败 ${requestUri.origin}: ${e.type}',
      );
      return RouteVerdict.unreachable;
    } catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '目标直连探测失败 ${requestUri.origin}: ${e.runtimeType}',
      );
      return RouteVerdict.unreachable;
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
  static RouteVerdict classifyDirectReachable({
    required int statusCode,
    String location = '',
    required Uri requestUri,
  }) {
    if (statusCode >= 200 && statusCode < 300 ||
        statusCode == 304 ||
        statusCode >= 400 && statusCode < 600) {
      return RouteVerdict.direct;
    }
    if (statusCode < 300 || statusCode >= 400) return RouteVerdict.unreachable;

    final rawLocation = location.trim();
    final parsed = Uri.tryParse(rawLocation);
    if (rawLocation.isEmpty || parsed == null) {
      return RouteVerdict.unknownRedirect;
    }
    final resolved = requestUri.resolveUri(parsed);
    if (resolved.host == _webVpnHost) return RouteVerdict.webVpnRedirected;
    if (isUnifiedAuthLoginEntryUrl(resolved.toString()) ||
        _isSameOrigin(requestUri, resolved)) {
      return RouteVerdict.direct;
    }
    return RouteVerdict.unknownRedirect;
  }

  /// A business response may change the route only for its own origin.
  static bool isWebVpnRedirectForTarget(Uri request, String location) {
    if (request.host.isEmpty ||
        request.host == _webVpnHost ||
        (request.scheme != 'http' && request.scheme != 'https')) {
      return false;
    }
    final reference = Uri.tryParse(location.trim());
    if (reference == null) return false;
    final target = request.resolveUri(reference);
    if (target.scheme != 'https' ||
        target.host != _webVpnHost ||
        target.port != 443 ||
        target.userInfo.isNotEmpty) {
      return false;
    }
    final expected = Uri.parse(
      ZhengfangAuth.instance.buildWebVpnProxyUrl(request.origin),
    );
    if (expected.host != _webVpnHost) return false;
    final prefix = expected.path.toLowerCase();
    final path = target.path.toLowerCase();
    return path == prefix || path.startsWith('$prefix/');
  }

  /// 日志用：只记跳转目标的 host，不记 path / query。畸形 Location 不抛异常，
  /// 避免诊断日志改变探测结果。
  static String _redirectHostForLog(Uri requestUri, String location) {
    final raw = location.trim();
    if (raw.isEmpty) return '';
    final parsed = Uri.tryParse(raw);
    if (parsed == null) return ' → (invalid location)';
    return ' → ${requestUri.resolveUri(parsed).host}';
  }

  static bool _isSameOrigin(Uri a, Uri b) {
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
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
    directVerdictChecker = null;
  }
}
