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
      expect(AppThemeController.instance.seedMode.value, AppThemeSeedMode.brandRed);
      expect(AppThemeController.instance.seedColor.value, AppColors.primary);
    });

    test('setSeedMode 应正确更新 seedMode', () async {
      await AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
      expect(AppThemeController.instance.seedMode.value, AppThemeSeedMode.preset);
    });

    test('setPresetSeedIndex 应正确更新 presetSeedIndex', () async {
      await AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
      await AppThemeController.instance.setPresetSeedIndex(2);
      expect(AppThemeController.instance.presetSeedIndex.value, 2);
      expect(AppThemeController.instance.seedColor.value, AppThemeController.presetSeedColors[2]);
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
      await AppThemeController.instance.setHomeTextColorMode(HomeTextColorMode.dark);
      expect(AppThemeController.instance.homeTextColorMode.value, HomeTextColorMode.dark);
    });

    test('presetSeedColors 应包含 7 种颜色', () {
      expect(AppThemeController.presetSeedColors.length, 7);
    });

    test('presetSeedLabels 应包含 7 个标签', () {
      expect(AppThemeController.presetSeedLabels.length, 7);
      expect(AppThemeController.presetSeedLabels[0], '嘉大蓝');
      expect(AppThemeController.presetSeedLabels[6], '石墨');
    });
  });
}
