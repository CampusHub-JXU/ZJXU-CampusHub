import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_preferences_controller.dart';

class AppPreferencesStore {
  AppPreferencesStore._();

  static final AppPreferencesStore instance = AppPreferencesStore._();

  static const _themeModeKey = 'app_theme_mode';
  static const _presetSeedIndexKey = 'app_theme_preset_seed_index';
  static const _pureBlackKey = 'app_theme_pure_black_mode';
  static const _textScaleKey = 'text_scale_factor';
  static const _homeTextColorModeKey = 'app_theme_home_text_color_mode';

  Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();

    // themeMode
    final themeModeName = prefs.getString(_themeModeKey);
    final themeMode = AppThemePreference.values.firstWhere(
      (e) => e.name == themeModeName,
      orElse: () => AppThemePreference.system,
    );

    // paletteIndex — map from existing presetSeedIndex
    final paletteIndex = (prefs.getInt(_presetSeedIndexKey) ?? 0).clamp(0, 6);

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
      paletteIndex: paletteIndex,
      pureBlack: pureBlack,
      textScale: textScale,
      homeTextColor: homeTextColor,
    );
  }

  Future<void> saveThemeMode(AppThemePreference value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, value.name);
  }

  Future<void> savePaletteIndex(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetSeedIndexKey, value);
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
