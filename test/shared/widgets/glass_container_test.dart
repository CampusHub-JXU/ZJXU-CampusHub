import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';
import 'package:jxu_campus_hub/shared/widgets/material_noise.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  Future<void> pumpSurface(WidgetTester tester, Widget surface) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: surface)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder noisePainterFinder() => find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is MaterialNoisePainter,
  );

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

  testWidgets('玻璃总开关关闭后降级实色且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('模糊强度拉到 0 时不创建 BackdropFilter（滑条 0 = 关模糊）', (tester) async {
    await GlassStyleController.instance.setBlurSigma(0);
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('亚克力材质保留有界实时模糊、半透明填充与细微噪点', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.acrylic,
    );
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    final backdrop = find.byType(BackdropFilter);
    expect(backdrop, findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(backdrop).filterConfig.toString(),
      contains('bounded'),
    );
    expect(noisePainterFinder(), findsOneWidget);

    final shape = surfaceDecoration(tester);
    expect(shape.color!.a, lessThan(1.0));
  });

  testWidgets('云母材质为不透明主题色调稳定表面：无模糊、无噪点', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.mica,
    );
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(noisePainterFinder(), findsNothing);

    // 不透明：填充色 alpha 必须为 1，否则未模糊的背景会透出。
    final shape = surfaceDecoration(tester);
    expect(shape.color!.a, 1.0);

    // 主题色调：不透明填充必须与中性 surface 容器色可区分。
    final theme = Theme.of(tester.element(find.byType(GlassContainer)));
    final baseSurface = theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerLow
        : theme.colorScheme.surfaceContainerLowest;
    expect(shape.color, isNot(equals(baseSurface)));
  });

  testWidgets('实色材质降级为不透明表面且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.solid,
    );
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('AppMaterialSurface 支持通过 surfaceType 显式指定材质', (tester) async {
    await pumpSurface(
      tester,
      const AppMaterialSurface(
        surfaceType: MaterialSurfaceType.mica,
        child: Text('显式云母'),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);

    await pumpSurface(
      tester,
      const AppMaterialSurface(
        surfaceType: MaterialSurfaceType.acrylic,
        child: Text('显式亚克力'),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
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
}
