import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'zhengfang_auth.dart';

/// 统一编排教务系统连接模式判定。
///
/// 不依赖 `connectivity_plus` 的 `wifi`/`mobile` 类型推断校园网，统一以
/// "目标服务是否可达且不被重定向到登录页"为判定依据（见 PRD FR-1）。
class ConnectModeResolver {
  ConnectModeResolver._();
  static final ConnectModeResolver instance = ConnectModeResolver._();

  static const _cacheTtl = Duration(seconds: 60);

  ZhengfangMode? _cachedMode;
  DateTime? _cachedAt;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _started = false;

  /// 直连探测钩子，测试可注入。
  @visibleForTesting
  Future<bool> Function()? directReachabilityChecker;

  /// WebVPN 探测钩子，测试可注入。
  @visibleForTesting
  Future<bool> Function()? webVpnReachabilityChecker;

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

  /// 失效缓存的探测结果。
  void invalidate() {
    _cachedMode = null;
    _cachedAt = null;
  }

  /// 按优先级解析当前应使用的连接模式。
  ///
  /// 1. 直连 `jwzx` 可达且不被重定向到 WebVPN → [ZhengfangMode.direct]。
  /// 2. 否则 WebVPN 可达 → [ZhengfangMode.webVpn]。
  /// 3. 两者都不可达 → `null`（调用方决定是否提示）。
  ///
  /// 结果缓存 60 秒，[forceRefresh] 或网络变化时重新探测。
  Future<ZhengfangMode?> resolve({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedMode != null && _cachedAt != null) {
      if (DateTime.now().difference(_cachedAt!) < _cacheTtl) {
        return _cachedMode;
      }
    }

    final direct = await (directReachabilityChecker?.call() ??
        ZhengfangAuth.checkDirectReachable());
    if (direct) {
      _cache(ZhengfangMode.direct);
      return ZhengfangMode.direct;
    }

    final webVpn = await (webVpnReachabilityChecker?.call() ??
        ZhengfangAuth.checkWebVpnReachable());
    final mode = webVpn ? ZhengfangMode.webVpn : null;
    _cache(mode);
    return mode;
  }

  void _cache(ZhengfangMode? mode) {
    _cachedMode = mode;
    _cachedAt = DateTime.now();
  }

  @visibleForTesting
  void debugReset() {
    invalidate();
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _started = false;
    directReachabilityChecker = null;
    webVpnReachabilityChecker = null;
  }
}