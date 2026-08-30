import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';
import 'package:jxu_campus_hub/shared/widgets/app_surface_style.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  /// 卡面 Container（卡片文案的直接祖先，单层平色装饰）。
  ShapeDecoration surfaceOf(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .ancestor(of: find.text('卡片'), matching: find.byType(Container))
          .first,
    );
    return container.decoration! as ShapeDecoration;
  }

  testWidgets('默认渲染实色卡片且不创建玻璃层', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final cs = Theme.of(element).colorScheme;

    final surface = surfaceOf(tester);
    expect(surface.color, cs.surfaceContainerLowest);
    expect(surface.gradient, isNull);
    // 均匀 hairline 描边（浅色：outlineVariant 0.55，1px）。
    final side = (surface.shape as RoundedSuperellipseBorder).side;
    expect(side.color, cs.outlineVariant.withValues(alpha: 0.55));
    expect(side.width, 1.0);
    expect(
      (surface.shape as RoundedSuperellipseBorder).borderRadius,
      BorderRadius.circular(22),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('玻璃卡片监听全局材质参数且默认不加模糊', (tester) async {
    await pumpApp(tester, const AppCard(glassEnabled: true, child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final cs = Theme.of(element).colorScheme;

    // 平色半透明 tint（无 sheen 渐变），透明度来自 GlassStyleController
    // （debugReset 后为 0.84）。
    expect(
      surfaceOf(tester).color,
      cs.surfaceContainerLowest.withValues(
        alpha: GlassStyleController.instance.tintOpacity.value,
      ),
    );
    expect(surfaceOf(tester).gradient, isNull);
    // 玻璃开启时描边提亮一档（outlineVariant 0.70）。
    final side = (surfaceOf(tester).shape as RoundedSuperellipseBorder).side;
    expect(side.color, cs.outlineVariant.withValues(alpha: 0.70));
    // 卡片级玻璃永不产生 BackdropFilter。
    expect(find.byType(BackdropFilter), findsNothing);

    // 调整全局 tint 参数后卡片重建并应用新值。
    await GlassStyleController.instance.setTintOpacity(0.5);
    await tester.pump();

    expect(
      surfaceOf(tester).color,
      cs.surfaceContainerLowest.withValues(alpha: 0.5),
    );
  });

  testWidgets('全局玻璃开关关闭后降级实色且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpApp(tester, const AppCard(glassEnabled: true, child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final surface = surfaceOf(tester);

    expect(surface.color, Theme.of(element).colorScheme.surfaceContainerLowest);
    expect(surface.gradient, isNull);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('浅色卡面零投影（分层靠色调对比 + hairline）', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final decorBox = tester.widget<DecoratedBox>(
      find
          .ancestor(of: find.text('卡片'), matching: find.byType(DecoratedBox))
          .last,
    );
    final boxDecoration = decorBox.decoration as BoxDecoration;
    expect(boxDecoration.borderRadius, BorderRadius.circular(22));
    expect(boxDecoration.boxShadow, appSurfaceShadows(isDark: false));
    expect(boxDecoration.boxShadow, isEmpty);
  });

  testWidgets('onTap 回调保持可用', (tester) async {
    var tapped = 0;
    await pumpApp(
      tester,
      AppCard(
        glassEnabled: true,
        onTap: () => tapped++,
        child: const Text('卡片'),
      ),
    );

    await tester.tap(find.text('卡片'));
    expect(tapped, 1);
  });
}
