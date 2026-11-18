import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/features/settings/theme_material_page.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('主题与材质页展示主题分组，不含首页个性化分组', (tester) async {
    await pumpPage(tester, const ThemeMaterialPage());

    expect(find.text('主题与材质'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('主题色彩'), findsOneWidget);

    // 「首页卡片文字」选择器已下线。
    expect(find.text('首页卡片文字'), findsNothing);
    expect(find.text('纯黑模式'), findsOneWidget);
    expect(find.text('文本缩放'), findsOneWidget);

    // 拆分后个性化分组不在此页。
    expect(find.text('壁纸'), findsNothing);
    expect(find.text('效果'), findsNothing);
    expect(find.text('应用图标'), findsNothing);
  });

  testWidgets('自定义主题色弹层保存后应切换到 custom 色源', (tester) async {
    await pumpPage(tester, const ThemeMaterialPage());

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('custom-theme-color-button')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('theme_material_scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
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
