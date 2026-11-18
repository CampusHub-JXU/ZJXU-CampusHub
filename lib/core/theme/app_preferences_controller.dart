import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../storage/app_preferences_store.dart';
import '../system_surface/app_icon_switcher.dart';
import 'app_icon_style.dart';
import 'app_theme_controller.dart';
import 'app_theme_palette.dart';
import 'text_scale_controller.dart';

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
  final AppIconStyle appIconStyle;

  const AppPreferences({
    this.themeMode = AppThemePreference.system,
    this.colorSource = AppColorPreference.preset,
    this.paletteIndex = 0,
    this.customSeedColor = AppThemeController.defaultCustomSeedColor,
    this.pureBlack = false,
    this.textScale = 0.9,
    this.homeTextColor = HomeTextColorPreference.system,
    this.appIconStyle = AppIconStyle.celadonSlate,
  });

  AppPreferences copyWith({
    AppThemePreference? themeMode,
    AppColorPreference? colorSource,
    int? paletteIndex,
    Color? customSeedColor,
    bool? pureBlack,
    double? textScale,
    HomeTextColorPreference? homeTextColor,
    AppIconStyle? appIconStyle,
  }) {
    return AppPreferences(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      paletteIndex: paletteIndex ?? this.paletteIndex,
      customSeedColor: customSeedColor ?? this.customSeedColor,
      pureBlack: pureBlack ?? this.pureBlack,
      textScale: textScale ?? this.textScale,
      homeTextColor: homeTextColor ?? this.homeTextColor,
      appIconStyle: appIconStyle ?? this.appIconStyle,
    );
  }

  ThemeMode get materialThemeMode => switch (themeMode) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  Color get seedColor => switch (colorSource) {
    AppColorPreference.preset =>
      themePalettes[paletteIndex.clamp(0, themePalettes.length - 1).toInt()]
          .primary,
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

    _syncSeedColorNotifier();
    _syncHomeTextColorNotifier();
    _syncLauncherIcon();
    notifyListeners();
  }

  // ── Theme Mode ─────────────────────────────────────────────────────────

  Future<void> setThemeMode(AppThemePreference value) async {
    if (_state.themeMode == value) return;
    _state = _state.copyWith(themeMode: value);
    notifyListeners();

    await AppPreferencesStore.instance.saveThemeMode(value);
  }

  // ── Palette ────────────────────────────────────────────────────────────

  Future<void> setPaletteIndex(int value) async {
    final safe = value.clamp(0, themePalettes.length - 1);
    if (_state.paletteIndex == safe &&
        _state.colorSource == AppColorPreference.preset) {
      return;
    }
    _state = _state.copyWith(
      colorSource: AppColorPreference.preset,
      paletteIndex: safe,
    );
    _syncSeedColorNotifier();
    _syncLauncherIcon();
    notifyListeners();

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
    _syncSeedColorNotifier();
    _syncLauncherIcon();
    notifyListeners();

    await AppPreferencesStore.instance.saveCustomSeedColor(safeColor);
  }

  // ── Pure Black ─────────────────────────────────────────────────────────

  Future<void> setPureBlack(bool value) async {
    if (_state.pureBlack == value) return;
    _state = _state.copyWith(pureBlack: value);
    notifyListeners();

    await AppPreferencesStore.instance.savePureBlack(value);
  }

  // ── Text Scale ─────────────────────────────────────────────────────────

  Future<void> setTextScale(double value) async {
    final normalized = TextScaleController.normalizeScaleFactor(value);
    if (_state.textScale == normalized) return;
    _state = _state.copyWith(textScale: normalized);
    notifyListeners();

    await AppPreferencesStore.instance.saveTextScale(normalized);
  }

  // ── Home Text Color ────────────────────────────────────────────────────

  Future<void> setHomeTextColor(HomeTextColorPreference value) async {
    if (_state.homeTextColor == value) return;
    _state = _state.copyWith(homeTextColor: value);
    notifyListeners();

    _syncHomeTextColorNotifier();
    await AppPreferencesStore.instance.saveHomeTextColor(value);
  }

  void _syncHomeTextColorNotifier() {
    final mode = switch (_state.homeTextColor) {
      HomeTextColorPreference.system => HomeTextColorMode.system,
      HomeTextColorPreference.dark => HomeTextColorMode.dark,
      HomeTextColorPreference.light => HomeTextColorMode.light,
    };
    AppThemeController.instance.updateHomeTextColorMode(mode);
  }

  Future<void> setAppIconStyle(AppIconStyle value) async {
    _state = _state.copyWith(appIconStyle: value);
    _syncLauncherIcon();
    notifyListeners();
    await AppPreferencesStore.instance.saveAppIconPreferences(_state);
  }

  void _syncLauncherIcon() {
    final alias = resolveAppIconLauncherAlias(
      style: _state.appIconStyle,
      seedColor: _state.seedColor,
      presetPaletteIndex: _state.colorSource == AppColorPreference.preset
          ? _state.paletteIndex
          : null,
    );
    unawaited(AppIconSwitcher.instance.setAlias(alias));
  }

  void _syncSeedColorNotifier() {
    AppThemeController.instance.updateSeedColor(_state.seedColor);
  }

  @visibleForTesting
  void debugReset() {
    _state = const AppPreferences();
    AppIconSwitcher.instance.clearCache();
    _syncSeedColorNotifier();
    _syncHomeTextColorNotifier();
    notifyListeners();
  }
}
