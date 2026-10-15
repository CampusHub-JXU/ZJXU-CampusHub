import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';

import '../../helpers/perf_frame_timing_support.dart';

void main() {
  group('默认关闭 / 显式开始', () {
    test('未启用时 start 被拒绝，且不注册任何回调', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build(enabled: false);
      addTearDown(collector.dispose);

      expect(
        collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome)),
        isFalse,
      );
      expect(env.registerCount, 0);
      expect(collector.isRunning, isFalse);
      expect(collector.sampleCount, 0);
    });

    test('未开始时也绝不注册回调（没有默认回调）', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);

      expect(env.registerCount, 0);
      expect(env.callback, isNull);
    });

    test('应用不在前台时拒绝开始', () {
      final env = FakeFrameTimingEnv(lifecycleState: AppLifecycleState.paused);
      final collector = env.build();
      addTearDown(collector.dispose);

      expect(
        collector.start(PerfRunMetadata(scenario: PerfScenario.homeScroll)),
        isFalse,
      );
      expect(env.registerCount, 0);
    });

    test('单例默认开关与编译期 --dart-define 一致', () {
      expect(FrameTimingCollector.instance.enabled, kPerfDiagnosticsEnabled);
    });

    test('源码守卫：默认开关来自 dart-define，且不靠调试模式自动开启', () {
      final src = dartCodeWithoutComments(
        File('lib/core/perf/frame_timing_collector.dart').readAsStringSync(),
      );
      expect(src.contains('JXU_PERF_DIAGNOSTICS'), isTrue);
      expect(src.contains('kDebugMode'), isFalse);
      // 不请求帧、不建持续 ticker。
      expect(src.contains('scheduleFrame'), isFalse);
      expect(src.contains('Timer.periodic'), isFalse);
      expect(src.contains('Ticker'), isFalse);
      expect(src.contains('Timeline.now'), isTrue);
      expect(src.contains('currentSystemFrameTimeStamp'), isFalse);
    });
  });

  group('采集与停止', () {
    test('开始只注册一次，并挂上生命周期观察者', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);

      expect(
        collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome)),
        isTrue,
      );
      expect(env.registerCount, 1);
      expect(env.observers, contains(collector));
      expect(collector.isRunning, isTrue);
      expect(collector.scenario, PerfScenario.idleHome);
    });

    test('合成帧进入样本，统计与偏移量正确', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.homeScroll));

      env.deliver(<FrameTiming>[
        fakeTiming(vsyncStart: 1000000, uiMicros: 2000, rasterMicros: 3000),
        fakeTiming(vsyncStart: 1008333, uiMicros: 4000, rasterMicros: 5000),
      ]);

      expect(collector.sampleCount, 2);
      expect(collector.invalidSamples, 0);
      final result = collector.lastResult;
      // 还没 stop，结果尚未生成。
      expect(result, isNull);

      collector.stop();
      final finished = collector.lastResult!;
      expect(finished.stopReason, PerfStopReason.userStop);
      expect(finished.samples.length, 2);
      expect(finished.samples.first.uiBuildMs, closeTo(2.0, 1e-9));
      expect(finished.samples.first.rasterMs, closeTo(3.0, 1e-9));
      expect(finished.samples.first.totalSpanMs, closeTo(5.2, 1e-9));
      expect(finished.samples.first.vsyncOverheadMs, closeTo(0.2, 1e-9));
      expect(finished.samples.first.vsyncOffsetMicros, 0);
      expect(finished.samples.last.vsyncOffsetMicros, 8333);
      expect(finished.stats.uiBuildP50, closeTo(2.0, 1e-9));
      expect(finished.stats.uiBuildMax, closeTo(4.0, 1e-9));
    });

    test('停止会注销回调、移除观察者并保留有界结果', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.tabReturn));
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);

      collector.stop();

      expect(env.unregisterCount, 1);
      expect(env.callback, isNull);
      expect(env.observers, isEmpty);
      expect(collector.isRunning, isFalse);
      expect(collector.lastResult, isNotNull);
      // 停止后再投递不会有任何变化。
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 2000000)]);
      expect(collector.lastResult!.samples.length, 1);
    });

    test('运行起点之前的迟到批次被丢弃并计数', () {
      final env = FakeFrameTimingEnv();
      env.rawMicros = 1000000;
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));

      env.deliver(<FrameTiming>[
        fakeTiming(vsyncStart: 900000), // 起点之前
        fakeTiming(vsyncStart: 1000000), // 起点
        fakeTiming(vsyncStart: 1008333),
      ]);

      expect(collector.sampleCount, 2);
      expect(collector.droppedLateSamples, 1);
    });

    test('采样开始晚于最近一帧时，以采样时刻为偏移基线', () {
      final env = FakeFrameTimingEnv()..rawMicros = 1000000;
      final collector = env.build();
      addTearDown(collector.dispose);

      // 最近一帧发生在 990000；开始采样时单调时钟已到 1000000。
      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));
      env.deliver(<FrameTiming>[
        fakeTiming(vsyncStart: 995000), // 较最近一帧新，但早于采样开始。
        fakeTiming(vsyncStart: 1000000),
        fakeTiming(vsyncStart: 1008333),
      ]);

      expect(collector.droppedLateSamples, 1);
      expect(collector.sampleCount, 2);
      collector.stop();
      expect(collector.lastResult!.samples.first.vsyncOffsetMicros, 0);
      expect(collector.lastResult!.samples.last.vsyncOffsetMicros, 8333);
    });

    test('重启后旧回调的迟到批次按 epoch 丢弃，不混入新运行', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);

      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));
      final staleCallback = env.callback!;
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
      collector.stop();
      expect(collector.lastResult!.samples.length, 1);

      // 第二次运行（新 epoch）。
      env.rawMicros = 5000000;
      collector.start(PerfRunMetadata(scenario: PerfScenario.settingsDialog));
      staleCallback(<FrameTiming>[fakeTiming(vsyncStart: 4900000)]);

      expect(collector.sampleCount, 0);
      collector.stop();
      expect(collector.lastResult!.samples, isEmpty);
      expect(
        collector.lastResult!.metadata.scenario,
        PerfScenario.settingsDialog,
      );
    });

    test('重复 start 被拒绝（不重叠运行）', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);

      expect(
        collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome)),
        isTrue,
      );
      expect(
        collector.start(PerfRunMetadata(scenario: PerfScenario.homeScroll)),
        isFalse,
      );
      expect(env.registerCount, 1);
      expect(collector.scenario, PerfScenario.idleHome);
    });

    test('start 重置上一轮样本；stop 保留有界报告', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);

      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));
      env.deliver(<FrameTiming>[
        fakeTiming(vsyncStart: 1000000),
        fakeTiming(vsyncStart: 1008333),
      ]);
      collector.stop();
      expect(collector.lastResult!.samples.length, 2);

      collector.start(PerfRunMetadata(scenario: PerfScenario.homeScroll));
      expect(collector.sampleCount, 0);
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 2000000)]);
      collector.stop();
      expect(collector.lastResult!.samples.length, 1);
    });

    test('非法时长被丢弃并计数', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));

      env.deliver(<FrameTiming>[
        // rasterFinish 早于 rasterStart → 负时长。
        fakeTiming(vsyncStart: 1000000, rasterMicros: -500),
        fakeTiming(vsyncStart: 1008333),
      ]);

      expect(collector.sampleCount, 1);
      expect(collector.invalidSamples, 1);
    });
  });

  group('上限', () {
    test('到达样本上限即停止，原因是 sampleCap', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build(maxSamples: 3);
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.homeScroll));

      env.deliver(<FrameTiming>[
        for (var i = 0; i < 5; i++) fakeTiming(vsyncStart: 1000000 + i * 8333),
      ]);

      expect(collector.isRunning, isFalse);
      expect(collector.sampleCount, 3);
      expect(collector.lastResult!.stopReason, PerfStopReason.sampleCap);
      expect(env.unregisterCount, 1);
    });

    test('默认上限是 5000 帧 / 60 秒', () {
      expect(kPerfMaxSamples, 5000);
      expect(kPerfMaxDuration, const Duration(seconds: 60));
      expect(kPerfSettlingWindowMs, 2000);
    });
  });

  group('时长与后台', () {
    testWidgets('到达时长上限自动停止（一次性 Timer，无持续 ticker）', (tester) async {
      final env = FakeFrameTimingEnv();
      final collector = env.build(maxDuration: const Duration(seconds: 1));
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);

      await tester.pump(const Duration(milliseconds: 1100));

      expect(collector.isRunning, isFalse);
      expect(collector.lastResult!.stopReason, PerfStopReason.autoDuration);
      expect(collector.lastResult!.samples.length, 1);
      expect(env.unregisterCount, 1);
    });

    test('应用退到后台立即停止，且不会自动恢复', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);

      env.goBackground();

      expect(collector.isRunning, isFalse);
      expect(collector.lastResult!.stopReason, PerfStopReason.appBackground);
      expect(env.observers, isEmpty);
      expect(env.unregisterCount, 1);

      // 回到前台不会自动重启，也不再注册回调。
      env.goForeground();
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 2000000)]);
      expect(collector.isRunning, isFalse);
      expect(env.registerCount, 1);
      expect(collector.lastResult!.samples.length, 1);
    });

    test('站内导航（页面 dispose）不停止采集', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(PerfRunMetadata(scenario: PerfScenario.homeScroll));

      // 模拟页面被销毁：采集器不监听页面，采集继续。
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
      expect(collector.isRunning, isTrue);
      expect(collector.sampleCount, 1);
    });
  });

  group('场景与结果', () {
    test('四个固定场景都有中文标签与提示', () {
      expect(PerfScenario.values.length, 4);
      for (final scenario in PerfScenario.values) {
        expect(scenario.label, isNotEmpty);
        expect(scenario.hint, isNotEmpty);
        expect(scenario.id, scenario.name);
      }
    });

    test('结果保留开始元数据（刷新率快照 / 可选帧率档位）', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);
      collector.start(
        PerfRunMetadata(
          scenario: PerfScenario.settingsDialog,
          displayRefreshRate: 120,
          shaderFps: 60,
        ),
      );
      collector.stop();

      final result = collector.lastResult!;
      expect(result.metadata.displayRefreshRate, 120);
      expect(result.metadata.shaderFps, 60);
      expect(result.metadata.scenario, PerfScenario.settingsDialog);
      expect(result.duration, isNotNull);
    });

    test('revision 在开始 / 样本 / 停止时递增', () {
      final env = FakeFrameTimingEnv();
      final collector = env.build();
      addTearDown(collector.dispose);

      final before = collector.revision.value;
      collector.start(PerfRunMetadata(scenario: PerfScenario.idleHome));
      final afterStart = collector.revision.value;
      env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
      final afterSample = collector.revision.value;
      collector.stop();
      final afterStop = collector.revision.value;

      expect(afterStart, greaterThan(before));
      expect(afterSample, greaterThan(afterStart));
      expect(afterStop, greaterThan(afterSample));
    });
  });
}
