import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_preferences_controller.dart';
import '../theme/app_theme_controller.dart';
import '../theme/app_theme_palette.dart';

class AppPreferencesStore {
  AppPreferencesStore._();

  static final AppPreferencesStore instance = AppPreferencesStore._();

  static const _themeModeKey = 'app_theme_mode';
  static const _colorSourceKey = 'app_theme_color_source';
  static const _presetSeedIndexKey = 'app_theme_preset_seed_index';
  static const _customSeedColorKey = 'app_theme_custom_seed_color';
  static const _pureBlackKey = 'app_theme_pure_black_mode';
  static const _textScaleKey = 'text_scale_factor';
  static const _homeTextColorModeKey = 'app_theme_home_text_color_mode';
  static const _filledButtonSoftStyleKey = 'app_theme_filled_button_soft_style';

  Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();

    // themeMode
    final themeModeName = prefs.getString(_themeModeKey);
    final themeMode = AppThemePreference.values.firstWhere(
      (e) => e.name == themeModeName,
      orElse: () => AppThemePreference.system,
    );

    // paletteIndex — map from existing presetSeedIndex
    final paletteIndex = (prefs.getInt(_presetSeedIndexKey) ?? 0).clamp(
      0,
      themePalettes.length - 1,
    );

    // colorSource
    final colorSourceName = prefs.getString(_colorSourceKey);
    final colorSource = AppColorPreference.values.firstWhere(
      (e) => e.name == colorSourceName,
      orElse: () => AppColorPreference.preset,
    );

    // customSeedColor
    final customSeedColor = Color(
      prefs.getInt(_customSeedColorKey) ??
          AppThemeController.defaultCustomSeedColor.toARGB32(),
    ).withValues(alpha: 1);

    // pureBlack
    final pureBlack = prefs.getBool(_pureBlackKey) ?? false;

    // textScale
    final textScale = prefs.getDouble(_textScaleKey) ?? 0.9;

    // homeTextColorMode
    final homeTextIndex = prefs.getInt(_homeTextColorModeKey) ?? 0;
    final homeTextColor = HomeTextColorPreference.values.firstWhere(
      (e) => e.index == homeTextIndex,
      orElse: () => HomeTextColorPreference.system,
    );

    // filledButtonSoftStyle
    final filledButtonSoftStyle =
        prefs.getBool(_filledButtonSoftStyleKey) ?? false;

    return AppPreferences(
      themeMode: themeMode,
      colorSource: colorSource,
      paletteIndex: paletteIndex,
      customSeedColor: customSeedColor,
      pureBlack: pureBlack,
      textScale: textScale,
      homeTextColor: homeTextColor,
      filledButtonSoftStyle: filledButtonSoftStyle,
    );
  }

  Future<void> saveThemeMode(AppThemePreference value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, value.name);
  }

  Future<void> savePaletteIndex(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorSourceKey, AppColorPreference.preset.name);
    await prefs.setInt(_presetSeedIndexKey, value);
  }

  Future<void> saveCustomSeedColor(Color value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorSourceKey, AppColorPreference.custom.name);
    await prefs.setInt(
      _customSeedColorKey,
      value.withValues(alpha: 1).toARGB32(),
    );
  }

  Future<void> savePureBlack(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pureBlackKey, value);
  }

  Future<void> saveTextScale(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_textScaleKey, value);
  }

  Future<void> saveHomeTextColor(HomeTextColorPreference value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_homeTextColorModeKey, value.index);
  }

  Future<void> saveFilledButtonSoftStyle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_filledButtonSoftStyleKey, value);
  }
}
