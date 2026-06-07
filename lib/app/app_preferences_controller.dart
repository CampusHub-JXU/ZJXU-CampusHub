import 'package:flutter/material.dart';

import 'app_theme_controller.dart';
import 'text_scale_controller.dart';
import 'theme_mode_controller.dart';
import '../core/storage/app_preferences_store.dart';

enum AppThemePreference { system, light, dark }

enum HomeTextColorPreference { system, dark, light }

class AppPreferences {
  final AppThemePreference themeMode;
  final int paletteIndex;
  final bool pureBlack;
  final double textScale;
  final HomeTextColorPreference homeTextColor;

  const AppPreferences({
    this.themeMode = AppThemePreference.system,
    this.paletteIndex = 0,
    this.pureBlack = false,
    this.textScale = 0.9,
    this.homeTextColor = HomeTextColorPreference.system,
  });

  AppPreferences copyWith({
    AppThemePreference? themeMode,
    int? paletteIndex,
    bool? pureBlack,
    double? textScale,
    HomeTextColorPreference? homeTextColor,
  }) {
    return AppPreferences(
      themeMode: themeMode ?? this.themeMode,
      paletteIndex: paletteIndex ?? this.paletteIndex,
      pureBlack: pureBlack ?? this.pureBlack,
      textScale: textScale ?? this.textScale,
      homeTextColor: homeTextColor ?? this.homeTextColor,
    );
  }

  ThemeMode get materialThemeMode => switch (themeMode) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  Color get seedColor => AppThemeController.presetSeedColors[paletteIndex];
}

class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController._();

  static final AppPreferencesController instance = AppPreferencesController._();

  AppPreferences _state = const AppPreferences();
  AppPreferences get state => _state;

  /// Restore preferences from SharedPreferences.
  /// Call during bootstrap warming phase.
  Future<void> restore() async {
    _state = await AppPreferencesStore.instance.load();

    // Sync state to legacy singletons for backward compat
    _syncToLegacySingletons();

    notifyListeners();
  }

  // ── Theme Mode ─────────────────────────────────────────────────────────

  Future<void> setThemeMode(AppThemePreference value) async {
    if (_state.themeMode == value) return;
    _state = _state.copyWith(themeMode: value);
    notifyListeners();

    // Delegate to legacy singleton
    ThemeModeController.instance.setThemeMode(value.materialThemeMode);
    // Persist
    AppPreferencesStore.instance.saveThemeMode(value);
  }

  // ── Palette ────────────────────────────────────────────────────────────

  Future<void> setPaletteIndex(int value) async {
    final safe = value.clamp(0, AppThemeController.presetSeedColors.length - 1);
    if (_state.paletteIndex == safe) return;
    _state = _state.copyWith(paletteIndex: safe);
    notifyListeners();

    // Delegate to legacy singletons
    AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
    AppThemeController.instance.setPresetSeedIndex(safe);
    // Persist
    AppPreferencesStore.instance.savePaletteIndex(safe);
  }

  // ── Pure Black ─────────────────────────────────────────────────────────

  Future<void> setPureBlack(bool value) async {
    if (_state.pureBlack == value) return;
    _state = _state.copyWith(pureBlack: value);
    notifyListeners();

    AppThemeController.instance.setPureBlackMode(value);
    AppPreferencesStore.instance.savePureBlack(value);
  }

  // ── Text Scale ─────────────────────────────────────────────────────────

  Future<void> setTextScale(double value) async {
    final normalized = TextScaleController.normalizeScaleFactor(value);
    if (_state.textScale == normalized) return;
    _state = _state.copyWith(textScale: normalized);
    notifyListeners();

    TextScaleController.instance.setTextScaleFactor(normalized);
    AppPreferencesStore.instance.saveTextScale(normalized);
  }

  // ── Home Text Color ────────────────────────────────────────────────────

  Future<void> setHomeTextColor(HomeTextColorPreference value) async {
    if (_state.homeTextColor == value) return;
    _state = _state.copyWith(homeTextColor: value);
    notifyListeners();

    // Map to legacy enum
    final legacyMode = switch (value) {
      HomeTextColorPreference.system => HomeTextColorMode.system,
      HomeTextColorPreference.dark => HomeTextColorMode.dark,
      HomeTextColorPreference.light => HomeTextColorMode.light,
    };
    AppThemeController.instance.setHomeTextColorMode(legacyMode);
    AppPreferencesStore.instance.saveHomeTextColor(value);
  }

  // ── Legacy sync ────────────────────────────────────────────────────────

  /// Sync restored preferences to legacy singletons so existing
  /// ValueListenableBuilder widgets stay in sync.
  void _syncToLegacySingletons() {
    // Use public setters (fire-and-forget during bootstrap)
    ThemeModeController.instance.setThemeMode(_state.materialThemeMode);
    TextScaleController.instance.setTextScaleFactor(_state.textScale);
    AppThemeController.instance.setPureBlackMode(_state.pureBlack);
    AppThemeController.instance.setPresetSeedIndex(_state.paletteIndex);
    final legacyHomeTextColor = switch (_state.homeTextColor) {
      HomeTextColorPreference.system => HomeTextColorMode.system,
      HomeTextColorPreference.dark => HomeTextColorMode.dark,
      HomeTextColorPreference.light => HomeTextColorMode.light,
    };
    AppThemeController.instance.setHomeTextColorMode(legacyHomeTextColor);
  }

  @visibleForTesting
  void debugReset() {
    _state = const AppPreferences();
    notifyListeners();
  }
}

extension on AppThemePreference {
  ThemeMode get materialThemeMode => switch (this) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };
}
