import 'package:flutter/material.dart';

import 'app_theme_palette.dart';

enum HomeTextColorMode { system, dark, light }

class AppThemeController {
  AppThemeController._();

  static final instance = AppThemeController._();

  static const defaultCustomSeedColor = Color(0xFF8B1A2D);
  static final presetSeedColors = List<Color>.unmodifiable(
    themePalettes.map((palette) => palette.primary),
  );
  static final presetSeedLabels = List<String>.unmodifiable(
    themePalettes.map((palette) => palette.label),
  );

  final ValueNotifier<HomeTextColorMode> homeTextColorMode = ValueNotifier(
    HomeTextColorMode.system,
  );
  final ValueNotifier<Color> seedColor = ValueNotifier(defaultCustomSeedColor);

  void updateSeedColor(Color color) {
    seedColor.value = color;
  }

  void updateHomeTextColorMode(HomeTextColorMode mode) {
    homeTextColorMode.value = mode;
  }

  Color resolveIconColor(BuildContext context, Color fallback) => fallback;

  Color resolveHomeTextColor(BuildContext context, Color fallback) {
    return switch (homeTextColorMode.value) {
      HomeTextColorMode.system => fallback,
      HomeTextColorMode.dark => const Color(0xFF1F1A1D),
      HomeTextColorMode.light => Colors.white,
    };
  }

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

  @visibleForTesting
  void debugReset() {
    homeTextColorMode.value = HomeTextColorMode.system;
    seedColor.value = defaultCustomSeedColor;
  }
}
