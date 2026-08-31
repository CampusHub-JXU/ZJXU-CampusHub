import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_theme_builder.dart';

class AppTheme {
  AppTheme._();

  static ThemeData lightTheme = lightThemeFor(AppColors.primary);
  static ThemeData darkTheme = darkThemeFor(AppColors.primary);

  static ThemeData lightThemeFor(
    Color seedColor, {
    bool filledButtonSoftStyle = false,
  }) => AppThemeBuilder.light(
    seedColor,
    filledButtonSoftStyle: filledButtonSoftStyle,
  );

  static ThemeData darkThemeFor(
    Color seedColor, {
    bool pureBlack = false,
    bool filledButtonSoftStyle = false,
  }) => AppThemeBuilder.dark(
    seedColor,
    pureBlack: pureBlack,
    filledButtonSoftStyle: filledButtonSoftStyle,
  );
}
