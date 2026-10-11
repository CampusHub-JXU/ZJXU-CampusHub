import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';
import 'package:jxu_campus_hub/core/perf/frame_timing_report.dart';
import 'package:jxu_campus_hub/features/settings/performance_diagnostics_page.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

import '../../helpers/perf_frame_timing_support.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

class FakeExportStore implements PerfExportStore {
  final Map<String, String> files = <String, String>{};

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }

  @override
  Future<String?> read(String fileName) async => files[fileName];

  @override
  Future<void> delete(String fileName) async => files.remove(fileName);
}

class ThrowingExportStore implements PerfExportStore {
  @override
  Future<void> write(String fileName, String content) async {
    throw FileSystemException(
      'permission denied',
      r'C:\Users\secret\perf.json',
    );
  }

  @override
  Future<String?> read(String fileName) async => null;

  @override
  Future<void> delete(String fileName) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  String valueOf(WidgetTester tester, String key) {
    final text = tester.widget<Text>(find.byKey(Key(key)));
    return text.data ?? '';
  }

  /// 交互测试用足够高的视口，让整页内容一次布局完成（不用来回滚动），
  /// 窄屏 / 大字号的溢出验证另有专门用例。
  Future<void> pumpDiagnostics(
    WidgetTester tester, {
    required FrameTimingCollector collector,
    DateTime Function()? clock,
    PerfRunExporter? exporter,
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(600, 2400),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await pumpPage(
      tester,
      PerformanceDiagnosticsPage(
        collector: collector,
        clock: clock,
        exporter: exporter,
      ),
      themeMode: themeMode,
    );
  }

  testWidgets('未启用时 fail closed，不提供任何开启入口', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build(enabled: false);

    await pumpDiagnostics(tester, collector: collector);

    expect(find.text('性能诊断未启用'), findsOneWidget);
    expect(find.byKey(const Key('perf_start_button')), findsNothing);
    expect(find.byType(AppDropdown<PerfScenario>), findsNothing);
  });

  testWidgets('启用时展示场景选择与开始 / 停止', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);

    expect(find.byType(AppDropdown<PerfScenario>), findsOneWidget);
    expect(find.byKey(const Key('perf_start_button')), findsOneWidget);
    expect(valueOf(tester, 'perf_state_value'), '未开始');
    expect(valueOf(tester, 'perf_frames_value'), '0');
  });

  testWidgets('离开页面继续采集，回来能看到帧数', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    expect(valueOf(tester, 'perf_state_value'), '采集中');

    // 页面被销毁（返回 / 切走），采集不停止。
    await tester.pumpWidget(const SizedBox.shrink());
    expect(collector.isRunning, isTrue);

    env.deliver(<FrameTiming>[
      fakeTiming(vsyncStart: 1000000),
      fakeTiming(vsyncStart: 1008333),
      fakeTiming(vsyncStart: 1016666),
    ]);
    expect(collector.sampleCount, 3);

    // 回到页面：显示当前计数。
    await pumpDiagnostics(tester, collector: collector);
    expect(valueOf(tester, 'perf_frames_value'), '3');
    expect(valueOf(tester, 'perf_state_value'), '采集中');

    // 收尾：停止采集，避免留下挂起的自动停止定时器。
    collector.stop();
  });

  testWidgets('停止后出现结果分区与诚实标签', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    env.deliver(<FrameTiming>[
      fakeTiming(vsyncStart: 1000000, uiMicros: 2000, rasterMicros: 3000),
      fakeTiming(vsyncStart: 1008333, uiMicros: 12000, rasterMicros: 3000),
    ]);

    await tester.tap(find.byKey(const Key('perf_stop_button')));
    await tester.pump();

    expect(valueOf(tester, 'perf_state_value'), '未开始');
    expect(find.text('结果（最近一次）'), findsOneWidget);
    expect(find.text('UI build p50 / p95 / p99'), findsOneWidget);
    expect(find.textContaining('非系统掉帧总数'), findsOneWidget);
    expect(find.textContaining('不代表 120 FPS 已达标'), findsOneWidget);
  });

  testWidgets('应用退到后台停止采集', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();

    env.goBackground();
    await tester.pump();

    expect(collector.isRunning, isFalse);
    expect(valueOf(tester, 'perf_state_value'), '未开始');
  });

  testWidgets('逐帧批次不会逐帧刷新（≤1Hz 节流）', (tester) async {
    var fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector, clock: () => fakeNow);
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    expect(valueOf(tester, 'perf_frames_value'), '0');

    // 时钟不动：即使来了批次，界面也不刷新。
    env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
    await tester.pump();
    expect(collector.sampleCount, 1);
    expect(valueOf(tester, 'perf_frames_value'), '0');

    // 推进 1 秒后再来一批：这次才刷新。
    fakeNow = fakeNow.add(const Duration(seconds: 1));
    env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1008333)]);
    await tester.pump();
    expect(valueOf(tester, 'perf_frames_value'), '2');

    collector.stop();
  });

  testWidgets('复制 JSON 把真实报告放进剪贴板', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
    await tester.tap(find.byKey(const Key('perf_stop_button')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_copy_json_button')));
    await tester.pump();

    expect(copied, isNotNull);
    final decoded = jsonDecode(copied!) as Map<String, dynamic>;
    expect(decoded['tool'], 'frame-timing-diagnostics');
    expect(decoded['sampleCount'], 1);
    expect(find.text('JSON 报告已复制'), findsOneWidget);
  });

  testWidgets('复制 CSV 把原始帧表放进剪贴板', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
    await tester.tap(find.byKey(const Key('perf_stop_button')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_copy_csv_button')));
    await tester.pump();

    expect(copied, isNotNull);
    expect(copied, contains('vsync_offset_ms'));
    expect(find.text('CSV 原始帧已复制'), findsOneWidget);
  });

  testWidgets('导出到文件写入有界槽位并提示', (tester) async {
    final store = FakeExportStore();
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(
      tester,
      collector: collector,
      exporter: PerfRunExporter(store),
    );
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
    await tester.tap(find.byKey(const Key('perf_stop_button')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_export_button')));
    await tester.pumpAndSettle();

    expect(store.files.keys.toSet(), <String>{
      'perf_diagnostics_1.json',
      'perf_diagnostics_1.csv',
    });
    expect(find.byKey(const Key('perf_export_ok')), findsOneWidget);
  });

  testWidgets('导出失败只给可重试提示，不泄漏路径', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(
      tester,
      collector: collector,
      exporter: PerfRunExporter(ThrowingExportStore()),
    );
    await tester.tap(find.byKey(const Key('perf_start_button')));
    await tester.pump();
    env.deliver(<FrameTiming>[fakeTiming(vsyncStart: 1000000)]);
    await tester.tap(find.byKey(const Key('perf_stop_button')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_export_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('perf_export_error')), findsOneWidget);
    expect(find.text('导出失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('C:\\'), findsNothing);
  });

  testWidgets('没有结果时导出按钮不可用', (tester) async {
    final env = FakeFrameTimingEnv();
    final collector = env.build();

    await pumpDiagnostics(tester, collector: collector);

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('perf_copy_json_button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('perf_export_button')))
          .onPressed,
      isNull,
    );
  });

  group('无障碍 / 窄屏', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('360 宽 + textScale 2（$brightness）不溢出且可滚动', (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.reset);

        final env = FakeFrameTimingEnv();
        final collector = env.build();

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 800),
                textScaler: TextScaler.linear(2),
              ),
              child: PerformanceDiagnosticsPage(collector: collector),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('perf_start_button')), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 动作按钮高度不小于 48。
        final size = tester.getSize(find.byKey(const Key('perf_start_button')));
        expect(size.height, greaterThanOrEqualTo(48));

        // 能滚到底部导出区。
        await tester.scrollUntilVisible(
          find.byKey(const Key('perf_export_button')),
          300,
        );
        expect(find.byKey(const Key('perf_export_button')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
