import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/core/storage/app_preferences_store.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    AppPreferencesController.instance.debugReset();
    AppThemeController.instance.debugReset();
  });

  group('AppPreferencesStore', () {
    test('空 SharedPreferences 应返回默认值', () async {
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.themeMode, AppThemePreference.system);
      expect(loaded.colorSource, AppColorPreference.preset);
      expect(loaded.paletteIndex, 0);
      expect(loaded.customSeedColor, AppThemeController.defaultCustomSeedColor);
      expect(loaded.pureBlack, false);
      expect(loaded.textScale, 0.9);
      expect(loaded.homeTextColor, HomeTextColorPreference.system);
    });

    test('saveThemeMode 应持久化', () async {
      await AppPreferencesStore.instance.saveThemeMode(AppThemePreference.dark);
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.themeMode, AppThemePreference.dark);
    });

    test('savePaletteIndex 应持久化', () async {
      await AppPreferencesStore.instance.savePaletteIndex(3);
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.paletteIndex, 3);
      expect(loaded.colorSource, AppColorPreference.preset);
    });

    test('saveCustomSeedColor 应持久化', () async {
      const customColor = Color(0xFF3366CC);
      await AppPreferencesStore.instance.saveCustomSeedColor(customColor);
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.colorSource, AppColorPreference.custom);
      expect(loaded.customSeedColor, customColor);
      expect(loaded.seedColor, customColor);
    });

    test('savePureBlack 应持久化', () async {
      await AppPreferencesStore.instance.savePureBlack(true);
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.pureBlack, true);
    });

    test('saveTextScale 应持久化', () async {
      await AppPreferencesStore.instance.saveTextScale(1.1);
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.textScale, 1.1);
    });

    test('saveHomeTextColor 应持久化', () async {
      await AppPreferencesStore.instance.saveHomeTextColor(
        HomeTextColorPreference.light,
      );
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.homeTextColor, HomeTextColorPreference.light);
    });
  });

  group('AppPreferencesController', () {
    test('初始状态应为默认值', () {
      final state = AppPreferencesController.instance.state;
      expect(state.themeMode, AppThemePreference.system);
      expect(state.paletteIndex, 0);
      expect(state.pureBlack, false);
      expect(state.textScale, 0.9);
    });

    test('restore 应从 SharedPreferences 恢复', () async {
      // Pre-populate SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_theme_mode', 'dark');
      await prefs.setString('app_theme_color_source', 'custom');
      await prefs.setInt('app_theme_custom_seed_color', 0xFF3366CC);
      await prefs.setInt('app_theme_preset_seed_index', 2);
      await prefs.setBool('app_theme_pure_black_mode', true);
      await prefs.setDouble('text_scale_factor', 1.05);

      await AppPreferencesController.instance.restore();
      final state = AppPreferencesController.instance.state;
      expect(state.themeMode, AppThemePreference.dark);
      expect(state.colorSource, AppColorPreference.custom);
      expect(state.customSeedColor, const Color(0xFF3366CC));
      expect(state.seedColor, const Color(0xFF3366CC));
      expect(state.paletteIndex, 2);
      expect(state.pureBlack, true);
      expect(state.textScale, 1.05);
    });

    test('setThemeMode 应更新 state', () async {
      await AppPreferencesController.instance.setThemeMode(
        AppThemePreference.dark,
      );
      expect(
        AppPreferencesController.instance.state.themeMode,
        AppThemePreference.dark,
      );
    });

    test('setPaletteIndex 应更新 state 和 seedColor', () async {
      await AppPreferencesController.instance.setPaletteIndex(3);
      expect(AppPreferencesController.instance.state.paletteIndex, 3);
      expect(
        AppPreferencesController.instance.state.seedColor,
        themePalettes[3].primary,
      );
      expect(
        AppPreferencesController.instance.state.colorSource,
        AppColorPreference.preset,
      );
    });

    test('setCustomSeedColor 应更新 state 和 seedColor', () async {
      const customColor = Color(0xFF3366CC);
      await AppPreferencesController.instance.setCustomSeedColor(customColor);
      expect(
        AppPreferencesController.instance.state.colorSource,
        AppColorPreference.custom,
      );
      expect(
        AppPreferencesController.instance.state.customSeedColor,
        customColor,
      );
      expect(AppPreferencesController.instance.state.seedColor, customColor);
    });

    test('setPureBlack 应更新 state', () async {
      await AppPreferencesController.instance.setPureBlack(true);
      expect(AppPreferencesController.instance.state.pureBlack, true);
    });

    test('setTextScale 应更新 state', () async {
      await AppPreferencesController.instance.setTextScale(1.1);
      expect(AppPreferencesController.instance.state.textScale, 1.1);
    });

    test('setHomeTextColor 应更新 state', () async {
      await AppPreferencesController.instance.setHomeTextColor(
        HomeTextColorPreference.dark,
      );
      expect(
        AppPreferencesController.instance.state.homeTextColor,
        HomeTextColorPreference.dark,
      );
    });

    test('setter 返回前应完成持久化', () async {
      await AppPreferencesController.instance.setThemeMode(
        AppThemePreference.dark,
      );
      await AppPreferencesController.instance.setPureBlack(true);
      await AppPreferencesController.instance.setTextScale(1.1);
      await AppPreferencesController.instance.setHomeTextColor(
        HomeTextColorPreference.light,
      );

      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.themeMode, AppThemePreference.dark);
      expect(loaded.pureBlack, true);
      expect(loaded.textScale, 1.1);
      expect(loaded.homeTextColor, HomeTextColorPreference.light);
    });

    test('materialThemeMode 应正确映射', () {
      expect(const AppPreferences().materialThemeMode, ThemeMode.system);
      expect(
        const AppPreferences(themeMode: AppThemePreference.light)
            .materialThemeMode,
        ThemeMode.light,
      );
      expect(
        const AppPreferences(themeMode: AppThemePreference.dark)
            .materialThemeMode,
        ThemeMode.dark,
      );
    });

    test('debugReset 应重置 state', () async {
      await AppPreferencesController.instance.setPureBlack(true);
      await AppPreferencesController.instance.setPaletteIndex(5);
      AppPreferencesController.instance.debugReset();
      final state = AppPreferencesController.instance.state;
      expect(state.pureBlack, false);
      expect(state.paletteIndex, 0);
      expect(state.colorSource, AppColorPreference.preset);
    });
  });
}
