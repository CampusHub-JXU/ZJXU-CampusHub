import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/core/theme/widgets/app_wallpaper_backdrop.dart';
import 'package:jxu_campus_hub/core/theme/widgets/home_fluid_background.dart';

void main() {
  late ui.FragmentProgram program;

  setUpAll(() async {
    program = await ui.FragmentProgram.fromAsset(
      'shaders/home_collage_background.frag',
    );
  });

  setUp(() {
    HomeFluidBackgroundState.debugResetSharedClock();
    PageTransitionActivity.instance.debugReset();
    HomeFluidBackground.debugResetShaderCache();
    HomeFluidBackground.debugProgramLoader = () async => program;
    HomeFluidBackground.debugSkipPaint = true;
  });

  tearDown(() {
    PageTransitionActivity.instance.debugReset();
    HomeFluidBackground.debugResetShaderCache();
    HomeFluidBackground.debugSkipPaint = false;
  });

  /// 背景内容（OverflowBox 的子节点）实际布局出的尺寸。
  Size backdropContentSize(WidgetTester tester) {
    final overflow = tester.renderObject<RenderBox>(
      find.descendant(
        of: find.byType(AppWallpaperBackdrop),
        matching: find.byType(OverflowBox),
      ),
    );
    var child = overflow;
    overflow.visitChildren((c) => child = c as RenderBox);
    return child.size;
  }

  testWidgets('keyboard insets do not squash the backdrop', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Widget app({required double keyboard}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: const Scaffold(
          body: Stack(fit: StackFit.expand, children: [AppWallpaperBackdrop()]),
        ),
      ),
    );

    await tester.pumpWidget(app(keyboard: 0));
    await tester.pump();
    expect(backdropContentSize(tester), const Size(400, 800));

    // 键盘弹出：Scaffold body 被压到 500 高，背景内容仍按整屏高度布局。
    await tester.pumpWidget(app(keyboard: 300));
    await tester.pump();
    expect(
      tester.getSize(find.byType(AppWallpaperBackdrop)),
      const Size(400, 500),
    );
    expect(backdropContentSize(tester), const Size(400, 800));
  });
}
