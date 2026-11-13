import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_preferences_controller.dart';
import '../theme/app_icon_style.dart';
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
  static const _appIconStyleKey = 'app_icon_style';

  /// 已退役的图标偏好键（深浅自动翻转那套已并入资源限定符）。
  static const _retiredIconKeys = [
    'app_icon_follow_theme_color',
    'app_icon_dark_invert',
  ];

  Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _retiredIconKeys) {
      await prefs.remove(key);
    }

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

    return AppPreferences(
      themeMode: themeMode,
      colorSource: colorSource,
      paletteIndex: paletteIndex,
      customSeedColor: customSeedColor,
      pureBlack: pureBlack,
      textScale: textScale,
      homeTextColor: homeTextColor,
      appIconStyle: AppIconStyle.values.firstWhere(
        (style) => style.name == prefs.getString(_appIconStyleKey),
        orElse: () => AppIconStyle.celadonSlate,
      ),
    );
  }

  Future<void> saveThemeMode(AppThemePreference value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, value.name);
  }

  Future<void> saveAppIconPreferences(AppPreferences value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appIconStyleKey, value.appIconStyle.name);
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
}
