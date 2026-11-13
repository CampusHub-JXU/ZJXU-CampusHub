import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/features/settings/appearance_page.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('合并页展示外观与个性化全部分组且无顶部预览框', (tester) async {
    await pumpPage(tester, const AppearancePage());

    expect(find.text('外观与个性化'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('按住预览'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('应用图标'),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('personalization_scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('应用图标'), findsOneWidget);
  });

  testWidgets('右上角按住预览展示真实首页实体，松开后返回', (tester) async {
    // 预览叠加层在 Shader 开启时会渲染持续帧；这里先关闭 Shader 以便松开后校验稳定状态。
    await PersonalizationController.instance.setShaderEnabled(false);

    await pumpPage(
      tester,
      AppearancePage(
        homeSceneBuilder: (context) => const Center(child: Text('真实首页场景')),
      ),
    );

    expect(find.text('真实首页场景'), findsNothing);

    final previewButton = find.byKey(const Key('appearance_hold_preview'));
    final gesture = await tester.startGesture(tester.getCenter(previewButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    expect(find.text('真实首页场景'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('真实首页场景'), findsNothing);
  });

  testWidgets('自定义主题色弹层保存后应切换到 custom 色源', (tester) async {
    await pumpPage(tester, const AppearancePage());

    await tester.ensureVisible(
      find.byKey(const ValueKey('custom-theme-color-button')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('custom-theme-color-button')));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);

    final colorPlane = find.byKey(const ValueKey('hsv-color-plane'));
    await tester.tapAt(tester.getTopLeft(colorPlane) + const Offset(220, 24));
    await tester.pump();

    // 弹层内容在 800×600 测试窗口里比可视区略高（可滚动），先滚到保存按钮。
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final state = AppPreferencesController.instance.state;
    expect(state.colorSource, AppColorPreference.custom);
    expect(
      state.customSeedColor,
      isNot(AppThemeController.defaultCustomSeedColor),
    );
    expect(state.seedColor, state.customSeedColor);
  });
}
