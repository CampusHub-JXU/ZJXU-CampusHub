import 'dart:async';
import 'dart:ui' show AppLifecycleState, FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver;

import 'frame_timing_stats.dart';

/// 编译期开关：只有显式 `--dart-define=JXU_PERF_DIAGNOSTICS=true` 才为 true。
///
/// 默认 false——生产包不注册任何帧时回调、不显示入口、路由 fail closed。
/// 不能靠 `kDebugMode` 自动打开（否则 debug 包自动采样，违背「显式开始」）。
const bool kPerfDiagnosticsEnabled = bool.fromEnvironment(
  'JXU_PERF_DIAGNOSTICS',
);

/// 单次运行的样本上限。到达即停止并记录 `sampleCap` 原因（不是静默丢弃）。
const int kPerfMaxSamples = 5000;

/// 单次运行的最长时间。用一次性 Timer 到点停止，不做持续 ticker。
const Duration kPerfMaxDuration = Duration(seconds: 60);

/// 观测页建议的静置窗口：开始后的前 2 秒包含导航/首帧沉降，判读时应避开。
/// 只写进报告元数据做提示，**不**剔除、**不**填充任何样本。
const int kPerfSettlingWindowMs = 2000;

/// 四个固定场景（不接受自由文本备注，避免隐私与分类歧义）。
enum PerfScenario {
  /// 首页闲置（默认流体背景出帧）。
  idleHome('首页闲置', '停在首页不动，观察背景动效出帧'),

  /// 首页功能区磁贴滚动。
  homeScroll('首页滚动', '在首页功能区磁贴列表上下滚动'),

  /// 首页 / 我的 tab 切换与返回转场。
  tabReturn('切换返回', '在「首页 / 我的」之间切换并返回'),

  /// 设置页滑动 / 打开玻璃弹窗。
  settingsDialog('设置弹窗', '在设置页滑动并打开一个弹窗');

  const PerfScenario(this.label, this.hint);

  final String label;
  final String hint;

  /// 稳定字符串（导出白名单用），不随本地化改变。
  String get id => name;
}

/// 运行结束原因。
enum PerfStopReason {
  userStop('手动停止'),
  autoDuration('到达时长上限'),
  sampleCap('到达样本上限'),
  appBackground('应用进入后台');

  const PerfStopReason(this.label);

  final String label;
  String get id => name;
}

/// 开始采集时快照的元数据（由调用方在 start 时提供，core 不主动读取界面）。
class PerfRunMetadata {
  const PerfRunMetadata({
    required this.scenario,
    this.displayRefreshRate,
    this.shaderFps,
  });

  final PerfScenario scenario;

  /// 开始瞬间的显示刷新率快照（`View.of(context).display.refreshRate`）。
  /// LTPO 场景中会变化，这里只代表开始那一刻。
  final double? displayRefreshRate;

  /// 现有「流体背景帧率档位」设置的可选快照（只读，不写设置）。
  final int? shaderFps;
}

/// 单次运行结果（不可变快照）。
class PerfRunResult {
  const PerfRunResult({
    required this.metadata,
    required this.startedAt,
    required this.endedAt,
    required this.stopReason,
    required this.samples,
    required this.droppedLateSamples,
    required this.invalidSamples,
  });

  final PerfRunMetadata metadata;
  final DateTime startedAt;
  final DateTime endedAt;
  final PerfStopReason stopReason;
  final List<FrameTimingSample> samples;

  /// 属于本次运行之前（起点之前）的迟到批次，被丢弃的帧数。
  final int droppedLateSamples;

  /// 时长字段非法（NaN / 负值 / 非有限）被丢弃的帧数。
  final int invalidSamples;

  Duration get duration => endedAt.difference(startedAt);

  FrameTimingStats get stats => computeFrameTimingStats(samples);
}

typedef PerfTimingsRegister = void Function(TimingsCallback callback);
typedef PerfTimingsUnregister = void Function(TimingsCallback callback);

/// 帧时采集器：**只在显式 [start] 后**注册 `SchedulerBinding.addTimingsCallback`。
///
/// 设计要点：
/// * 单例 [instance] 会被「性能诊断」页共享；页面 dispose / 返回不停止采集
///   （用户需要先开始、再离开页面去操作场景，然后回来停止 / 导出）；
/// * 应用进入后台（paused / hidden / detached）会诚实停止——那是用户离开 App，
///   不是站内导航；
/// * 不主动请求任何新帧，不创建持续 ticker；
/// * 运行有唯一 epoch，重启后旧回调迟到批次按 epoch + 时间戳双重丢弃；
/// * 采集器只做 O(n) 追加，分位数只在读取统计时计算。
class FrameTimingCollector with WidgetsBindingObserver {
  FrameTimingCollector({
    bool? enabled,
    PerfTimingsRegister? registerTimings,
    PerfTimingsUnregister? unregisterTimings,
    void Function(WidgetsBindingObserver observer)? addObserver,
    void Function(WidgetsBindingObserver observer)? removeObserver,
    AppLifecycleState Function()? lifecycleState,
    int Function()? rawFrameClockMicros,
    DateTime Function()? clock,
    this.maxDuration = kPerfMaxDuration,
    this.maxSamples = kPerfMaxSamples,
  }) : enabled = enabled ?? kPerfDiagnosticsEnabled,
       _registerTimings =
           registerTimings ?? SchedulerBinding.instance.addTimingsCallback,
       _unregisterTimings =
           unregisterTimings ?? SchedulerBinding.instance.removeTimingsCallback,
       _addObserver =
           addObserver ??
           ((observer) => WidgetsBinding.instance.addObserver(observer)),
       _removeObserver =
           removeObserver ??
           ((observer) => WidgetsBinding.instance.removeObserver(observer)),
       _lifecycleState =
           lifecycleState ??
           (() =>
               WidgetsBinding.instance.lifecycleState ??
               AppLifecycleState.resumed),
       _rawFrameClockMicros =
           rawFrameClockMicros ??
           (() => SchedulerBinding
               .instance
               .currentSystemFrameTimeStamp
               .inMicroseconds),
       _clock = clock ?? DateTime.now;

  /// App 级单例。仅在显式 start 时注册回调。
  static final FrameTimingCollector instance = FrameTimingCollector();

  /// 构造期覆盖（测试用）。生产默认取 [kPerfDiagnosticsEnabled]。
  final bool enabled;

  final Duration maxDuration;
  final int maxSamples;

  final PerfTimingsRegister _registerTimings;
  final PerfTimingsUnregister _unregisterTimings;
  final void Function(WidgetsBindingObserver observer) _addObserver;
  final void Function(WidgetsBindingObserver observer) _removeObserver;
  final AppLifecycleState Function() _lifecycleState;
  final int Function() _rawFrameClockMicros;
  final DateTime Function() _clock;

  /// 每次「状态或样本」变化自增。页面按 ≤1Hz 节流监听，避免逐帧 setState。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool _running = false;
  int _runEpoch = 0;
  PerfScenario? _scenario;
  DateTime? _startedAt;
  int _startRawMicros = 0;
  final List<FrameTimingSample> _samples = <FrameTimingSample>[];
  int _droppedLate = 0;
  int _invalid = 0;
  TimingsCallback? _callback;
  Timer? _durationTimer;
  bool _observing = false;
  PerfRunResult? _lastResult;

  bool get isRunning => _running;
  PerfScenario? get scenario => _scenario;
  int get sampleCount => _samples.length;
  int get droppedLateSamples => _droppedLate;
  int get invalidSamples => _invalid;
  PerfRunResult? get lastResult => _lastResult;

  Duration get elapsed {
    final started = _startedAt;
    if (started == null) return Duration.zero;
    final now = _clock();
    if (now.isBefore(started)) return Duration.zero;
    return now.difference(started);
  }

  /// 显式开始。返回 false 表示被拒绝（未启用 / 已在运行 / 应用不在前台）。
  bool start(PerfRunMetadata metadata) {
    if (!enabled || _running) return false;
    if (_lifecycleState() != AppLifecycleState.resumed) return false;

    _running = true;
    _runEpoch++;
    _lastMetadata = metadata;
    _scenario = metadata.scenario;
    _startedAt = _clock();
    _startRawMicros = _rawFrameClockMicros();
    _samples.clear();
    _droppedLate = 0;
    _invalid = 0;

    final epoch = _runEpoch;
    void callback(List<FrameTiming> timings) => _onTimings(epoch, timings);
    _callback = callback;
    _registerTimings(callback);

    _durationTimer = Timer(
      maxDuration,
      () => _stop(PerfStopReason.autoDuration),
    );

    if (!_observing) {
      _addObserver(this);
      _observing = true;
    }
    revision.value++;
    return true;
  }

  /// 显式停止。未运行时为 no-op。
  void stop({PerfStopReason reason = PerfStopReason.userStop}) => _stop(reason);

  void _stop(PerfStopReason reason) {
    if (!_running) return;
    _running = false;

    final callback = _callback;
    if (callback != null) {
      _unregisterTimings(callback);
      _callback = null;
    }
    _durationTimer?.cancel();
    _durationTimer = null;
    if (_observing) {
      _removeObserver(this);
      _observing = false;
    }

    final started = _startedAt ?? _clock();
    final metadata =
        _lastMetadata ??
        PerfRunMetadata(scenario: _scenario ?? PerfScenario.idleHome);
    _lastResult = PerfRunResult(
      metadata: metadata,
      startedAt: started,
      endedAt: _clock(),
      stopReason: reason,
      samples: List<FrameTimingSample>.unmodifiable(_samples),
      droppedLateSamples: _droppedLate,
      invalidSamples: _invalid,
    );
    revision.value++;
  }

  PerfRunMetadata? _lastMetadata;

  void _onTimings(int epoch, List<FrameTiming> timings) {
    if (!_running || epoch != _runEpoch) return;
    var appended = false;
    for (final timing in timings) {
      final vsyncUs = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      // 起点之前的迟到帧：不能归给本次运行（可能属于上一个场景）。
      if (vsyncUs < _startRawMicros) {
        _droppedLate++;
        continue;
      }
      final ui = timing.buildDuration.inMicroseconds / 1000.0;
      final raster = timing.rasterDuration.inMicroseconds / 1000.0;
      final total = timing.totalSpan.inMicroseconds / 1000.0;
      final vsync = timing.vsyncOverhead.inMicroseconds / 1000.0;
      if (!ui.isFinite ||
          !raster.isFinite ||
          !total.isFinite ||
          !vsync.isFinite ||
          ui < 0 ||
          raster < 0 ||
          total < 0 ||
          vsync < 0) {
        _invalid++;
        continue;
      }
      _samples.add(
        FrameTimingSample(
          vsyncOffsetMicros: vsyncUs - _startRawMicros,
          uiBuildMs: ui,
          rasterMs: raster,
          totalSpanMs: total,
          vsyncOverheadMs: vsync,
        ),
      );
      appended = true;
      if (_samples.length >= maxSamples) {
        _stop(PerfStopReason.sampleCap);
        return;
      }
    }
    if (appended) revision.value++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_running) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _stop(PerfStopReason.appBackground);
    }
  }

  /// 释放采集器（测试 / App 级销毁用）。运行中会先停止。
  void dispose() {
    if (_running) _stop(PerfStopReason.userStop);
    revision.dispose();
  }

  /// 测试复位：停止运行并清空结果。
  @visibleForTesting
  void debugReset() {
    if (_running) _stop(PerfStopReason.userStop);
    _lastResult = null;
    _samples.clear();
    _scenario = null;
    _startedAt = null;
    _droppedLate = 0;
    _invalid = 0;
    _runEpoch = 0;
    _lastMetadata = null;
    revision.value = 0;
  }
}
