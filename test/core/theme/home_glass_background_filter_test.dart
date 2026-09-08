import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/core/theme/widgets/home_glass_background_filter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.FragmentProgram glassProgram;
  late ui.FragmentProgram ribbonProgram;

  setUpAll(() async {
    // Loader injection tests lifecycle behavior, not removed shader variants.
    glassProgram = await ui.FragmentProgram.fromAsset(
      'shaders/home_collage_background.frag',
    );
    ribbonProgram = glassProgram;
  });

  setUp(() {
    AppLogger.instance.debugReset();
    HomeGlassBackgroundFilter.debugResetShaderCache();
  });

  tearDown(HomeGlassBackgroundFilter.debugResetShaderCache);

  Widget filter({
    required HomeShaderMode mode,
    double intensity = 0.4,
    bool tickerEnabled = true,
    Key? key,
  }) {
    return TickerMode(
      enabled: tickerEnabled,
      child: HomeGlassBackgroundFilter(
        key: key,
        mode: mode,
        intensity: intensity,
        levels: 12,
        themeColor: const Color(0xFF8B1A2D),
        monetColors: null,
        isDarkMode: false,
        opacity: 1,
        animationSpeed: 1,
        child: const Text('bg-child'),
      ),
    );
  }

  Future<void> pumpFilter(
    WidgetTester tester, {
    required HomeShaderMode mode,
    double intensity = 0.4,
    bool tickerEnabled = true,
    Key? key,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: filter(
            key: key,
            mode: mode,
            intensity: intensity,
            tickerEnabled: tickerEnabled,
          ),
        ),
      ),
    );
  }

  HomeGlassBackgroundFilterState stateOf(WidgetTester tester) {
    return tester.state<HomeGlassBackgroundFilterState>(
      find.byType(HomeGlassBackgroundFilter),
    );
  }

  test('着色器加载按模式去重且失败后可重试', () async {
    var calls = 0;
    final completer = Completer<ui.FragmentProgram>();
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) {
      calls += 1;
      expect(mode, HomeShaderMode.glass);
      return completer.future;
    };

    final first = HomeGlassBackgroundFilter.debugLoadShader(
      HomeShaderMode.glass,
    );
    final second = HomeGlassBackgroundFilter.debugLoadShader(
      HomeShaderMode.glass,
    );
    expect(calls, 1);

    completer.complete(glassProgram);
    expect(await first, same(glassProgram));
    expect(await second, same(glassProgram));
    expect(
      HomeGlassBackgroundFilter.debugShaderInitialized(HomeShaderMode.glass),
      isTrue,
    );

    HomeGlassBackgroundFilter.debugResetShaderCache(clearLoader: false);
    var failures = 0;
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) async {
      failures += 1;
      throw StateError('shader missing');
    };

    expect(
      await HomeGlassBackgroundFilter.debugLoadShader(HomeShaderMode.glass),
      isNull,
    );
    expect(
      HomeGlassBackgroundFilter.debugShaderInitialized(HomeShaderMode.glass),
      isFalse,
    );
    expect(
      await HomeGlassBackgroundFilter.debugLoadShader(HomeShaderMode.glass),
      isNull,
    );
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

  testWidgets('加载失败时回退子组件且不挂着色器', (tester) async {
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) async {
      throw StateError('gpu unavailable');
    };

    await pumpFilter(tester, mode: HomeShaderMode.glass);
    await tester.pump();

    expect(find.text('bg-child'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(stateOf(tester).debugFragmentShader, isNull);
  });

  testWidgets('resumed 且着色器为空时只重试一次并可恢复', (tester) async {
    var calls = 0;
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) async {
      calls += 1;
      if (calls == 1) {
        throw StateError('gpu unavailable');
      }
      return glassProgram;
    };

    await pumpFilter(tester, mode: HomeShaderMode.glass);
    await tester.pump();
    expect(stateOf(tester).debugFragmentShader, isNull);
    expect(find.byType(ImageFiltered), findsNothing);
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
    expect(stateOf(tester).debugBoundMode, HomeShaderMode.glass);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('同一 widget 重建复用 FragmentShader，换模式才释放', (tester) async {
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) async {
      return mode == HomeShaderMode.ribbon ? ribbonProgram : glassProgram;
    };

    var mode = HomeShaderMode.glass;
    var intensity = 0.2;
    late StateSetter localSetState;
    final key = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              localSetState = setState;
              return filter(key: key, mode: mode, intensity: intensity);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final first = stateOf(tester).debugFragmentShader;
    expect(first, isNotNull);

    localSetState(() => intensity = 0.8);
    await tester.pump();
    expect(stateOf(tester).debugFragmentShader, same(first));

    localSetState(() => mode = HomeShaderMode.ribbon);
    await tester.pump();
    await tester.pump();

    final second = stateOf(tester).debugFragmentShader;
    expect(second, isNotNull);
    expect(second, isNot(same(first)));
    expect(stateOf(tester).debugBoundMode, HomeShaderMode.ribbon);
  });

  testWidgets('异步模式切换忽略迟到的旧结果', (tester) async {
    final glassLoad = Completer<ui.FragmentProgram>();
    final ribbonLoad = Completer<ui.FragmentProgram>();
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) {
      return switch (mode) {
        HomeShaderMode.glass => glassLoad.future,
        HomeShaderMode.ribbon => ribbonLoad.future,
        HomeShaderMode.collage => ribbonLoad.future,
      };
    };

    await pumpFilter(tester, mode: HomeShaderMode.glass);
    await tester.pump();
    expect(stateOf(tester).debugFragmentShader, isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: filter(mode: HomeShaderMode.ribbon)),
      ),
    );
    await tester.pump();

    glassLoad.complete(glassProgram);
    await tester.pump();
    expect(stateOf(tester).debugBoundMode, isNot(HomeShaderMode.glass));
    expect(stateOf(tester).debugFragmentShader, isNull);

    ribbonLoad.complete(ribbonProgram);
    await tester.pump();
    expect(stateOf(tester).debugBoundMode, HomeShaderMode.ribbon);
    expect(stateOf(tester).debugFragmentShader, isNotNull);
  });

  testWidgets('销毁后不采纳迟到的加载结果', (tester) async {
    final delayed = Completer<ui.FragmentProgram>();
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) => delayed.future;

    await pumpFilter(tester, mode: HomeShaderMode.glass);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    delayed.complete(glassProgram);
    await tester.pump();
    expect(find.byType(HomeGlassBackgroundFilter), findsNothing);
  });

  testWidgets('ticker 跟随模式、TickerMode 与生命周期，暂停后时间连续', (tester) async {
    HomeGlassBackgroundFilter.debugProgramLoader = (mode) async {
      return mode == HomeShaderMode.ribbon ? ribbonProgram : glassProgram;
    };

    var mode = HomeShaderMode.glass;
    var tickerEnabled = true;
    late StateSetter localSetState;
    final key = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              localSetState = setState;
              return filter(key: key, mode: mode, tickerEnabled: tickerEnabled);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isFalse);

    localSetState(() => mode = HomeShaderMode.ribbon);
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isTrue);

    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    final timeAfterFirstFrame = stateOf(tester).debugShaderTimeSeconds;
    expect(timeAfterFirstFrame, greaterThan(0));

    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isFalse);
    final pausedTime = stateOf(tester).debugShaderTimeSeconds;

    await tester.pump(const Duration(seconds: 2));
    expect(stateOf(tester).debugShaderTimeSeconds, pausedTime);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(stateOf(tester).debugTickerActive, isTrue);
    await tester.pump(const Duration(milliseconds: 16));
    expect(stateOf(tester).debugShaderTimeSeconds, pausedTime);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    expect(stateOf(tester).debugShaderTimeSeconds, greaterThan(pausedTime));

    localSetState(() => tickerEnabled = false);
    await tester.pump();
    final mutedTime = stateOf(tester).debugShaderTimeSeconds;
    await tester.pump(const Duration(milliseconds: 80));
    expect(stateOf(tester).debugShaderTimeSeconds, mutedTime);
  });
}
