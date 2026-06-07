import 'package:flutter/material.dart';

import '../core/theme/app_theme_builder.dart';

class AppColors {
  AppColors._();

  // Primary - Wine Red
  static const Color primary = Color(0xFF8B1A2D);
  static const Color primaryDark = Color(0xFF6B0F1F);
  static const Color primaryLight = Color(0xFFB85C6E);

  // Secondary - Gold
  static const Color gold = Color(0xFFD4AF37);

  // Semantic
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFF57C00);
  static const Color error = Color(0xFFC62828);
  static const Color info = Color(0xFF1565C0);
}

class AppTheme {
  AppTheme._();

  static ThemeData lightTheme = lightThemeFor(AppColors.primary);
  static ThemeData darkTheme = darkThemeFor(AppColors.primary);

  static ThemeData lightThemeFor(Color seedColor) =>
      AppThemeBuilder.light(seedColor);

  static ThemeData darkThemeFor(Color seedColor, {bool pureBlack = false}) =>
      AppThemeBuilder.dark(seedColor, pureBlack: pureBlack);
}
