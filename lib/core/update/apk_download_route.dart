import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';
import 'apk_update_controller.dart';

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

/// 换源原因（只给 UI / 诊断，不含 URL / 异常字符串）。wire 名即枚举名，必须与
/// 原生白名单 `connectTimeout|stalled|slow|paused|failed` 一致：前四种可由 Dart
/// 停滞观察器经 `switchSource` 建议，[failed] 是原生专属（明确失败自动换源时
/// 原生自己写入），Dart 永不发送。
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

/// 下载停滞观察器：**无计划状态**，只在调用方轮询之后读取已投影的原生进度，
/// 用 [DownloadStallDetector] 近似「连接超时 / 无字节 / 持续低速 / 长暂停」，
/// 判定成立时只调用 [ApkUpdateController.switchSource]。
///
/// 边界（契约 §6.2）：
/// - **不**选下一条线路、**不**记住已试过的线路、**不**入队 / 取消：这些全在原生，
///   Dart 只据 `state.canSwitch`（下载中、自动模式、还有未试的源）决定要不要建议；
/// - `state.attempt` 变化（原生换源 / 重试开了新尝试）即重置检测器，计时从头开始；
/// - 只在 `enqueued / downloading / paused` 观察，其余阶段不判定；
/// - 无后台定时器：由弹窗的 ~1s 轮询驱动，弹窗关闭后不再观察，重开后从原生
///   状态继续、停滞计时从头开始；
/// - 发出一次建议后立即重置检测器：原生若拒绝（或调用失败），要再满足一个完整
///   阈值窗口才会再次建议，不会每秒重复发送。
class ApkDownloadStallWatcher {
  ApkDownloadStallWatcher({
    ApkUpdateController? controller,
    DateTime Function()? clock,
    DownloadStallDetector Function()? detectorFactory,
  }) : _controller = controller ?? ApkUpdateController.instance,
       _clock = clock ?? DateTime.now,
       _detector = (detectorFactory ?? DownloadStallDetector.new)();

  final ApkUpdateController _controller;
  final DateTime Function() _clock;
  final DownloadStallDetector _detector;

  int? _attempt;

  /// 每次轮询（[ApkUpdateController.refreshActiveUpdate]）完成后调用。
  Future<void> onPolled() async {
    final state = _controller.state.value;
    if (_attempt != state.attempt) {
      _attempt = state.attempt;
      _detector.reset();
    }
    if (!state.canSwitch) return;

    final ApkFallbackReason? verdict;
    switch (state.phase) {
      case ApkUpdatePhase.enqueued:
      case ApkUpdatePhase.downloading:
        // 原生 DM 查询暂不可用时不带字节数；这不是「没有进度」，跳过本次采样，
        // 否则连续几次查询失败会被当成停滞而误触发换线。
        if (state.bytesDownloaded == null &&
            state.phase == ApkUpdatePhase.downloading) {
          return;
        }
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
      case ApkUpdatePhase.idle:
      case ApkUpdatePhase.verifying:
      case ApkUpdatePhase.readyToInstall:
      case ApkUpdatePhase.permissionRequired:
      case ApkUpdatePhase.installerOpened:
      case ApkUpdatePhase.failed:
      case ApkUpdatePhase.canceled:
      case ApkUpdatePhase.unavailable:
      case ApkUpdatePhase.reconcileRequired:
      case ApkUpdatePhase.cleanupPending:
        verdict = null;
    }
    if (verdict == null) return;

    _detector.reset();
    AppLogger.instance.info(
      '更新下载建议换线: ${state.source?.name} (${verdict.name})',
    );
    await _controller.switchSource(verdict);
  }

  @visibleForTesting
  void debugReset() {
    _attempt = null;
    _detector.reset();
  }
}
