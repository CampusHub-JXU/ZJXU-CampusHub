import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_refraction.dart';
import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  Future<void> pumpSurface(
    WidgetTester tester,
    Widget surface, {
    bool dark = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? ThemeData.dark() : null,
        home: Scaffold(body: Center(child: surface)),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 颗粒噪点已移除：任何 CustomPaint 都不应出现在材质层（BackdropFilter）里。
  // nav 档的液态玻璃高光描边刻意放在 BackdropFilter 之外（同级 Stack 前景），
  // 该守卫语义保持不变。
  Finder noisePainterFinder() => find.descendant(
    of: find.byType(BackdropFilter),
    matching: find.byType(CustomPaint),
  );

  // nav 档液态玻璃边缘高光描边。
  Finder liquidEdgePainterFinder() => find.descendant(
    of: find.byType(GlassContainer),
    matching: find.byType(CustomPaint),
  );

  // ClipRRect 外层的 nav 悬浮影：CustomPaint（背景 painter）包住 ClipRRect，
  // evenOdd 挖空玻璃轮廓、只在轮廓外围投影；原先铺满内部的
  // DecoratedBox(BoxShadow) 会透过半透明玻璃把浅色 Dock 染成脏灰。
  // 用背景 painter（非 foregroundPainter）与高光描边区分开。
  Finder outerShadowPainterFinder() => find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint &&
        widget.painter != null &&
        widget.painter!.runtimeType.toString() == '_NavOuterShadowPainter',
  );

  CustomPaint? outerShadowPaint(WidgetTester tester) {
    final finder = outerShadowPainterFinder();
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<CustomPaint>(finder);
  }

  ShapeDecoration surfaceDecoration(WidgetTester tester) {
    final surface = tester.widget<Container>(
      find.descendant(
        of: find.byType(GlassContainer),
        matching: find.byType(Container),
      ),
    );
    return surface.decoration! as ShapeDecoration;
  }

  testWidgets('card 层默认真实模糊（玻璃开启时创建 BackdropFilter）', (tester) async {
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('card 层显式 blurred=false 可关闭模糊（密集列表省 GPU）', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(blurred: false, child: Text('卡片')),
    );

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('nav/overlay 层默认真实模糊', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.overlay, child: Text('弹层')),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('亚克力总开关关闭后降级实色（不透明、无噪点、无 BackdropFilter）', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(noisePainterFinder(), findsNothing);
    expect(surfaceDecoration(tester).color!.a, 1.0);
  });

  testWidgets('亚克力材质保留有界实时模糊、半透明填充，不再叠加颗粒', (tester) async {
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    final backdrop = find.byType(BackdropFilter);
    expect(backdrop, findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(backdrop).filterConfig.toString(),
      contains('bounded'),
    );
    expect(noisePainterFinder(), findsNothing);

    final shape = surfaceDecoration(tester);
    expect(shape.color!.a, lessThan(1.0));
  });

  testWidgets('BackdropFilter 必须严格处于 ClipRRect 祖先内部避免整屏扩散', (tester) async {
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    final clipRRectFinder = find.byType(ClipRRect);
    final backdropFinder = find.descendant(
      of: clipRRectFinder,
      matching: find.byType(BackdropFilter),
    );
    expect(backdropFinder, findsOneWidget);
  });

  testWidgets('nav 档监听 LiquidGlass 就绪：shader 加载完能重建（否则永远停在磨砂）', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );
    final beforeFilter = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter),
    );

    // 模拟 preload 完成：就绪通知翻转。
    LiquidGlass.ready.value = true;
    await tester.pump();

    final afterFilter = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(
      identical(beforeFilter, afterFilter),
      isFalse,
      reason: '就绪翻转必须让 Dock 重建出折射滤镜，而不是停在纯磨砂',
    );
  });

  testWidgets('card 档不订阅液态玻璃就绪（无谓重建）', (tester) async {
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));
    final beforeFilter = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter),
    );

    LiquidGlass.ready.value = true;
    await tester.pump();

    final afterFilter = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(identical(beforeFilter, afterFilter), isTrue);
  });

  testWidgets('shader 未就绪时 Dock 退回纯磨砂 σ≈18.8（磨砂自己撑起材质感）', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );

    final filter = tester
        .widget<BackdropFilter>(find.byType(BackdropFilter))
        .filterConfig
        .toString();
    expect(filter, contains('18.8'));
    expect(filter, isNot(contains('28.2')));
  });

  testWidgets('液态玻璃就绪后 Dock 模糊收敛到 σ≈6.58（兼顾折射感与滚过文字可读性）', (tester) async {
    LiquidGlass.debugForceReady = true;
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );

    final filter = tester
        .widget<BackdropFilter>(find.byType(BackdropFilter))
        .filterConfig
        .toString();
    expect(filter, contains('6.58'));
    expect(filter, isNot(contains('18.8')));
  });

  testWidgets('shader 未就绪时 Dock 底色保持稳健磨砂基底（0.30~0.40）', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );

    expect(surfaceDecoration(tester).color!.a, inInclusiveRange(0.30, 0.40));
  });

  testWidgets('液态玻璃就绪后浅色 Dock 保持通透且对比稳健（0.30~0.40）', (tester) async {
    LiquidGlass.debugForceReady = true;
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );

    expect(surfaceDecoration(tester).color!.a, inInclusiveRange(0.30, 0.40));
  });

  testWidgets('液态玻璃就绪后深色 Dock 保持通透深琉璃且文字清晰（0.22~0.32）', (tester) async {
    LiquidGlass.debugForceReady = true;
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
      dark: true,
    );

    expect(surfaceDecoration(tester).color!.a, inInclusiveRange(0.22, 0.32));
  });

  testWidgets('nav 档贴底通栏（BorderRadius.zero）无外扩悬浮影与四边高光框，仅绘顶缘细分割线', (
    tester,
  ) async {
    LiquidGlass.debugForceReady = true;
    await pumpSurface(
      tester,
      const GlassContainer(
        tier: GlassTier.nav,
        borderRadius: BorderRadius.zero,
        child: Text('贴底通栏'),
      ),
    );

    // 贴底通栏不走液态玻璃合成：三边贴屏的无界模糊会把屏外透明黑卷进核，
    // 形成暗角；改走 bounded 磨砂（AppTileSurface 同款路径）。
    expect(find.byType(LiquidGlassBoundsTracker), findsNothing);
    final backdrop = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(backdrop.filterConfig.toString(), contains('bounded'));
    expect(outerShadowPaint(tester), isNull);
    final edgePaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: liquidEdgePainterFinder(),
      ),
    );
    expect(
      edgePaint.foregroundPainter.runtimeType.toString(),
      '_NavTopDividerPainter',
    );
  });

  testWidgets('card 档显式 liquid=true 走与 nav 同款液态玻璃链路且支持点击', (tester) async {
    LiquidGlass.debugForceReady = true;
    var tapped = false;
    await pumpSurface(
      tester,
      GlassContainer(
        liquid: true,
        onTap: () => tapped = true,
        child: const Text('我的卡片'),
      ),
    );

    expect(find.byType(LiquidGlassBoundsTracker), findsOneWidget);
    expect(outerShadowPaint(tester), isNotNull);
    expect(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: liquidEdgePainterFinder(),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('我的卡片'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('nav 档（浅色 acrylic）挖空外投影画在 ClipRRect 外层并渲染高光描边', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );

    // 悬浮影：CustomPaint 背景 painter 包住 ClipRRect，evenOdd 挖空玻璃
    // 内部，阴影只落在轮廓外围（alpha 0.08 柔和单色影，绝不再透灰）。
    final shadowPaint = outerShadowPaint(tester);
    expect(shadowPaint, isNotNull);
    expect(shadowPaint!.painter, isNotNull);
    expect((shadowPaint.painter! as dynamic).color.a, closeTo(0.08, 0.001));

    // 外投影必须在 ClipRRect 外层（画在内层会被整圈裁掉）。
    expect(
      find.descendant(
        of: outerShadowPainterFinder(),
        matching: find.byType(ClipRRect),
      ),
      findsOneWidget,
    );

    // 高光描边 CustomPaint：在 ClipRRect 内、BackdropFilter 外（守卫不破）。
    expect(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: liquidEdgePainterFinder(),
      ),
      findsOneWidget,
    );
    expect(noisePainterFinder(), findsNothing);

    // 高光描边生效时收起内部 hairline，避免双框。
    final shape =
        (surfaceDecoration(tester).shape as RoundedSuperellipseBorder).side;
    expect(shape, BorderSide.none);
  });

  testWidgets('nav 档（深色 acrylic）外投影沿用配方不透明度', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
      dark: true,
    );

    final shadowPaint = outerShadowPaint(tester);
    expect(shadowPaint, isNotNull);
    expect((shadowPaint!.painter! as dynamic).color.a, closeTo(0.14, 0.001));
    expect(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: liquidEdgePainterFinder(),
      ),
      findsOneWidget,
    );
    expect(noisePainterFinder(), findsNothing);
  });

  testWidgets('card 档无高光描边、无外层悬浮影', (tester) async {
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(liquidEdgePainterFinder(), findsNothing);
    expect(outerShadowPainterFinder(), findsNothing);
  });

  testWidgets('overlay 档无高光描边、无外层悬浮影', (tester) async {
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.overlay, child: Text('弹层')),
    );

    expect(liquidEdgePainterFinder(), findsNothing);
    expect(outerShadowPainterFinder(), findsNothing);
  });

  testWidgets('solid 退化态：nav 无高光描边、无悬浮影，仍走普通描边', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpSurface(
      tester,
      const GlassContainer(tier: GlassTier.nav, child: Text('底栏')),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(liquidEdgePainterFinder(), findsNothing);
    expect(outerShadowPainterFinder(), findsNothing);

    final shape =
        (surfaceDecoration(tester).shape as RoundedSuperellipseBorder).side;
    expect(shape.style, BorderStyle.solid);
  });
}
