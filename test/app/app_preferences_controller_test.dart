import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_preferences_controller.dart';
import 'package:jxu_campus_hub/app/app_theme_controller.dart';
import 'package:jxu_campus_hub/app/text_scale_controller.dart';
import 'package:jxu_campus_hub/app/theme_mode_controller.dart';
import 'package:jxu_campus_hub/core/storage/app_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    AppPreferencesController.instance.debugReset();
    ThemeModeController.instance.debugReset();
    AppThemeController.instance.debugReset();
    TextScaleController.instance.debugReset();
  });

  group('AppPreferencesStore', () {
    test('空 SharedPreferences 应返回默认值', () async {
      final loaded = await AppPreferencesStore.instance.load();
      expect(loaded.themeMode, AppThemePreference.system);
      expect(loaded.paletteIndex, 0);
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
      await prefs.setInt('app_theme_preset_seed_index', 2);
      await prefs.setBool('app_theme_pure_black_mode', true);
      await prefs.setDouble('text_scale_factor', 1.05);

      await AppPreferencesController.instance.restore();
      final state = AppPreferencesController.instance.state;
      expect(state.themeMode, AppThemePreference.dark);
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
        AppThemeController.presetSeedColors[3],
      );
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

    test('materialThemeMode 应正确映射', () {
      expect(const AppPreferences().materialThemeMode, ThemeMode.system);
      expect(
        const AppPreferences(
          themeMode: AppThemePreference.light,
        ).materialThemeMode,
        ThemeMode.light,
      );
      expect(
        const AppPreferences(
          themeMode: AppThemePreference.dark,
        ).materialThemeMode,
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
    });
  });
}
