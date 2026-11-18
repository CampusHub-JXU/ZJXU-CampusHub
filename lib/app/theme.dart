import 'package:material_ui/material_ui.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_theme_builder.dart';

class AppTheme {
  AppTheme._();

  static ThemeData lightTheme = lightThemeFor(AppColors.primary);
  static ThemeData darkTheme = darkThemeFor(AppColors.primary);

  static ThemeData lightThemeFor(Color seedColor) =>
      AppThemeBuilder.light(seedColor);

  static ThemeData darkThemeFor(Color seedColor, {bool pureBlack = false}) =>
      AppThemeBuilder.dark(seedColor, pureBlack: pureBlack);
}
