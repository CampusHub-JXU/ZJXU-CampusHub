import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';

/// 取子树里「当前位移最大」的 SlideTransition 的 dx。
///
/// 转场树里挂着两个 SlideTransition（入场位移在外层、退场视差在内层），
/// find.ancestor 的返回顺序依赖遍历方向，这里取 max 避免和顺序耦合。
double _maxSlideDx(WidgetTester tester, Finder target) {
  return tester
      .widgetList<SlideTransition>(
        find.ancestor(of: target, matching: find.byType(SlideTransition)),
      )
      .map((t) => t.position.value.dx)
      .fold<double>(0, (double a, double b) => a.abs() > b.abs() ? a : b);
}

void main() {
  // 回归：AppTheme 的 pageTransitionsTheme 必须让 push 产生真实的
  // 渐入+位移转场，而不是瞬切。采样点取转场时长的一半，避免把时长硬编码进
  // 断言（改时长不该改测试）。
  testWidgets('app theme push transition animates over its duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkThemeFor(AppColors.primary),
        home: const Scaffold(body: Center(child: Text('home-page'))),
      ),
    );

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('sub-page'))),
          ),
        );
    await tester.pump(); // 安装新路由
    await tester.pump(); // 构建新页内容

    final Animation<double> animation = ModalRoute.of(
      tester.element(find.text('sub-page')),
    )!.animation!;
    final Duration total = ModalRoute.of(tester.element(find.text('sub-page')))!
        .transitionDuration;

    // 对齐 Android 系统 Activity 转场：上层页只在开头一小段快速淡入。
    await tester.pump(total * 20 ~/ 100);
    final earlyFades = tester
        .widgetList<FadeTransition>(find.byType(FadeTransition))
        .map((t) => t.opacity.value)
        .where((v) => v > 0.05 && v < 0.95)
        .toList();
    expect(earlyFades, isNotEmpty, reason: '转场前段应有渐变层未完成');

    await tester.pump(total * 30 ~/ 100);
    expect(
      animation.value,
      allOf(greaterThan(0.1), lessThan(0.9)),
      reason: '转场中段应仍在进行（实测 ${animation.value}），瞬切会直接到 1.0',
    );
    expect(
      _maxSlideDx(tester, find.text('sub-page')),
      greaterThan(0.0),
      reason: '转场中段新页仍应有横向位移',
    );

    await tester.pump(total);
    expect(animation.value, 1.0, reason: '转场结束后新页应完全就位');
  });

  // 回归：返回（pop）方向的节奏必须先快后慢。
  //
  // pop 时路由动画是倒放的，CurvedAnimation 在 reverseCurve 为空时会直接
  // 复用正向曲线（SDK animations.dart:377），easeOutCubic 倒放即 easeInCubic
  // ——起步几乎不动、末尾突然冲刺，观感就是「先慢后快」。这里直接断言「前半
  // 段时间走完一半以上的行程」，反向曲线被误删会立刻红。
  testWidgets('app theme pop transition front-loads its travel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkThemeFor(AppColors.primary),
        home: const Scaffold(body: Center(child: Text('home-page'))),
      ),
    );

    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator),
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('sub-page'))),
      ),
    );
    await tester.pump();
    await tester.pump();

    final Finder subPage = find.text('sub-page');
    final Duration total = ModalRoute.of(tester.element(subPage))!
        .transitionDuration;

    // 等 push 完全结束后再返回，避免两段动画叠加干扰采样。
    await tester.pump(total);
    await tester.pump(total);

    navigator.pop();
    await tester.pump(); // 启动返回动画

    await tester.pump(total ~/ 2);
    final double halfWay = _maxSlideDx(tester, subPage);

    await tester.pump(Duration(milliseconds: total.inMilliseconds * 45 ~/ 100));
    final double nearEnd = _maxSlideDx(tester, subPage);

    expect(nearEnd, greaterThan(0.0), reason: '返回动画应在进行中');
    final double progress = halfWay / nearEnd;
    expect(
      progress,
      greaterThan(0.5),
      reason: '返回转场应先快后慢：半程应走完一半以上行程（实测 ${progress.toStringAsFixed(2)}）',
    );
  });

  // 系统「移除动画」：push 不再包位移 / 淡入转场，新页直接就位。
  testWidgets('app theme push skips transition when animations are disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkThemeFor(AppColors.primary),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: Center(child: Text('home-page'))),
      ),
    );

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('sub-page'))),
          ),
        );
    await tester.pump();
    await tester.pump();

    expect(
      find.ancestor(
        of: find.text('sub-page'),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    expect(
      tester
          .widgetList<FadeTransition>(
            find.ancestor(
              of: find.text('sub-page'),
              matching: find.byType(FadeTransition),
            ),
          )
          .where((t) => t.opacity.value < 1),
      isEmpty,
    );
  });
}
