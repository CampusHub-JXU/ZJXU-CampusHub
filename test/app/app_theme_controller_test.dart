import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jxu_campus_hub/app/app_theme_controller.dart';
import 'package:jxu_campus_hub/app/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    AppThemeController.instance.debugReset();
  });

  group('AppThemeController', () {
    test('初始状态应为 brandRed', () {
      expect(
        AppThemeController.instance.seedMode.value,
        AppThemeSeedMode.brandRed,
      );
      expect(AppThemeController.instance.seedColor.value, AppColors.primary);
    });

    test('setSeedMode 应正确更新 seedMode', () async {
      await AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
      expect(
        AppThemeController.instance.seedMode.value,
        AppThemeSeedMode.preset,
      );
    });

    test('setPresetSeedIndex 应正确更新 presetSeedIndex', () async {
      await AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
      await AppThemeController.instance.setPresetSeedIndex(2);
      expect(AppThemeController.instance.presetSeedIndex.value, 2);
      expect(
        AppThemeController.instance.seedColor.value,
        AppThemeController.presetSeedColors[2],
      );
    });

    test('setCustomSeedColor 应切换到自定义主题色', () async {
      const customColor = Color(0xFF3366CC);
      await AppThemeController.instance.setCustomSeedColor(customColor);
      expect(
        AppThemeController.instance.seedMode.value,
        AppThemeSeedMode.custom,
      );
      expect(AppThemeController.instance.customSeedColor.value, customColor);
      expect(AppThemeController.instance.seedColor.value, customColor);
    });

    test('init 应恢复自定义主题色', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('app_theme_seed_mode', AppThemeSeedMode.custom.index);
      await prefs.setInt('app_theme_custom_seed_color', 0xFF3366CC);

      await AppThemeController.instance.init();
      expect(
        AppThemeController.instance.seedMode.value,
        AppThemeSeedMode.custom,
      );
      expect(
        AppThemeController.instance.seedColor.value,
        const Color(0xFF3366CC),
      );
    });

    test('setPureBlackMode 应正确更新 pureBlackMode', () async {
      await AppThemeController.instance.setPureBlackMode(true);
      expect(AppThemeController.instance.pureBlackMode.value, true);
    });

    test('setPureBlackMode 应持久化到 SharedPreferences', () async {
      await AppThemeController.instance.setPureBlackMode(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('app_theme_pure_black_mode'), true);
    });

    test('debugReset 应重置 pureBlackMode', () async {
      await AppThemeController.instance.setPureBlackMode(true);
      AppThemeController.instance.debugReset();
      expect(AppThemeController.instance.pureBlackMode.value, false);
    });

    test('setHomeTextColorMode 应正确更新 homeTextColorMode', () async {
      await AppThemeController.instance.setHomeTextColorMode(
        HomeTextColorMode.dark,
      );
      expect(
        AppThemeController.instance.homeTextColorMode.value,
        HomeTextColorMode.dark,
      );
    });

    test('presetSeedColors 应包含 8 种颜色', () {
      expect(AppThemeController.presetSeedColors.length, 8);
    });

    test('presetSeedLabels 应包含 8 个标签', () {
      expect(AppThemeController.presetSeedLabels.length, 8);
      expect(AppThemeController.presetSeedLabels[0], '嘉大红');
      expect(AppThemeController.presetSeedLabels[7], '石墨');
    });

    test('石墨暗色主题应保持中性灰阶', () {
      final theme = AppTheme.darkThemeFor(
        AppThemeController.presetSeedColors[7],
      );

      expect(theme.colorScheme.primary, const Color(0xFF455A64));
      expect(theme.colorScheme.surface, const Color(0xFF171C20));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF101418));
    });
  });
}
