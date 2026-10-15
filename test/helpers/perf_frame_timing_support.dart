import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show WidgetsBindingObserver;

import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';

/// 采集器测试替身：把「注册回调 / 生命周期 / 时钟 / 原始帧时钟」全部收进一个
/// 可控对象，测试就能注入合成 [FrameTiming]，完全不依赖真实引擎与真实时间。
class FakeFrameTimingEnv {
  FakeFrameTimingEnv({this.lifecycleState = AppLifecycleState.resumed});

  AppLifecycleState lifecycleState;

  /// 当前已注册的回调（未注册为 null）。
  TimingsCallback? callback;

  /// 注册过的所有回调（含已注销），用于断言 epoch / 重复注册。
  final List<TimingsCallback> registered = <TimingsCallback>[];

  final List<WidgetsBindingObserver> observers = <WidgetsBindingObserver>[];

  int registerCount = 0;
  int unregisterCount = 0;

  /// 原始帧时钟（微秒，单调域）。
  int rawMicros = 1000000;

  /// 墙钟（可手动推进，验证节流与时长）。
  DateTime now = DateTime.utc(2026, 1, 1, 12, 0, 0);

  void register(TimingsCallback cb) {
    registerCount++;
    callback = cb;
    registered.add(cb);
  }

  void unregister(TimingsCallback cb) {
    unregisterCount++;
    if (identical(callback, cb)) callback = null;
  }

  void addObserver(WidgetsBindingObserver observer) => observers.add(observer);
  void removeObserver(WidgetsBindingObserver observer) =>
      observers.remove(observer);

  /// 投递一批合成帧。
  void deliver(List<FrameTiming> timings) => callback?.call(timings);

  /// 模拟应用退到后台（paused）。
  void goBackground() {
    lifecycleState = AppLifecycleState.paused;
    for (final observer in List<WidgetsBindingObserver>.of(observers)) {
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    }
  }

  /// 模拟应用回到前台。
  void goForeground() {
    lifecycleState = AppLifecycleState.resumed;
    for (final observer in List<WidgetsBindingObserver>.of(observers)) {
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
  }

  FrameTimingCollector build({
    bool enabled = true,
    Duration maxDuration = const Duration(seconds: 60),
    int maxSamples = 5000,
  }) {
    return FrameTimingCollector(
      enabled: enabled,
      registerTimings: register,
      unregisterTimings: unregister,
      addObserver: addObserver,
      removeObserver: removeObserver,
      lifecycleState: () => lifecycleState,
      rawFrameClockMicros: () => rawMicros,
      clock: () => now,
      maxDuration: maxDuration,
      maxSamples: maxSamples,
    );
  }
}

/// 合成一帧：UI build 与 raster 各占一段，vsync 开销另计。
FrameTiming fakeTiming({
  required int vsyncStart,
  int uiMicros = 2000,
  int rasterMicros = 3000,
  int vsyncOverheadMicros = 200,
}) {
  final buildStart = vsyncStart + vsyncOverheadMicros;
  final buildFinish = buildStart + uiMicros;
  final rasterStart = buildFinish;
  final rasterFinish = rasterStart + rasterMicros;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
  );
}

/// 去掉 `//` 行注释与 `/* */` 块注释，只留下代码。
///
/// 源码守卫只应约束代码；否则一句「不调用 scheduleFrame」的说明文字就会把
/// 守卫弄假阳性。
String dartCodeWithoutComments(String source) {
  final withoutBlocks = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return withoutBlocks
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
