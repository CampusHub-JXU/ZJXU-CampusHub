import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../async/serial_queue.dart';
import '../logging/app_logger.dart';
import 'network_settings.dart';
import 'proxy_mode.dart';

/// WebView 代理覆盖的底层后端（便于注入测试替身）。
abstract interface class WebViewProxyBackend {
  /// 当前 WebView 是否支持 `PROXY_OVERRIDE`；任何异常 / 平台缺失一律视为不支持。
  Future<bool> isSupported();

  /// 让本进程内所有 WebView 直连（`direct://`）。须在首次载入前 await。
  Future<void> setDirect();

  /// 清除覆盖，恢复跟随系统代理。
  Future<void> clear();
}

/// 生产后端：flutter_inappwebview 6.1.5 的 [ProxyController]（Android 原生
/// `androidx.webkit.ProxyController`，**进程级**覆盖）。
///
/// 插件的 `setProxyOverride` 在不支持时原生侧返回 false 但 Dart 签名是
/// `Future<void>`，无法据返回值判断成败，因此必须先用
/// [WebViewFeature.isFeatureSupported] 预检。
class InAppWebViewProxyBackend implements WebViewProxyBackend {
  const InAppWebViewProxyBackend();

  @override
  Future<bool> isSupported() async {
    try {
      return await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
    } catch (_) {
      // MissingPluginException / PlatformException / UnimplementedError（非
      // Android、单测未装平台）一律降级为「不支持」。
      return false;
    }
  }

  @override
  Future<void> setDirect() {
    return ProxyController.instance().setProxyOverride(
      settings: ProxySettings(proxyRules: [ProxyRule(url: 'direct://')]),
    );
  }

  @override
  Future<void> clear() => ProxyController.instance().clearProxyOverride();
}

enum WebViewDirectRouteStatus {
  /// 覆盖已生效：本进程 WebView 直连。
  applied,

  /// WebView 不支持 `PROXY_OVERRIDE`（或平台通道缺失）。
  unsupported,

  /// 支持但设置失败。
  failed,
}

/// [WebViewDirectRoute.acquire] 返回的租约；[release] 幂等。
class WebViewDirectLease {
  WebViewDirectLease._(this._route, this.status);

  final WebViewDirectRoute _route;

  /// 取得租约时的覆盖状态。
  final WebViewDirectRouteStatus status;

  bool _released = false;

  bool get applied => status == WebViewDirectRouteStatus.applied;

  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return _route._release();
  }
}

/// 引用计数的「WebView 直连」覆盖。
///
/// 背景：Dart `HttpClient` 在 `ignoreSystemProxy=true` 时强制 `DIRECT`，但
/// WebView 默认跟随系统代理；教务（正方）会话疑似与出口 IP 绑定，探测走直连、
/// H5 页面走代理会导致在网页内被要求重新登录。[startGlobal] 在
/// `ignoreSystemProxy=true`（默认）期间持有常驻租约，让本 App 全部 WebView 与
/// Dart 同走直连；教务 H5 入口页另持一个租约兜底（如环境代理例外场景）。
///
/// - 第一个租约设置覆盖，最后一个租约释放时清除；重叠页面 / 快速重进不会提前清除。
/// - Android `ProxyController` 是**进程级**覆盖（插件文档：used by all WebViews
///   in the app），只影响本应用自己的 WebView，不影响其它应用 / 系统设置；
///   但租约存续期间本进程所有 WebView（含 epay100 隐藏 WebView）都会直连。
/// - 所有状态迁移经 [SerialQueue] 串行，保证 set / clear 不交错。
class WebViewDirectRoute {
  WebViewDirectRoute({
    this._backend = const InAppWebViewProxyBackend(),
    Future<bool> Function()? isDartRouteDirect,
    this.backendTimeout = defaultBackendTimeout,
  }) : _isDartRouteDirect = isDartRouteDirect ?? defaultIsDartRouteDirect;

  static final WebViewDirectRoute instance = WebViewDirectRoute();

  /// Dart 侧到教务目标（直连 origin 与 WebVPN 网关）的实际路由是否为直连。
  ///
  /// `ignoreSystemProxy=true` 时 Dart 强制 DIRECT；否则 Dart 只认
  /// `HTTP_PROXY`/`NO_PROXY` 环境变量（Android 上通常没有，也读不到系统
  /// Wi-Fi 代理），目标未命中环境代理即同样直连。命中则 Dart 已走代理，不覆盖。
  static Future<bool> defaultIsDartRouteDirect() async {
    if (NetworkSettings.instance.ignoreSystemProxy.value) return true;
    for (final target in _academicTargets) {
      if (await resolveHttpProxyForUri(target) != null) return false;
    }
    return true;
  }

  static final List<Uri> _academicTargets = <Uri>[
    Uri.parse('https://jwzx.zjxu.edu.cn/'),
    Uri.parse('https://webvpn.zjxu.edu.cn/'),
  ];

  final WebViewProxyBackend _backend;
  final Future<bool> Function() _isDartRouteDirect;
  final SerialQueue _queue = SerialQueue();

  int _count = 0;
  bool _applied = false;

  /// 已发出 setDirect 但未确认成功（失败 / 超时）：覆盖可能迟到生效，最后一个
  /// 租约释放时仍须 clear，避免残留。
  bool _dirty = false;
  WebViewDirectRouteStatus _lastFailure = WebViewDirectRouteStatus.unsupported;
  bool _loggedUnavailable = false;

  /// 取得一个租约（无条件）。首个租约会 await 覆盖生效后才返回；不支持 /
  /// 失败不抛异常，租约 [WebViewDirectLease.status] 如实反映。
  Future<WebViewDirectLease> acquire() {
    return _queue.run(() async {
      _count++;
      if (!_applied) await _tryApply();
      return WebViewDirectLease._(
        this,
        _applied ? WebViewDirectRouteStatus.applied : _lastFailure,
      );
    });
  }

  /// 仅当 Dart 侧实际走直连时才取得租约；Dart 已走代理时返回 null（路由本就
  /// 一致，什么都不做）。
  Future<WebViewDirectLease?> acquireIfDartDirect() async {
    bool direct;
    try {
      direct = await _isDartRouteDirect();
    } catch (_) {
      direct = false;
    }
    if (!direct) return null;
    return acquire();
  }

  /// 单次原生调用的上限：通道无响应时不得阻塞教务入口。
  static const Duration defaultBackendTimeout = Duration(seconds: 3);

  final Duration backendTimeout;

  Future<void> _tryApply() async {
    try {
      if (!await _backend.isSupported().timeout(backendTimeout)) {
        _lastFailure = WebViewDirectRouteStatus.unsupported;
        _logUnavailableOnce(
          '当前 WebView 不支持 PROXY_OVERRIDE，无法让 WebView 与 Dart 同走直连',
        );
        return;
      }
      _dirty = true;
      await _backend.setDirect().timeout(backendTimeout);
      _applied = true;
    } catch (error, stackTrace) {
      _lastFailure = WebViewDirectRouteStatus.failed;
      _logUnavailableOnce(
        '设置 WebView 直连覆盖失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _logUnavailableOnce(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_loggedUnavailable) return;
    _loggedUnavailable = true;
    AppLogger.instance.webview(
      LogLevel.warn,
      message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<void> _release() {
    return _queue.run(() async {
      if (_count > 0) _count--;
      if (_count == 0 && (_applied || _dirty)) {
        _applied = false;
        _dirty = false;
        try {
          await _backend.clear().timeout(backendTimeout);
        } catch (error, stackTrace) {
          AppLogger.instance.webview(
            LogLevel.warn,
            '清除 WebView 直连覆盖失败',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    });
  }

  WebViewDirectLease? _globalLease;
  VoidCallback? _globalListener;
  Future<void> _globalSync = Future<void>.value();

  /// 全局直连：`ignoreSystemProxy=true`（默认）期间持有一个常驻租约，让本 App
  /// 所有 WebView 与 Dart 一样强制直连，即使系统开了代理；用户关闭该设置后
  /// 释放租约、WebView 恢复跟随系统代理。只在主引擎前台调用一次，重复调用无副作用。
  void startGlobal({ValueListenable<bool>? ignoreSystemProxy}) {
    if (_globalListener != null) return;
    final setting =
        ignoreSystemProxy ?? NetworkSettings.instance.ignoreSystemProxy;
    void sync() {
      final want = setting.value;
      _globalSync = _globalSync.then((_) async {
        if (want && _globalLease == null) {
          _globalLease = await acquire();
        } else if (!want && _globalLease != null) {
          final lease = _globalLease!;
          _globalLease = null;
          await lease.release();
        }
      });
    }

    _globalListener = sync;
    setting.addListener(sync);
    sync();
  }

  @visibleForTesting
  Future<void> debugGlobalSettled() => _globalSync;

  @visibleForTesting
  int get debugLeaseCount => _count;

  @visibleForTesting
  bool get debugApplied => _applied;
}
