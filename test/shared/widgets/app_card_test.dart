import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  /// AppCard 的内容容器（卡片文案的唯一 Container 祖先）。
  Container contentContainer(WidgetTester tester) {
    return tester.widget<Container>(
      find
          .ancestor(of: find.text('卡片'), matching: find.byType(Container))
          .first,
    );
  }

  testWidgets('默认渲染实色卡片且不创建玻璃层', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final decoration = contentContainer(tester).decoration! as BoxDecoration;

    expect(
      decoration.color,
      Theme.of(element).colorScheme.surfaceContainerLowest,
    );
    expect(decoration.borderRadius, BorderRadius.circular(22));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('玻璃卡片监听全局材质参数且默认不加模糊', (tester) async {
    await pumpApp(tester, const AppCard(glassEnabled: true, child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final cs = Theme.of(element).colorScheme;

    ShapeDecoration decorationOf() =>
        contentContainer(tester).decoration! as ShapeDecoration;

    // 初始 tint 使用 GlassStyleController.tintOpacity（debugReset 后为 0.84）。
    expect(
      decorationOf().gradient,
      LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            Colors.white.withValues(alpha: 0.34),
            cs.surfaceContainerLowest.withValues(
              alpha: GlassStyleController.instance.tintOpacity.value,
            ),
          ),
          Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            cs.surfaceContainerLowest.withValues(
              alpha: GlassStyleController.instance.tintOpacity.value,
            ),
          ),
        ],
      ),
    );
    // 玻璃卡片使用 squircle + 高光描边。
    final shape = decorationOf().shape as RoundedSuperellipseBorder;
    expect(shape.borderRadius, BorderRadius.circular(22));
    expect(shape.side.color, cs.outlineVariant.withValues(alpha: 0.55));
    // 卡片级玻璃默认 blurred=false，不产生 BackdropFilter。
    expect(find.byType(BackdropFilter), findsNothing);

    // 调整全局 tint 参数后卡片重建并应用新值。
    await GlassStyleController.instance.setTintOpacity(0.5);
    await tester.pump();

    final gradient = decorationOf().gradient as LinearGradient;
    expect(
      gradient.colors.first,
      Color.alphaBlend(
        Colors.white.withValues(alpha: 0.34),
        cs.surfaceContainerLowest.withValues(alpha: 0.5),
      ),
    );
  });

  testWidgets('全局玻璃开关关闭后降级实色且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpApp(tester, const AppCard(glassEnabled: true, child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final decoration = contentContainer(tester).decoration! as BoxDecoration;

    expect(
      decoration.color,
      Theme.of(element).colorScheme.surfaceContainerLowest,
    );
    expect(find.byType(BackdropFilter), findsNothing);
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
