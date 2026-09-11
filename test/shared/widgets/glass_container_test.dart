import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/surface_material.dart';
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

  testWidgets('亚克力材质保留真实模糊', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.acrylic,
    );
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('实色材质降级为不透明表面且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.solid,
    );
    await pumpSurface(tester, const GlassContainer(child: Text('卡片')));

    expect(find.byType(BackdropFilter), findsNothing);
  });
}
