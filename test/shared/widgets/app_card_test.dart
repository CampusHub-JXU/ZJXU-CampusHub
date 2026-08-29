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

  /// fill 层（内缩 1px 的内容 Container，卡片文案的直接祖先）。
  Container fillContainer(WidgetTester tester) {
    return tester.widget<Container>(
      find
          .ancestor(of: find.text('卡片'), matching: find.byType(Container))
          .first,
    );
  }

  /// ring 层（fill 的直接 Container 祖先，整幅渐变描边环）。
  Container ringContainer(WidgetTester tester) {
    return tester.widget<Container>(
      find
          .ancestor(of: find.text('卡片'), matching: find.byType(Container))
          .at(1),
    );
  }

  testWidgets('默认渲染实色卡片且不创建玻璃层', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final cs = Theme.of(element).colorScheme;

    final fill =
        fillContainer(tester).decoration! as ShapeDecoration;
    expect(fill.color, cs.surfaceContainerLowest);
    expect(
      (fill.shape as RoundedSuperellipseBorder).borderRadius,
      BorderRadius.circular(21),
    );

    final ring = ringContainer(tester).decoration! as ShapeDecoration;
    expect(
      (ring.shape as RoundedSuperellipseBorder).borderRadius,
      BorderRadius.circular(22),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('玻璃卡片监听全局材质参数且默认不加模糊', (tester) async {
    await pumpApp(tester, const AppCard(glassEnabled: true, child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final cs = Theme.of(element).colorScheme;

    ShapeDecoration fillOf() =>
        fillContainer(tester).decoration! as ShapeDecoration;

    // 初始 tint 使用 GlassStyleController.tintOpacity（debugReset 后为 0.84），
    // 叠加受光高光渐变（sheen 0.32 → 0.06）。
    expect(
      fillOf().gradient,
      LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            Colors.white.withValues(alpha: 0.32),
            cs.surfaceContainerLowest.withValues(
              alpha: GlassStyleController.instance.tintOpacity.value,
            ),
          ),
          Color.alphaBlend(
            Colors.white.withValues(alpha: 0.06),
            cs.surfaceContainerLowest.withValues(
              alpha: GlassStyleController.instance.tintOpacity.value,
            ),
          ),
        ],
      ),
    );
    // ring 层为定向受光描边环（无 BorderSide，露出的一圈即描边）。
    final ring = ringContainer(tester).decoration! as ShapeDecoration;
    expect(
      (ring.shape as RoundedSuperellipseBorder).borderRadius,
      BorderRadius.circular(22),
    );
    expect(ring.color, isNull);
    // 卡片级玻璃永不产生 BackdropFilter。
    expect(find.byType(BackdropFilter), findsNothing);

    // 调整全局 tint 参数后卡片重建并应用新值。
    await GlassStyleController.instance.setTintOpacity(0.5);
    await tester.pump();

    final gradient = fillOf().gradient as LinearGradient;
    expect(
      gradient.colors.first,
      Color.alphaBlend(
        Colors.white.withValues(alpha: 0.32),
        cs.surfaceContainerLowest.withValues(alpha: 0.5),
      ),
    );
  });

  testWidgets('全局玻璃开关关闭后降级实色且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpApp(tester, const AppCard(glassEnabled: true, child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final fill =
        fillContainer(tester).decoration! as ShapeDecoration;

    expect(fill.color, Theme.of(element).colorScheme.surfaceContainerLowest);
    expect(fill.gradient, isNull);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('标准卡面使用配方双层投影', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final decorBox = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.text('卡片'),
            matching: find.byType(DecoratedBox),
          )
          .last,
    );
    final boxDecoration = decorBox.decoration as BoxDecoration;
    expect(boxDecoration.borderRadius, BorderRadius.circular(22));
    expect(boxDecoration.boxShadow, appSurfaceShadows(isDark: false));
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
