import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';
import 'package:jxu_campus_hub/features/settings/performance_diagnostics_page.dart';

import '../helpers/perf_frame_timing_support.dart';
import '../helpers/preview_support.dart';
import '../helpers/test_setup.dart';

/// 「性能诊断」页视觉预览（预渲染脚本专用）。
///
/// `flutter test` 默认整体 skip（零副作用）；由 `tools/render_previews.ps1`
/// 设置 `JXU_PREVIEW_RENDER=1` 并配合
/// `flutter test --update-goldens test/preview/performance_diagnostics_preview_test.dart`
/// 渲染到 `preview/render/`。
///
/// 只渲染程序化构造的状态（不读真实设备、不联网、不含任何身份信息）。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      await body(tester);
    }, skip: !renderEnabled);
  }

  FrameTimingCollector collectorWithResult() {
    final env = FakeFrameTimingEnv();
    final collector = env.build();
    collector.start(
      PerfRunMetadata(
        scenario: PerfScenario.homeScroll,
        displayRefreshRate: 120,
        shaderFps: 60,
      ),
    );
    env.deliver(<FrameTiming>[
      fakeTiming(vsyncStart: 1000000, uiMicros: 3000, rasterMicros: 4000),
      fakeTiming(vsyncStart: 1008333, uiMicros: 9000, rasterMicros: 12000),
      fakeTiming(vsyncStart: 1016666, uiMicros: 5000, rasterMicros: 6000),
    ]);
    collector.stop();
    return collector;
  }

  previewTest('page_performance_diagnostics_light', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();
    await pumpPreviewScene(
      tester,
      (_) => PerformanceDiagnosticsPage(collector: collector),
      logicalSize: const Size(412, 1280),
    );
    await expectPreviewGolden(tester, 'page_performance_diagnostics_light');
  });

  previewTest('page_performance_diagnostics_result_dark', (tester) async {
    final collector = collectorWithResult();
    await pumpPreviewScene(
      tester,
      (_) => PerformanceDiagnosticsPage(collector: collector),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 1760),
    );
    await expectPreviewGolden(
      tester,
      'page_performance_diagnostics_result_dark',
    );
  });

  previewTest('page_performance_diagnostics_disabled_light', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build(enabled: false);
    await pumpPreviewScene(
      tester,
      (_) => PerformanceDiagnosticsPage(collector: collector),
      logicalSize: const Size(412, 904),
    );
    await expectPreviewGolden(
      tester,
      'page_performance_diagnostics_disabled_light',
    );
  });
}
