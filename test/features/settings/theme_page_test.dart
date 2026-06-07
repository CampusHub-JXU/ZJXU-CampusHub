import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_theme_controller.dart';
import 'package:jxu_campus_hub/app/text_scale_controller.dart';
import 'package:jxu_campus_hub/app/theme_mode_controller.dart';
import 'package:jxu_campus_hub/features/settings/theme_page.dart';

import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    ThemeModeController.instance.debugReset();
    AppThemeController.instance.debugReset();
    TextScaleController.instance.debugReset();
  });

  group('ThemePage', () {
    testWidgets('显示模式按钮', (tester) async {
      await pumpPage(tester, const ThemePage());
      expect(find.text('自动'), findsOneWidget);
      expect(find.text('浅色'), findsOneWidget);
      expect(find.text('深色'), findsOneWidget);
    });

    testWidgets('点击浅色应更新 ThemeModeController', (tester) async {
      await pumpPage(tester, const ThemePage());
      await tester.tap(find.text('浅色'));
      await tester.pump();
      expect(ThemeModeController.instance.themeMode.value, ThemeMode.light);
    });

    testWidgets('点击深色应更新 ThemeModeController', (tester) async {
      await pumpPage(tester, const ThemePage());
      await tester.tap(find.text('深色'));
      await tester.pump();
      expect(ThemeModeController.instance.themeMode.value, ThemeMode.dark);
    });

    testWidgets('点击自动应更新 ThemeModeController', (tester) async {
      ThemeModeController.instance.setThemeMode(ThemeMode.light);
      await pumpPage(tester, const ThemePage());
      await tester.tap(find.text('自动'));
      await tester.pump();
      expect(ThemeModeController.instance.themeMode.value, ThemeMode.system);
    });

    testWidgets('点击第 2 个色板应更新 presetSeedIndex', (tester) async {
      await pumpPage(tester, const ThemePage());
      // 色板通过 ClipOval 包裹的 GridView 实现
      final clipOvals = find.byType(ClipOval);
      expect(clipOvals.evaluate().length, greaterThanOrEqualTo(7));
      // 点击第 2 个色板（它的父级是 SizedBox -> Center -> AnimatedContainer -> GestureDetector）
      final secondSwatch = clipOvals.at(1);
      await tester.tap(secondSwatch);
      await tester.pump();
      expect(AppThemeController.instance.presetSeedIndex.value, 1);
      expect(
        AppThemeController.instance.seedMode.value,
        AppThemeSeedMode.preset,
      );
    });

    testWidgets('纯黑模式开关应切换 pureBlackMode', (tester) async {
      await pumpPage(tester, const ThemePage());
      expect(AppThemeController.instance.pureBlackMode.value, false);
      // 滚动到纯黑模式开关
      await tester.scrollUntilVisible(
        find.text('纯黑模式'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('纯黑模式'));
      await tester.pump();
      expect(AppThemeController.instance.pureBlackMode.value, true);
    });

    testWidgets('文本缩放开关应展开 slider', (tester) async {
      await pumpPage(tester, const ThemePage());
      expect(find.byType(Slider), findsNothing);
      await tester.scrollUntilVisible(
        find.text('文本缩放'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('文本缩放'));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('恢复默认按钮应重置文本缩放', (tester) async {
      await pumpPage(tester, const ThemePage());
      await tester.scrollUntilVisible(
        find.text('文本缩放'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('文本缩放'));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);
      await tester.tap(find.text('恢复默认'));
      await tester.pump();
      expect(
        TextScaleController.instance.textScaleFactor.value,
        TextScaleController.defaultScaleFactor,
      );
    });
  });
}
