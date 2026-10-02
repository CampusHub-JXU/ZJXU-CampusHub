import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';

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

  // 颗粒噪点已移除：任何 CustomPaint 都不应出现在材质层里。
  Finder noisePainterFinder() => find.descendant(
    of: find.byType(BackdropFilter),
    matching: find.byType(CustomPaint),
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
}
