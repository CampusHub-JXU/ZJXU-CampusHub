import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';
import 'apk_update_controller.dart';
import 'update_model.dart';

/// 用户可选的 APK 下载线路偏好（只持久化这一个枚举名，不含任何身份信息）。
enum ApkDownloadRoute {
  /// 默认：先 R2，失败 / 卡住 / 持续低速时回退 EdgeOne。
  auto,

  /// 只走 Cloudflare R2；不静默改线。
  r2,

  /// 只走 EdgeOne（GitHub 代理）；不静默改线。
  edgeone;

  /// 另一条线路（手动「换线重试」用）；[auto] 无另一条，返回 null。
  ApkDownloadRoute? get other => switch (this) {
    ApkDownloadRoute.auto => null,
    ApkDownloadRoute.r2 => ApkDownloadRoute.edgeone,
    ApkDownloadRoute.edgeone => ApkDownloadRoute.r2,
  };

  /// 本偏好对应的线路候选顺序。R2 缺标记时被剔除（不尝试未确认存在的对象）。
  List<ApkDownloadSource> candidates({required bool r2Available}) =>
      switch (this) {
        ApkDownloadRoute.auto => <ApkDownloadSource>[
          if (r2Available) ApkDownloadSource.r2,
          ApkDownloadSource.edgeone,
        ],
        ApkDownloadRoute.r2 =>
          r2Available ? const [ApkDownloadSource.r2] : const [],
        ApkDownloadRoute.edgeone => const [ApkDownloadSource.edgeone],
      };
}

/// 线路偏好的持久化。读盘缺失 / 类型不符 / 未知值一律回退 [ApkDownloadRoute.auto]。
abstract final class ApkDownloadRoutePreference {
  static const String storageKey = 'update_download_route_v1';

  static Future<ApkDownloadRoute> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.get(storageKey);
      if (raw is String) {
        for (final route in ApkDownloadRoute.values) {
          if (route.name == raw) return route;
        }
      }
    } catch (_) {
      // 读盘失败按默认处理，不阻塞更新流程。
    }
    return ApkDownloadRoute.auto;
  }

  static Future<void> save(ApkDownloadRoute route) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, route.name);
    } catch (_) {
      // 写盘失败只影响下次记忆，不影响本次下载。
    }
  }
}

/// 自动回退的触发原因（只给 UI / 诊断，不含 URL / 异常字符串）。
enum ApkFallbackReason {
  /// 8 秒内一个字节都没收到（连接 / 首包超时的近似）。
  connectTimeout,

  /// 已收到过数据后，连续 10 秒无新增字节。
  stalled,

  /// 连续 15 秒窗口内平均速度低于阈值。
  slow,

  /// DownloadManager 长时间处于暂停（等待重试 / 网络）。
  paused,

  /// DownloadManager 直接报告失败（HTTP 403/404/429/5xx、DNS/TLS 等）。
  failed,
}

/// 下载进度停滞 / 低速判定器（纯逻辑，时钟由调用方注入，便于测试）。
///
/// 数据来源是 DownloadManager 的 `bytesDownloaded` 轮询，**不是**逐包进度：
/// 系统只在约每 2 秒或每 64 KiB 进度步长更新一次该列，因此阈值以秒级窗口
/// 判定，且对窗口起点 / 收尾做小样本保护，避免误判。
class DownloadStallDetector {
  DownloadStallDetector({
    this.connectTimeout = const Duration(seconds: 8),
    this.noBytesTimeout = const Duration(seconds: 10),
    this.slowWindow = const Duration(seconds: 15),
    this.pausedTimeout = const Duration(seconds: 12),
    this.minBytesPerSecond = 100 * 1024,
    this.rampUp = const Duration(seconds: 3),
    this.tailBytes = 1024 * 1024,
    this.maxSampleGap = const Duration(seconds: 5),
  });

  /// 开始后一个字节都没有的容忍时长。
  final Duration connectTimeout;

  /// 已有数据后连续无新增字节的容忍时长。
  final Duration noBytesTimeout;

  /// 低速判定窗口长度。
  final Duration slowWindow;

  /// 暂停态（等待重试 / 网络）的容忍时长。
  final Duration pausedTimeout;

  /// 窗口平均速度下限（字节 / 秒）。
  final int minBytesPerSecond;

  /// 首个字节之后的起步缓冲，期间不判低速。
  final Duration rampUp;

  /// 距离总量不足该字节数时不判低速（下载收尾小样本）。
  final int tailBytes;

  /// 相邻两次采样的最大间隔；超过视为进程被挂起 / 退后台，窗口重置而不是
  /// 把挂起时间算作「无数据」。
  final Duration maxSampleGap;

  DateTime? _startedAt;
  DateTime? _lastSampleAt;
  DateTime? _firstByteAt;
  DateTime? _lastProgressAt;
  DateTime? _pausedSince;
  int _lastBytes = 0;
  final List<(DateTime, int)> _window = <(DateTime, int)>[];

  /// 重新开始观察（新一次入队 / 换线后调用）。
  void reset() {
    _startedAt = null;
    _lastSampleAt = null;
    _firstByteAt = null;
    _lastProgressAt = null;
    _pausedSince = null;
    _lastBytes = 0;
    _window.clear();
  }

  /// 喂入一次轮询样本；返回触发回退的原因，未触发返回 null。
  ApkFallbackReason? observe({
    required DateTime now,
    required int bytes,
    int? totalBytes,
    bool paused = false,
  }) {
    final started = _startedAt;
    if (started == null) {
      _startedAt = now;
      _lastSampleAt = now;
      _lastBytes = bytes;
      if (bytes > 0) {
        _firstByteAt = now;
        _lastProgressAt = now;
        _window.add((now, bytes));
      }
      if (paused) _pausedSince = now;
      return null;
    }

    final lastSample = _lastSampleAt!;
    if (now.difference(lastSample) > maxSampleGap) {
      // 采样中断（后台 / 进程冻结）：丢弃历史，以当前样本为新起点。
      _startedAt = now;
      _firstByteAt = bytes > 0 ? now : null;
      _lastProgressAt = bytes > 0 ? now : null;
      _pausedSince = paused ? now : null;
      _window
        ..clear()
        ..add((now, bytes));
      _lastSampleAt = now;
      _lastBytes = bytes;
      return null;
    }
    _lastSampleAt = now;

    if (bytes > _lastBytes) {
      _firstByteAt ??= now;
      _lastProgressAt = now;
    }
    _lastBytes = bytes;
    _window.add((now, bytes));
    while (_window.isNotEmpty &&
        now.difference(_window.first.$1) > slowWindow + maxSampleGap) {
      _window.removeAt(0);
    }

    if (paused) {
      _pausedSince ??= now;
      if (now.difference(_pausedSince!) >= pausedTimeout) {
        return ApkFallbackReason.paused;
      }
      return null;
    }
    _pausedSince = null;

    if (_firstByteAt == null) {
      if (now.difference(_startedAt!) >= connectTimeout) {
        return ApkFallbackReason.connectTimeout;
      }
      return null;
    }

    final progressAt = _lastProgressAt ?? _firstByteAt!;
    if (now.difference(progressAt) >= noBytesTimeout) {
      return ApkFallbackReason.stalled;
    }

    // 低速：窗口至少完整覆盖 slowWindow，且已过起步缓冲、未到收尾。
    if (now.difference(_firstByteAt!) < rampUp + slowWindow) return null;
    if (totalBytes != null && totalBytes - bytes < tailBytes) return null;
    (DateTime, int)? anchor;
    for (final sample in _window) {
      if (now.difference(sample.$1) >= slowWindow) {
        anchor = sample;
      } else {
        break;
      }
    }
    if (anchor == null) return null;
    final seconds = now.difference(anchor.$1).inMilliseconds / 1000.0;
    if (seconds <= 0) return null;
    final speed = (bytes - anchor.$2) / seconds;
    if (speed < minBytesPerSecond) return ApkFallbackReason.slow;
    return null;
  }
}

/// 路由状态（给 UI 的纯数据；文案由 UI 层决定）。
@immutable
class ApkDownloadRouteStatus {
  const ApkDownloadRouteStatus({
    this.route = ApkDownloadRoute.auto,
    this.active,
    this.switching = false,
    this.lastFallback,
    this.fellBackFrom,
    this.exhausted = false,
  });

  /// 本次下载使用的偏好。
  final ApkDownloadRoute route;

  /// 当前入队的线路；未开始为 null。
  final ApkDownloadSource? active;

  /// 正在退役旧请求并入队备用线路。
  final bool switching;

  /// 最近一次自动回退的原因（本次下载内）。
  final ApkFallbackReason? lastFallback;

  /// 最近一次自动回退离开的线路。
  final ApkDownloadSource? fellBackFrom;

  /// 候选线路已全部失败（不再自动重试，等待用户手动重试 / 换线）。
  final bool exhausted;

  @override
  bool operator ==(Object other) =>
      other is ApkDownloadRouteStatus &&
      other.route == route &&
      other.active == active &&
      other.switching == switching &&
      other.lastFallback == lastFallback &&
      other.fellBackFrom == fellBackFrom &&
      other.exhausted == exhausted;

  @override
  int get hashCode => Object.hash(
    route,
    active,
    switching,
    lastFallback,
    fellBackFrom,
    exhausted,
  );
}

/// APK 双线路下载协调器：在 [ApkUpdateController] 之上选线并做自动回退。
///
/// - 下载仍由原生 DownloadManager 执行；本类只在**调用方轮询**时
///   （[onPolled]，通常每秒一次）读取已投影的进度，用 [DownloadStallDetector]
///   近似「连接超时 / 无字节 / 持续低速」，**不**持有后台定时器、不虚构进度。
/// - 自动模式候选顺序 `R2 → EdgeOne`，每条线路最多尝试一次，**不循环**；
///   手动线路（R2 / EdgeOne）不静默改线，失败后由用户「换线重试」。
/// - 换线 = 复用既有权威退役路径（取消 → 确认移除）后以新 `requestKey` 入队；
///   DownloadManager 无法跨 URL 续传，临时文件在退役时一并删除，**不拼接**
///   不同来源的字节。完成后仍由原生统一做 SHA-256 / 签名 / 包名 / 版本校验。
/// - 调用方（弹窗）关闭后不再轮询，也就不再自动回退：下载继续在当前线路，
///   回到弹窗后重新开始计时。
class ApkDownloadRouter {
  ApkDownloadRouter({
    ApkUpdateController? controller,
    DateTime Function()? clock,
    DownloadStallDetector Function()? detectorFactory,
  }) : _controller = controller ?? ApkUpdateController.instance,
       _clock = clock ?? DateTime.now,
       _detector = (detectorFactory ?? DownloadStallDetector.new)();

  final ApkUpdateController _controller;
  final DateTime Function() _clock;
  final DownloadStallDetector _detector;

  final ValueNotifier<ApkDownloadRouteStatus> status =
      ValueNotifier<ApkDownloadRouteStatus>(const ApkDownloadRouteStatus());

  List<ApkDownloadSource> _remaining = const <ApkDownloadSource>[];
  String? _activeRequestKey;
  bool _autoActive = false;
  bool _switching = false;
  bool _starting = false;

  /// 是否在自动回退的观察窗口内（用于 UI 判断是否需要继续轮询）。
  bool get isWatching => _autoActive;

  /// 按 [route] 选线并入队首选线路。
  ///
  /// 没有任何可用候选（例如手动选 R2 但 Release 无 R2 标记）时不调用通道，
  /// 状态置 `exhausted`，UI 提示换线。
  Future<void> start(AppRelease release, ApkDownloadRoute route) async {
    if (_starting || _switching) return;
    _starting = true;
    try {
      var candidates = route.candidates(r2Available: release.r2MirrorAvailable);
      _detector.reset();
      _autoActive = false;
      _activeRequestKey = null;
      // 手动选了 R2 但该版本没有 R2 镜像：不让「更新」按钮点了没反应，
      // 改用唯一存在的 EdgeOne，并通过 fellBackFrom 如实告知。
      final unavailableR2 = candidates.isEmpty && route == ApkDownloadRoute.r2;
      if (unavailableR2) {
        candidates = const <ApkDownloadSource>[ApkDownloadSource.edgeone];
      }
      if (candidates.isEmpty) {
        _remaining = const <ApkDownloadSource>[];
        _publish(ApkDownloadRouteStatus(route: route, exhausted: true));
        return;
      }
      _remaining = candidates.sublist(1);
      final first = candidates.first;
      _publish(
        ApkDownloadRouteStatus(
          route: route,
          active: first,
          fellBackFrom: unavailableR2 ? ApkDownloadSource.r2 : null,
        ),
      );
      await _controller.startDownload(release, source: first);
      _activeRequestKey = _controller.state.value.requestKey;
      // 仅自动模式（有备用线路）才观察卡顿；手动线路不改线。
      _autoActive = route == ApkDownloadRoute.auto && _remaining.isNotEmpty;
    } finally {
      _starting = false;
    }
  }

  /// 用户主动「换线重试」：改走 [route]（调用方已确认不是静默改线）。
  Future<void> restartWith(AppRelease release, ApkDownloadRoute route) async {
    if (_controller.state.value.phase.isActive) {
      await _controller.cancelActiveUpdate();
      if (_controller.state.value.phase.isActive) return; // 退役未确认
    }
    await start(release, route);
  }

  /// 每次轮询（[ApkUpdateController.refreshActiveUpdate]）完成后调用。
  Future<void> onPolled(AppRelease release) async {
    if (!_autoActive || _switching || _starting) return;
    final state = _controller.state.value;
    if (_activeRequestKey != null && state.requestKey != _activeRequestKey) {
      _autoActive = false;
      return;
    }

    ApkFallbackReason? verdict;
    switch (state.phase) {
      case ApkUpdatePhase.enqueued:
      case ApkUpdatePhase.downloading:
        verdict = _detector.observe(
          now: _clock(),
          bytes: state.bytesDownloaded ?? 0,
          totalBytes: state.totalBytes,
        );
      case ApkUpdatePhase.paused:
        verdict = _detector.observe(
          now: _clock(),
          bytes: state.bytesDownloaded ?? 0,
          totalBytes: state.totalBytes,
          paused: true,
        );
      case ApkUpdatePhase.failed:
        if (_isSourceFailure(state.reason)) {
          verdict = ApkFallbackReason.failed;
        } else {
          _autoActive = false;
        }
      case ApkUpdatePhase.verifying:
      case ApkUpdatePhase.readyToInstall:
      case ApkUpdatePhase.permissionRequired:
      case ApkUpdatePhase.installerOpened:
      case ApkUpdatePhase.idle:
      case ApkUpdatePhase.canceled:
      case ApkUpdatePhase.unavailable:
        _autoActive = false;
    }
    if (verdict == null) return;
    await _fallback(release, verdict);
  }

  /// 失败原因里「换一条线路可能就好」的子集；存储不足 / 签名 / 版本等与线路
  /// 无关的失败不触发回退。
  static bool _isSourceFailure(ApkUpdateFailureReason? reason) =>
      reason == ApkUpdateFailureReason.network ||
      reason == ApkUpdateFailureReason.verificationFailed ||
      reason == ApkUpdateFailureReason.unknown ||
      reason == null;

  Future<void> _fallback(AppRelease release, ApkFallbackReason reason) async {
    if (_switching) return;
    final from = status.value.active;
    if (_remaining.isEmpty) {
      _autoActive = false;
      _publish(
        ApkDownloadRouteStatus(
          route: status.value.route,
          active: from,
          lastFallback: reason,
          fellBackFrom: from,
          exhausted: true,
        ),
      );
      return;
    }

    _switching = true;
    final next = _remaining.first;
    _remaining = _remaining.sublist(1);
    _publish(
      ApkDownloadRouteStatus(
        route: status.value.route,
        active: next,
        switching: true,
        lastFallback: reason,
        fellBackFrom: from,
      ),
    );
    try {
      AppLogger.instance.info(
        '更新下载自动换线: ${from?.name} → ${next.name} (${reason.name})',
      );
      await _controller.cancelActiveUpdate();
      if (_controller.state.value.phase.isActive) {
        // 旧请求退役未确认：绝不盲目入队新请求，保留原生权威状态。
        _autoActive = false;
        _publish(
          ApkDownloadRouteStatus(
            route: status.value.route,
            active: from,
            lastFallback: reason,
            fellBackFrom: from,
            exhausted: true,
          ),
        );
        return;
      }
      _detector.reset();
      await _controller.startDownload(release, source: next);
      _activeRequestKey = _controller.state.value.requestKey;
      // 继续观察最后一条线路：只用于如实报告「全部线路失败」，不再换线。
      _autoActive = true;
      _publish(
        ApkDownloadRouteStatus(
          route: status.value.route,
          active: next,
          lastFallback: reason,
          fellBackFrom: from,
        ),
      );
    } finally {
      _switching = false;
    }
  }

  void _publish(ApkDownloadRouteStatus next) {
    if (status.value == next) return;
    status.value = next;
  }

  /// 弹窗关闭 / 用户取消时停止观察（下载本身由控制器 / 原生管理）。
  void stopWatching() {
    _autoActive = false;
  }

  @visibleForTesting
  void debugReset() {
    _remaining = const <ApkDownloadSource>[];
    _activeRequestKey = null;
    _autoActive = false;
    _switching = false;
    _starting = false;
    _detector.reset();
    status.value = const ApkDownloadRouteStatus();
  }
}
