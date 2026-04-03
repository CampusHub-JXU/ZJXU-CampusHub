import 'package:flutter/material.dart';

class ThemeModeController {
  ThemeModeController._();

  static final ThemeModeController instance = ThemeModeController._();

  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  void setThemeMode(ThemeMode mode) {
    if (themeMode.value == mode) return;
    themeMode.value = mode;
  }
}
