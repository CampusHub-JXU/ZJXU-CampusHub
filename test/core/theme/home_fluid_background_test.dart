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
    HomeFluidBackgroundState.debugResetSharedClock();
    AppLogger.instance.debugReset();
    PageTransitionActivity.instance.debugReset();
    HomeFluidBackground.debugResetShaderCache();
    HomeFluidBackground.debugProgramLoader = () async => program;
    HomeFluidBackground.debugRefreshRate = 60;
    // 出帧节拍与暂停逻辑和真实光栅化无关，默认跳过软件光栅化以免用例极慢。
    HomeFluidBackground.debugSkipPaint = true;
  });

  tearDown(() {
    PageTransitionActivity.instance.debugReset();
    HomeFluidBackground.debugResetShaderCache();
  });

  Widget background({
    bool tickerEnabled = true,
    bool disableAnimations = false,
    double animationSpeed = 1,
    int targetFps = 60,
    Key? key,
  }) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: TickerMode(
        enabled: tickerEnabled,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: HomeFluidBackground(
              key: key,
              intensity: 0.4,
              themeColor: const Color(0xFF8B1A2D),
              monetColors: null,
              isDarkMode: false,
              opacity: 1,
              animationSpeed: animationSpeed,
              targetFps: targetFps,
              fallback: const Text('wallpaper-fallback'),
            ),
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

  /// 推进约 1 秒（62 个 16ms 帧），返回这段时间内真正出了多少帧。
  Future<int> framesPerSecond(WidgetTester tester) async {
    final before = stateOf(tester).debugRenderedFrames;
    await advance(tester, const Duration(milliseconds: 992));
    return stateOf(tester).debugRenderedFrames - before;
  }

  group('frameIntervalFor 帧率档位到出帧间隔的映射', () {
    test('低于屏幕刷新率：按 1/fps 节流', () {
      expect(
        HomeFluidBackground.frameIntervalFor(30, 60),
        const Duration(microseconds: 33333),
      );
      expect(
        HomeFluidBackground.frameIntervalFor(45, 60),
        const Duration(microseconds: 22222),
      );
      expect(
        HomeFluidBackground.frameIntervalFor(60, 120),
        const Duration(microseconds: 16667),
      );
      expect(
        HomeFluidBackground.frameIntervalFor(90, 120),
        const Duration(microseconds: 11111),
      );
    });

    test('达到或超过屏幕刷新率：不节流（每个 vsync 一帧）', () {
      expect(HomeFluidBackground.frameIntervalFor(60, 60), isNull);
      expect(HomeFluidBackground.frameIntervalFor(90, 60), isNull);
      expect(HomeFluidBackground.frameIntervalFor(120, 60), isNull);
      expect(HomeFluidBackground.frameIntervalFor(120, 120), isNull);
      // 刷新率常报 59.94 / 119.88：60 / 120 档仍视为「跟随屏幕」。
      expect(HomeFluidBackground.frameIntervalFor(60, 59.94), isNull);
      expect(HomeFluidBackground.frameIntervalFor(120, 119.88), isNull);
    });

    test('非法值不节流', () {
      expect(HomeFluidBackground.frameIntervalFor(0, 60), isNull);
      expect(HomeFluidBackground.frameIntervalFor(-5, 60), isNull);
      expect(HomeFluidBackground.frameIntervalFor(30, 0), isNull);
    });
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

  testWidgets('加载失败时回退原始壁纸且不出帧', (tester) async {
    HomeFluidBackground.debugProgramLoader = () async {
      throw StateError('gpu unavailable');
    };
    await tester.pumpWidget(background());
    await tester.pump();

    expect(find.text('wallpaper-fallback'), findsOneWidget);
    expect(stateOf(tester).debugFragmentShader, isNull);
    expect(stateOf(tester).debugDriverActive, isFalse);
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

  testWidgets('出帧驱动跟随 TickerMode 与生命周期，暂停后时间连续', (tester) async {
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
    expect(stateOf(tester).debugDriverActive, isTrue);

    await advance(tester, const Duration(milliseconds: 400));
    final running = stateOf(tester).debugShaderTimeSeconds;
    expect(running, greaterThan(0));

    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(stateOf(tester).debugDriverActive, isFalse);
    final paused = stateOf(tester).debugShaderTimeSeconds;
    await tester.pump(const Duration(seconds: 2));
    expect(stateOf(tester).debugShaderTimeSeconds, paused);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(stateOf(tester).debugDriverActive, isTrue);
    await advance(tester, const Duration(milliseconds: 400));
    final resumed = stateOf(tester).debugShaderTimeSeconds;
    expect(resumed, greaterThan(paused));
    // 暂停的 2 秒不会被补算成一次跳变。
    expect(resumed - paused, lessThan(1.0));

    localSetState(() => tickerEnabled = false);
    await tester.pump();
    expect(stateOf(tester).debugDriverActive, isFalse);
    final muted = stateOf(tester).debugShaderTimeSeconds;
    await tester.pump(const Duration(milliseconds: 200));
    expect(stateOf(tester).debugShaderTimeSeconds, muted);
  });

  group('帧率档位的实际出帧节拍（屏幕 60Hz）', () {
    testWidgets('60 fps：每个 vsync 一帧', (tester) async {
      await tester.pumpWidget(background(targetFps: 60));
      await tester.pump();
      await advance(tester, const Duration(milliseconds: 100));
      expect(await framesPerSecond(tester), inInclusiveRange(58, 62));
    });

    testWidgets('90 / 120 fps 超过屏幕刷新率：同样每个 vsync 一帧', (tester) async {
      await tester.pumpWidget(background(targetFps: 120));
      await tester.pump();
      await advance(tester, const Duration(milliseconds: 100));
      expect(await framesPerSecond(tester), inInclusiveRange(58, 62));
    });

    testWidgets('30 fps：约一半的帧', (tester) async {
      await tester.pumpWidget(background(targetFps: 30));
      await tester.pump();
      await advance(tester, const Duration(milliseconds: 100));
      expect(await framesPerSecond(tester), inInclusiveRange(27, 34));
    });

    testWidgets('45 fps：介于 30 与 60 之间', (tester) async {
      await tester.pumpWidget(background(targetFps: 45));
      await tester.pump();
      await advance(tester, const Duration(milliseconds: 100));
      expect(await framesPerSecond(tester), inInclusiveRange(40, 50));
    });

    testWidgets('运行中切换帧率立即生效', (tester) async {
      var fps = 60;
      late StateSetter localSetState;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            localSetState = setState;
            return background(targetFps: fps);
          },
        ),
      );
      await tester.pump();
      await advance(tester, const Duration(milliseconds: 100));
      expect(await framesPerSecond(tester), inInclusiveRange(58, 62));

      localSetState(() => fps = 30);
      await tester.pump();
      expect(await framesPerSecond(tester), inInclusiveRange(27, 34));

      localSetState(() => fps = 60);
      await tester.pump();
      expect(await framesPerSecond(tester), inInclusiveRange(58, 62));
    });

    testWidgets('120Hz 屏幕上 60 fps 档位按 1/60 节流', (tester) async {
      HomeFluidBackground.debugRefreshRate = 120;
      await tester.pumpWidget(background(targetFps: 60));
      await tester.pump();
      // 测试里 8ms 一帧模拟 120Hz。
      const step = Duration(milliseconds: 8);
      for (var i = 0; i < 12; i++) {
        await tester.pump(step);
      }
      final before = stateOf(tester).debugRenderedFrames;
      for (var i = 0; i < 125; i++) {
        await tester.pump(step);
      }
      expect(
        stateOf(tester).debugRenderedFrames - before,
        inInclusiveRange(57, 63),
      );
    });

    testWidgets('节流时节拍之间不请求任何帧（定时器而非 Ticker）', (tester) async {
      await tester.pumpWidget(background(targetFps: 30));
      await tester.pump();
      // 先等到一次出帧刚刚完成。
      final start = stateOf(tester).debugRenderedFrames;
      while (stateOf(tester).debugRenderedFrames == start) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // 距下一个 33ms 节拍还有一段：框架不应有待处理的帧。若误用每个 vsync
      // 触发的 Ticker，这里恒为 true，整屏每个 vsync 都在重绘。
      await tester.pump(const Duration(milliseconds: 4));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  testWidgets('页面转场期间不推进着色器时间，结束后恢复且不跳变', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 300));

    PageTransitionActivity.instance.acquire();
    await tester.pump(const Duration(milliseconds: 16));
    final before = stateOf(tester).debugShaderTimeSeconds;
    await advance(tester, const Duration(milliseconds: 400));
    expect(stateOf(tester).debugShaderTimeSeconds, before);

    PageTransitionActivity.instance.release();
    await advance(tester, const Duration(milliseconds: 400));
    final after = stateOf(tester).debugShaderTimeSeconds;
    expect(after, greaterThan(before));
    // 转场里被丢掉的时间不得补回：恢复后只前进约 0.4s（实际运行）。
    expect(after - before, lessThan(0.45));
  });

  testWidgets('转场结束后下一帧立即恢复出帧，不等轮询', (tester) async {
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 300));

    PageTransitionActivity.instance.acquire();
    await tester.pump(const Duration(milliseconds: 16));
    await advance(tester, const Duration(milliseconds: 200));
    final frames = stateOf(tester).debugRenderedFrames;

    PageTransitionActivity.instance.release();
    // 旧实现 100ms 轮询一次：这里只给 1ms，必须已经恢复出帧。
    await tester.pump(const Duration(milliseconds: 1));
    expect(stateOf(tester).debugRenderedFrames, greaterThan(frames));
  });

  testWidgets('系统减弱动画时不出帧，恢复后继续', (tester) async {
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
    expect(stateOf(tester).debugDriverActive, isFalse);
    await advance(tester, const Duration(milliseconds: 400));
    expect(stateOf(tester).debugShaderTimeSeconds, 0);
    expect(stateOf(tester).debugRenderedFrames, 0);

    localSetState(() => reduce = false);
    await tester.pump();
    expect(stateOf(tester).debugReduceMotion, isFalse);
    expect(stateOf(tester).debugDriverActive, isTrue);
  });

  testWidgets('动画速度为 0 时不出帧', (tester) async {
    await tester.pumpWidget(background(animationSpeed: 0));
    await tester.pump();
    expect(stateOf(tester).debugFragmentShader, isNotNull);
    expect(stateOf(tester).debugDriverActive, isFalse);
  });

  testWidgets('真实绘制：低分辨率子树铺满且不回退壁纸', (tester) async {
    HomeFluidBackground.debugSkipPaint = false;
    tester.view.physicalSize = const Size(200, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(background());
    await tester.pump();
    await advance(tester, const Duration(milliseconds: 200));

    expect(stateOf(tester).debugRenderFailed, isFalse);
    expect(find.text('wallpaper-fallback'), findsNothing);
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('多个实例共享同一时钟：切 tab 不跳相位，同时可见也不两倍速', (tester) async {
    Widget sized(Widget child) =>
        SizedBox(width: 200, height: 400, child: child);
    var secondVisible = false;
    late StateSetter localSetState;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          localSetState = setState;
          return Row(
            textDirection: TextDirection.ltr,
            children: [
              sized(background()),
              sized(background(tickerEnabled: secondVisible)),
            ],
          );
        },
      ),
    );
    await tester.pump();
    final states = tester
        .stateList<HomeFluidBackgroundState>(find.byType(HomeFluidBackground))
        .toList();
    expect(states, hasLength(2));

    // 只有第一个在跑：1 秒后约 1 秒，第二个（暂停中）读到同一时间。
    await advance(tester, const Duration(seconds: 1));
    final single = states[0].debugShaderTimeSeconds;
    expect(single, closeTo(1.0, 0.1));
    expect(states[1].debugShaderTimeSeconds, single);

    // 两个都在跑：时钟仍按真实时间推进，不会翻倍。
    localSetState(() => secondVisible = true);
    await tester.pump();
    await advance(tester, const Duration(seconds: 1));
    final both = states[0].debugShaderTimeSeconds;
    expect(both - single, closeTo(1.0, 0.1));
    expect(states[1].debugShaderTimeSeconds, both);
  });
}
