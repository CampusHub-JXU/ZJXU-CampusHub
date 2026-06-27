import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/home/home_controller.dart';
import 'theme.dart';

enum AppThemeSeedMode {
  brandRed('默认红色'),
  monet('莫奈取色'),
  preset('预设颜色'),
  custom('自定义颜色');

  const AppThemeSeedMode(this.label);
  final String label;
}

enum HomeTextColorMode {
  system('跟随系统'),
  dark('深色文字'),
  light('浅色文字');

  const HomeTextColorMode(this.label);
  final String label;
}

class AppThemeController {
  AppThemeController._();

  static final AppThemeController instance = AppThemeController._();

  static const _prefKey = 'app_theme_seed_mode';
  static const _pureBlackModeKey = 'app_theme_pure_black_mode';
  static const _monetSeedIndexKey = 'app_theme_monet_seed_index';
  static const _presetSeedIndexKey = 'app_theme_preset_seed_index';
  static const _customSeedColorKey = 'app_theme_custom_seed_color';
  static const _homeTextColorModeKey = 'app_theme_home_text_color_mode';
  static const defaultCustomSeedColor = AppColors.primary;

  final ValueNotifier<AppThemeSeedMode> seedMode = ValueNotifier(
    AppThemeSeedMode.brandRed,
  );
  final ValueNotifier<Color> seedColor = ValueNotifier(AppColors.primary);
  final ValueNotifier<Color> customSeedColor = ValueNotifier(
    defaultCustomSeedColor,
  );
  final ValueNotifier<bool> pureBlackMode = ValueNotifier(false);
  final ValueNotifier<int> monetSeedIndex = ValueNotifier(1);
  final ValueNotifier<int> presetSeedIndex = ValueNotifier(0);
  final ValueNotifier<HomeTextColorMode> homeTextColorMode = ValueNotifier(
    HomeTextColorMode.system,
  );

  static const presetSeedColors = <Color>[
    Color(0xFF8B1A2D),
    Color(0xFF1565C0),
    Color(0xFF00A6A6),
    Color(0xFF6C5CE7),
    Color(0xFFE94B9B),
    Color(0xFFFF8A00),
    Color(0xFF2E7D32),
    Color(0xFF455A64),
  ];

  static const presetSeedLabels = <String>[
    '嘉大红',
    '嘉大蓝',
    '湖青',
    '紫罗兰',
    '樱粉',
    '暖橙',
    '松绿',
    '石墨',
  ];

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_prefKey);
    if (stored != null &&
        stored >= 0 &&
        stored < AppThemeSeedMode.values.length) {
      seedMode.value = AppThemeSeedMode.values[stored];
    }
    pureBlackMode.value = prefs.getBool(_pureBlackModeKey) ?? false;
    monetSeedIndex.value = (prefs.getInt(_monetSeedIndexKey) ?? 1).clamp(0, 4);
    presetSeedIndex.value = (prefs.getInt(_presetSeedIndexKey) ?? 0).clamp(
      0,
      presetSeedColors.length - 1,
    );
    customSeedColor.value = _opaqueColor(
      Color(
        prefs.getInt(_customSeedColorKey) ?? defaultCustomSeedColor.toARGB32(),
      ),
    );
    final storedHomeTextMode = prefs.getInt(_homeTextColorModeKey);
    if (storedHomeTextMode != null &&
        storedHomeTextMode >= 0 &&
        storedHomeTextMode < HomeTextColorMode.values.length) {
      homeTextColorMode.value = HomeTextColorMode.values[storedHomeTextMode];
    }
    await _refreshSeedColor();
  }

  Future<void> setSeedMode(AppThemeSeedMode mode) async {
    if (seedMode.value == mode) return;
    seedMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKey, mode.index);
    await _refreshSeedColor();
  }

  Future<void> setPureBlackMode(bool enabled) async {
    if (pureBlackMode.value == enabled) return;
    pureBlackMode.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pureBlackModeKey, enabled);
  }

  Future<void> setMonetSeedIndex(int index) async {
    final safeIndex = index.clamp(0, 4);
    if (monetSeedIndex.value == safeIndex) return;
    monetSeedIndex.value = safeIndex;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_monetSeedIndexKey, safeIndex);
    await _refreshSeedColor();
  }

  Future<void> setPresetSeedIndex(int index) async {
    final safeIndex = index.clamp(0, presetSeedColors.length - 1);
    if (presetSeedIndex.value == safeIndex) return;
    presetSeedIndex.value = safeIndex;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetSeedIndexKey, safeIndex);
    await _refreshSeedColor();
  }

  Future<void> setCustomSeedColor(Color color) async {
    final safeColor = _opaqueColor(color);
    final prefs = await SharedPreferences.getInstance();

    if (customSeedColor.value != safeColor) {
      customSeedColor.value = safeColor;
      await prefs.setInt(_customSeedColorKey, safeColor.toARGB32());
    }
    if (seedMode.value != AppThemeSeedMode.custom) {
      seedMode.value = AppThemeSeedMode.custom;
      await prefs.setInt(_prefKey, AppThemeSeedMode.custom.index);
    }
    seedColor.value = safeColor;
  }

  Future<void> setHomeTextColorMode(HomeTextColorMode mode) async {
    if (homeTextColorMode.value == mode) return;
    homeTextColorMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_homeTextColorModeKey, mode.index);
  }

  Color resolveIconColor(BuildContext context, Color fallback) {
    // 莫奈取色模式下整体主题源自背景图，图标统一跟随主题色以保持协调；
    // 其余模式（品牌红 / 预设 / 自定义）透传调用方传入的 accent 色，
    // 让 feature_entry_catalog 中为每个入口定义的 accentColor 生效。
    return switch (seedMode.value) {
      AppThemeSeedMode.monet => Theme.of(context).colorScheme.primary,
      _ => fallback,
    };
  }

  Color resolveHomeTextColor(BuildContext context, Color fallback) {
    return switch (homeTextColorMode.value) {
      HomeTextColorMode.system => fallback,
      HomeTextColorMode.dark => const Color(0xFF1F1A1D),
      HomeTextColorMode.light => Colors.white,
    };
  }

  /// System 模式下根据背景亮度自动选择 light/dark 文字，保证 WCAG AA 对比度。
  /// 其余模式保持用户显式选择。供首页头部等渐变/玻璃材质文案使用。
  Color resolveHomeTextColorForBackground(
    BuildContext context,
    Color background,
  ) {
    return switch (homeTextColorMode.value) {
      HomeTextColorMode.system =>
        background.computeLuminance() < 0.42
            ? Colors.white
            : const Color(0xFF1F1A1D),
      HomeTextColorMode.dark => const Color(0xFF1F1A1D),
      HomeTextColorMode.light => Colors.white,
    };
  }

  Color resolveHomeSecondaryTextColorForBackground(
    BuildContext context,
    Color background,
  ) {
    return switch (homeTextColorMode.value) {
      HomeTextColorMode.system =>
        background.computeLuminance() < 0.42
            ? Colors.white.withValues(alpha: 0.82)
            : const Color(0xFF4C4247),
      HomeTextColorMode.dark => const Color(0xFF4C4247),
      HomeTextColorMode.light => Colors.white.withValues(alpha: 0.82),
    };
  }

  Color resolveHomeSecondaryTextColor(BuildContext context, Color fallback) {
    return switch (homeTextColorMode.value) {
      HomeTextColorMode.system => fallback,
      HomeTextColorMode.dark => const Color(0xFF4C4247),
      HomeTextColorMode.light => Colors.white.withValues(alpha: 0.82),
    };
  }

  Future<void> refreshMonetSeed() async {
    if (seedMode.value != AppThemeSeedMode.monet) return;
    await _refreshSeedColor();
  }

  Future<void> _refreshSeedColor() async {
    if (seedMode.value == AppThemeSeedMode.brandRed) {
      seedColor.value = AppColors.primary;
      return;
    }
    if (seedMode.value == AppThemeSeedMode.preset) {
      seedColor.value = presetSeedColors[presetSeedIndex.value];
      return;
    }
    if (seedMode.value == AppThemeSeedMode.custom) {
      seedColor.value = customSeedColor.value;
      return;
    }

    final colors = await HomeController.instance.getMonetColors();
    seedColor.value = _pickMonetSeed(colors);
  }

  Color _opaqueColor(Color color) => color.withValues(alpha: 1);

  Color _pickMonetSeed(List<Color> colors) {
    if (colors.isEmpty) return AppColors.primary;
    final selectedIndex = monetSeedIndex.value;
    if (selectedIndex < colors.length &&
        colors[selectedIndex].computeLuminance() > 0.03) {
      return colors[selectedIndex];
    }
    for (final index in const [1, 0, 2, 3, 4]) {
      if (index < colors.length && colors[index].computeLuminance() > 0.05) {
        return colors[index];
      }
    }
    return colors.first;
  }

  @visibleForTesting
  void debugReset({AppThemeSeedMode mode = AppThemeSeedMode.brandRed}) {
    seedMode.value = mode;
    seedColor.value = AppColors.primary;
    customSeedColor.value = defaultCustomSeedColor;
    pureBlackMode.value = false;
    monetSeedIndex.value = 1;
    presetSeedIndex.value = 0;
    homeTextColorMode.value = HomeTextColorMode.system;
  }
}
