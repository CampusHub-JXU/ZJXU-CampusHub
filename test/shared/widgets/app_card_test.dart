import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_design_tokens.dart';
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

  testWidgets('渲染实色卡片且不创建玻璃层', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final element = tester.element(find.text('卡片'));
    final cs = Theme.of(element).colorScheme;

    final surface = surfaceOf(tester);
    expect(surface.color, cs.surfaceContainerLowest);
    expect(surface.gradient, isNull);
    // 视觉做减法：卡面无描边，仅剩平色填充。
    final shape = surface.shape as RoundedSuperellipseBorder;
    expect(shape.side, BorderSide.none);
    expect(shape.borderRadius, AppRadius.cardBorder);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('浅色卡面零投影（分层靠色调对比）', (tester) async {
    await pumpApp(tester, const AppCard(child: Text('卡片')));

    final decorBox = tester.widget<DecoratedBox>(
      find
          .ancestor(of: find.text('卡片'), matching: find.byType(DecoratedBox))
          .last,
    );
    final boxDecoration = decorBox.decoration as BoxDecoration;
    expect(boxDecoration.borderRadius, AppRadius.cardBorder);
    expect(boxDecoration.boxShadow, appSurfaceShadows(isDark: false));
    expect(boxDecoration.boxShadow, isEmpty);
  });

  testWidgets('onTap 回调保持可用', (tester) async {
    var tapped = 0;
    await pumpApp(
      tester,
      AppCard(onTap: () => tapped++, child: const Text('卡片')),
    );

    await tester.tap(find.text('卡片'));
    expect(tapped, 1);
  });
}
