import 'package:flutter/material.dart';

import 'app_theme_controller.dart';
import 'text_scale_controller.dart';
import 'theme_mode_controller.dart';
import '../core/storage/app_preferences_store.dart';

enum AppThemePreference { system, light, dark }

enum AppColorPreference { preset, custom }

enum HomeTextColorPreference { system, dark, light }

class AppPreferences {
  final AppThemePreference themeMode;
  final AppColorPreference colorSource;
  final int paletteIndex;
  final Color customSeedColor;
  final bool pureBlack;
  final double textScale;
  final HomeTextColorPreference homeTextColor;

  const AppPreferences({
    this.themeMode = AppThemePreference.system,
    this.colorSource = AppColorPreference.preset,
    this.paletteIndex = 0,
    this.customSeedColor = AppThemeController.defaultCustomSeedColor,
    this.pureBlack = false,
    this.textScale = 0.9,
    this.homeTextColor = HomeTextColorPreference.system,
  });

  AppPreferences copyWith({
    AppThemePreference? themeMode,
    AppColorPreference? colorSource,
    int? paletteIndex,
    Color? customSeedColor,
    bool? pureBlack,
    double? textScale,
    HomeTextColorPreference? homeTextColor,
  }) {
    return AppPreferences(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      paletteIndex: paletteIndex ?? this.paletteIndex,
      customSeedColor: customSeedColor ?? this.customSeedColor,
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

  Color get seedColor => switch (colorSource) {
    AppColorPreference.preset =>
      AppThemeController.presetSeedColors[paletteIndex
          .clamp(0, AppThemeController.presetSeedColors.length - 1)
          .toInt()],
    AppColorPreference.custom => customSeedColor,
  };
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
    await _syncToLegacySingletons();

    notifyListeners();
  }

  // ── Theme Mode ─────────────────────────────────────────────────────────

  Future<void> setThemeMode(AppThemePreference value) async {
    if (_state.themeMode == value) return;
    _state = _state.copyWith(themeMode: value);
    notifyListeners();

    // Delegate to legacy singleton
    await ThemeModeController.instance.setThemeMode(value.materialThemeMode);
    // Persist
    await AppPreferencesStore.instance.saveThemeMode(value);
  }

  // ── Palette ────────────────────────────────────────────────────────────

  Future<void> setPaletteIndex(int value) async {
    final safe = value.clamp(0, AppThemeController.presetSeedColors.length - 1);
    if (_state.paletteIndex == safe &&
        _state.colorSource == AppColorPreference.preset) {
      return;
    }
    _state = _state.copyWith(
      colorSource: AppColorPreference.preset,
      paletteIndex: safe,
    );
    notifyListeners();

    // Delegate to legacy singletons
    await AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
    await AppThemeController.instance.setPresetSeedIndex(safe);
    // Persist
    await AppPreferencesStore.instance.savePaletteIndex(safe);
  }

  Future<void> setCustomSeedColor(Color value) async {
    final safeColor = value.withValues(alpha: 1);
    if (_state.colorSource == AppColorPreference.custom &&
        _state.customSeedColor == safeColor) {
      return;
    }
    _state = _state.copyWith(
      colorSource: AppColorPreference.custom,
      customSeedColor: safeColor,
    );
    notifyListeners();

    await AppThemeController.instance.setCustomSeedColor(safeColor);
    await AppPreferencesStore.instance.saveCustomSeedColor(safeColor);
  }

  // ── Pure Black ─────────────────────────────────────────────────────────

  Future<void> setPureBlack(bool value) async {
    if (_state.pureBlack == value) return;
    _state = _state.copyWith(pureBlack: value);
    notifyListeners();

    await AppThemeController.instance.setPureBlackMode(value);
    await AppPreferencesStore.instance.savePureBlack(value);
  }

  // ── Text Scale ─────────────────────────────────────────────────────────

  Future<void> setTextScale(double value) async {
    final normalized = TextScaleController.normalizeScaleFactor(value);
    if (_state.textScale == normalized) return;
    _state = _state.copyWith(textScale: normalized);
    notifyListeners();

    await TextScaleController.instance.setTextScaleFactor(normalized);
    await AppPreferencesStore.instance.saveTextScale(normalized);
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
    await AppThemeController.instance.setHomeTextColorMode(legacyMode);
    await AppPreferencesStore.instance.saveHomeTextColor(value);
  }

  // ── Legacy sync ────────────────────────────────────────────────────────

  /// Sync restored preferences to legacy singletons so existing
  /// ValueListenableBuilder widgets stay in sync.
  Future<void> _syncToLegacySingletons() async {
    // Use public setters so existing ValueListenableBuilder widgets stay in sync.
    await ThemeModeController.instance.setThemeMode(_state.materialThemeMode);
    await TextScaleController.instance.setTextScaleFactor(_state.textScale);
    await AppThemeController.instance.setPureBlackMode(_state.pureBlack);
    if (_state.colorSource == AppColorPreference.custom) {
      await AppThemeController.instance.setCustomSeedColor(
        _state.customSeedColor,
      );
    } else {
      await AppThemeController.instance.setSeedMode(AppThemeSeedMode.preset);
      await AppThemeController.instance.setPresetSeedIndex(_state.paletteIndex);
    }
    final legacyHomeTextColor = switch (_state.homeTextColor) {
      HomeTextColorPreference.system => HomeTextColorMode.system,
      HomeTextColorPreference.dark => HomeTextColorMode.dark,
      HomeTextColorPreference.light => HomeTextColorMode.light,
    };
    await AppThemeController.instance.setHomeTextColorMode(legacyHomeTextColor);
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
