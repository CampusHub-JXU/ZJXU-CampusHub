import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/core/theme/widgets/home_fluid_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.FragmentProgram program;

  setUpAll(() async {
    program = await ui.FragmentProgram.fromAsset(
      'shaders/home_collage_background.frag',
    );
  });

  setUp(() {
    AppLogger.instance.debugReset();
    PageTransitionActivity.instance.debugReset();
    HomeFluidBackground.debugResetShaderCache();
    HomeFluidBackground.debugProgramLoader = () async => program;
    // 节拍 / 暂停逻辑与真实出图无关，默认跳过软件光栅化以免用例极慢。
    HomeFluidBackground.debugSkipRender = true;
  });

  tearDown(() {
    PageTransitionActivity.instance.debugReset();
    HomeFluidBackground.debugResetShaderCache();
  });

  Widget background({
    bool tickerEnabled = true,
    bool disableAnimations = false,
    double animationSpeed = 1,
    Key? key,
  }) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: TickerMode(
        enabled: tickerEnabled,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: HomeFluidBackground(
            key: key,
            intensity: 0.4,
            themeColor: const Color(0xFF8B1A2D),
            monetColors: null,
            isDarkMode: false,
            opacity: 1,
            animationSpeed: animationSpeed,
            fallback: const Text('wallpaper-fallback'),
          ),
        ),
      ),
    );
  }

  HomeFluidBackgroundState stateOf(WidgetTester tester) =>
      tester.state<HomeFluidBackgroundState>(find.byType(HomeFluidBackground));

  /// 以 16ms 一帧推进 [total]。
  Future<void> advance(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 16);
    var elapsed = Duration.zero;
    while (elapsed < total) {
      await tester.pump(step);
      elapsed += step;
    }
  }

  testWidgets('真实出图：低分辨率图铺满且不回退壁纸', (tester) async {
    HomeFluidBackground.debugSkipRender = false;
    tester.view.physicalSize = const Size(200, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 200));

    expect(stateOf(tester).debugRenderFailed, isFalse);
    expect(find.text('wallpaper-fallback'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  test('着色器加载去重且失败后可重试', () async {
    var calls = 0;
    final completer = Completer<ui.FragmentProgram>();
    HomeFluidBackground.debugProgramLoader = () {
      calls += 1;
      return completer.future;
    };

    final first = HomeFluidBackground.debugLoadShader();
    final second = HomeFluidBackground.debugLoadShader();
    expect(calls, 1);
    completer.complete(program);
    expect(await first, same(program));
    expect(await second, same(program));
    expect(HomeFluidBackground.debugShaderInitialized, isTrue);

    HomeFluidBackground.debugResetShaderCache(clearLoader: false);
    var failures = 0;
    HomeFluidBackground.debugProgramLoader = () async {
      failures += 1;
      throw StateError('shader missing');
    };
    expect(await HomeFluidBackground.debugLoadShader(), isNull);
    expect(HomeFluidBackground.debugShaderInitialized, isFalse);
    expect(await HomeFluidBackground.debugLoadShader(), isNull);
    expect(failures, 2);
    expect(
      AppLogger.instance.entries.where(
        (entry) =>
            entry.category == LogCategory.ui &&
            entry.level == LogLevel.warn &&
            entry.message.contains('首页着色器加载失败'),
      ),
      isNotEmpty,
    );
  });

  testWidgets('加载失败时回退原始壁纸且不跑 ticker', (tester) async {
    HomeFluidBackground.debugProgramLoader = () async {
      throw StateError('gpu unavailable');
    };
    await tester.pumpWidget(background());
    await tester.pump();

    expect(find.text('wallpaper-fallback'), findsOneWidget);
    expect(stateOf(tester).debugFragmentShader, isNull);
    expect(stateOf(tester).debugTickerActive, isFalse);
  });

  testWidgets('resumed 且着色器为空时只重试一次并可恢复', (tester) async {
    var calls = 0;
    HomeFluidBackground.debugProgramLoader = () async {
      calls += 1;
      if (calls == 1) throw StateError('gpu unavailable');
      return program;
    };
    await tester.pumpWidget(background());
    await tester.pump();
    expect(stateOf(tester).debugFragmentShader, isNull);
    expect(calls, 1);

    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 2);
    expect(stateOf(tester).debugFragmentShader, isNotNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('销毁后不采纳迟到的加载结果', (tester) async {
    final delayed = Completer<ui.FragmentProgram>();
    HomeFluidBackground.debugProgramLoader = () => delayed.future;
    await tester.pumpWidget(background());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    delayed.complete(program);
    await tester.pump();
    expect(find.byType(HomeFluidBackground), findsNothing);
  });

  testWidgets('ticker 跟随 TickerMode 与生命周期，暂停后时间连续', (tester) async {
    var tickerEnabled = true;
    late StateSetter localSetState;
    final key = GlobalKey();
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          localSetState = setState;
          return background(key: key, tickerEnabled: tickerEnabled);
        },
      ),
    );
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isTrue);

    await advance(tester, const Duration(milliseconds: 400));
    final running = stateOf(tester).debugShaderTimeSeconds;
    expect(running, greaterThan(0));

    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isFalse);
    final paused = stateOf(tester).debugShaderTimeSeconds;
    await tester.pump(const Duration(seconds: 2));
    expect(stateOf(tester).debugShaderTimeSeconds, paused);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isTrue);
    await advance(tester, const Duration(milliseconds: 400));
    final resumed = stateOf(tester).debugShaderTimeSeconds;
    expect(resumed, greaterThan(paused));
    // 暂停的 2 秒不会被补算成一次跳变。
    expect(resumed - paused, lessThan(1.0));

    localSetState(() => tickerEnabled = false);
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isFalse);
    final muted = stateOf(tester).debugShaderTimeSeconds;
    await tester.pump(const Duration(milliseconds: 200));
    expect(stateOf(tester).debugShaderTimeSeconds, muted);
  });

  testWidgets('出图节拍约 15fps：一秒内时间只推进十几次', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 100));

    final seen = <double>{};
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      seen.add(stateOf(tester).debugShaderTimeSeconds);
    }
    // 60 个 16ms 帧 ≈ 0.96s；64ms 节拍 → 约 15 次推进（含起始值）。
    expect(seen.length, inInclusiveRange(12, 17));
  });

  testWidgets('节拍之间不请求任何帧（定时器而非 Ticker）', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    // 刚出完一帧、距下一个 64ms 节拍还远：框架不应有待处理的帧。若误用每个
    // vsync 触发的 Ticker，这里会恒为 true，整屏每个 vsync 都在重绘。
    await tester.pump(const Duration(milliseconds: 5));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('页面转场期间不推进着色器时间', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 300));

    PageTransitionActivity.instance.acquire();
    final before = stateOf(tester).debugShaderTimeSeconds;
    await advance(tester, const Duration(milliseconds: 400));
    expect(stateOf(tester).debugShaderTimeSeconds, before);

    PageTransitionActivity.instance.release();
    await advance(tester, const Duration(milliseconds: 400));
    expect(stateOf(tester).debugShaderTimeSeconds, greaterThan(before));
  });

  testWidgets('系统减弱动画时不跑 ticker，恢复后继续', (tester) async {
    var reduce = true;
    late StateSetter localSetState;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          localSetState = setState;
          return background(disableAnimations: reduce);
        },
      ),
    );
    await tester.pump();
    expect(stateOf(tester).debugReduceMotion, isTrue);
    expect(stateOf(tester).debugTickerActive, isFalse);
    await advance(tester, const Duration(milliseconds: 400));
    expect(stateOf(tester).debugShaderTimeSeconds, 0);

    localSetState(() => reduce = false);
    await tester.pump();
    expect(stateOf(tester).debugReduceMotion, isFalse);
    expect(stateOf(tester).debugTickerActive, isTrue);
  });

  testWidgets('动画速度为 0 时不跑 ticker', (tester) async {
    await tester.pumpWidget(background(animationSpeed: 0));
    await tester.pump();
    expect(stateOf(tester).debugFragmentShader, isNotNull);
    expect(stateOf(tester).debugTickerActive, isFalse);
  });

  testWidgets('无触摸 45 秒后缓出冻结并停 ticker，触摸后恢复', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isTrue);

    // 45s 内保持运行。
    await advance(tester, const Duration(seconds: 40));
    expect(stateOf(tester).debugFrozen, isFalse);
    expect(stateOf(tester).debugTickerActive, isTrue);
    expect(stateOf(tester).debugMotion, 1.0);

    // 超过阈值后 2 秒内缓出到静止，然后 ticker 停止。
    await advance(tester, const Duration(seconds: 8));
    expect(stateOf(tester).debugFrozen, isTrue);
    expect(stateOf(tester).debugTickerActive, isFalse);
    final frozenTime = stateOf(tester).debugShaderTimeSeconds;
    await advance(tester, const Duration(seconds: 2));
    expect(stateOf(tester).debugShaderTimeSeconds, frozenTime);

    // 任意触摸唤醒。
    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.up();
    await tester.pump();
    expect(stateOf(tester).debugFrozen, isFalse);
    expect(stateOf(tester).debugTickerActive, isTrue);
    await advance(tester, const Duration(seconds: 1));
    expect(stateOf(tester).debugMotion, 1.0);
    expect(stateOf(tester).debugShaderTimeSeconds, greaterThan(frozenTime));
  });

  testWidgets('触摸会重置空闲计时', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(seconds: 30));
    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.up();
    await advance(tester, const Duration(seconds: 30));
    // 距上次触摸只有 30s，总运行 60s：仍应在动。
    expect(stateOf(tester).debugFrozen, isFalse);
    expect(stateOf(tester).debugTickerActive, isTrue);
  });
}
