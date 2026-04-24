import 'package:flutter/material.dart';

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

  // Light surfaces
  static const Color surfaceL1 = Color(0xFFFBF9F8);
  static const Color surfaceL2 = Color(0xFFF5F3F2);
  static const Color surfaceL3 = Color(0xFFFFFFFF);

  // Dark surfaces
  static const Color darkBackground = Color(0xFF1A1214);
  static const Color darkSurface = Color(0xFF2D1F23);
}

class AppTheme {
  AppTheme._();

  // ── Cached Themes ────────────────────────────────────────────────────────
  // Pre-computed once; avoids rebuilding ThemeData + ColorScheme on every toggle.

  static final ThemeData lightTheme = lightThemeFor(AppColors.primary);
  static final ThemeData darkTheme = darkThemeFor(AppColors.primary);

  static ThemeData lightThemeFor(Color seedColor) =>
      _buildLightTheme(seedColor);

  static ThemeData darkThemeFor(Color seedColor) => _buildDarkTheme(seedColor);

  static ThemeData _buildLightTheme(Color seedColor) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ).copyWith(
          primary: seedColor,
          surface: AppColors.surfaceL1,
          surfaceContainerHighest: AppColors.surfaceL3,
          surfaceContainerHigh: AppColors.surfaceL2,
          surfaceContainer: AppColors.surfaceL2,
          surfaceContainerLow: AppColors.surfaceL2,
          surfaceContainerLowest: AppColors.surfaceL3,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: AppColors.surfaceL1,

      // AppBar
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: AppColors.surfaceL1,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: colorScheme.primary,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),

      // Cards
      cardTheme: CardThemeData(
        color: AppColors.surfaceL3,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),

      // FilledButton
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // OutlinedButton
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),

      // TextButton
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      // Input
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceL2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),

      // BottomSheet
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        backgroundColor: AppColors.surfaceL3,
      ),

      // NavigationBar
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surfaceL3,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            );
          }
          return const TextStyle(fontSize: 12);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
      ),

      // Divider - intentionally subtle
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE0E0E0),
        thickness: 0.5,
        space: 1,
      ),

      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceL2,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        labelStyle: const TextStyle(fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),

      // ProgressIndicator
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),

      // SnackBar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF323232),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Dark Theme ───────────────────────────────────────────────────────────

  // Pre-computed colors to avoid repeated withValues() allocations.
  static final _darkAppBarBg = AppColors.darkSurface.withValues(alpha: 0.8);
  static final _darkNavBg = AppColors.darkSurface.withValues(alpha: 0.8);
  static final _darkDivider = Colors.white.withValues(alpha: 0.08);
  static final _darkCardBorder = Colors.white.withValues(alpha: 0.08);

  static ThemeData _buildDarkTheme(Color seedColor) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ).copyWith(
          surface: AppColors.darkSurface,
          surfaceContainerHighest: const Color(0xFF3D2E33),
          surfaceContainerHigh: const Color(0xFF35272C),
          surfaceContainer: const Color(0xFF2D1F23),
          surfaceContainerLow: const Color(0xFF251A1E),
          surfaceContainerLowest: const Color(0xFF1A1214),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: AppColors.darkBackground,

      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: _darkAppBarBg,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Color(0xFFE6E1E5),
        ),
      ),

      cardTheme: CardThemeData(
        color: AppColors.darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _darkCardBorder, width: 0.5),
        ),
        margin: EdgeInsets.zero,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF35272C),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        backgroundColor: AppColors.darkSurface,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _darkNavBg,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.2),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            );
          }
          return const TextStyle(fontSize: 12, color: Color(0xFFCAC4D0));
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary);
          }
          return const IconThemeData(color: Color(0xFF938F99));
        }),
      ),

      dividerTheme: DividerThemeData(
        color: _darkDivider,
        thickness: 0.5,
        space: 1,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF35272C),
        selectedColor: colorScheme.primary.withValues(alpha: 0.2),
        labelStyle: const TextStyle(fontSize: 13, color: Color(0xFFE6E1E5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFFE6E1E5),
        contentTextStyle: const TextStyle(color: Color(0xFF1C1B1F)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
