import 'package:flutter/material.dart';

/// Material 3 theme builder.
///
/// Builds light/dark [ThemeData] from a seed color, optionally
/// overriding dark surfaces for pure-black (AMOLED) mode.
class AppThemeBuilder {
  AppThemeBuilder._();

  static const Color _graphiteSeed = Color(0xFF455A64);
  static const Color _brandRedSeed = Color(0xFF8B1A2D);

  /// 深色模式下使用中性石墨/黑灰背景的种子色集合。
  /// 品牌红（嘉大红）保留为 primary 用于强调色，但 surface/scaffold
  /// 不再掺入酒红，避免深色模式出现"血色/阴间"观感。
  static bool _isNeutralDarkSeed(Color seedColor) =>
      seedColor == _graphiteSeed || seedColor == _brandRedSeed;

  // ── Light ──────────────────────────────────────────────────────────────

  static ThemeData light(
    Color seedColor, {
    bool filledButtonSoftStyle = false,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    ).copyWith(primary: seedColor);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: colorScheme.primary,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLowest,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: filledButtonSoftStyle
              ? colorScheme.primaryContainer
              : colorScheme.primary,
          foregroundColor: filledButtonSoftStyle
              ? colorScheme.onPrimaryContainer
              : colorScheme.onPrimary,
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
        fillColor: colorScheme.surfaceContainerHighest,
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
        backgroundColor: colorScheme.surfaceContainerLowest,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surfaceContainerLowest,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            );
          }
          return TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 0.5,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        labelStyle: TextStyle(fontSize: 13, color: colorScheme.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Dark ───────────────────────────────────────────────────────────────

  static Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

  static Color _foregroundFor(Color background) =>
      background.computeLuminance() > 0.45 ? Colors.black : Colors.white;

  static Color _darkSeedTone(Color seedColor, double lightness) {
    final hsl = HSLColor.fromColor(seedColor);
    return hsl
        .withSaturation((hsl.saturation * 0.72).clamp(0.28, 0.78))
        .withLightness(lightness)
        .toColor();
  }

  static ThemeData dark(
    Color seedColor, {
    bool pureBlack = false,
    bool filledButtonSoftStyle = false,
  }) {
    final isNeutralDark = _isNeutralDarkSeed(seedColor);
    final baseScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    final seedBase = _darkSeedTone(seedColor, 0.12);
    final seedRaised = _darkSeedTone(seedColor, 0.18);
    final seedHigh = _darkSeedTone(seedColor, 0.24);

    final darkBase = pureBlack
        ? const Color(0xFF000000)
        : isNeutralDark
        ? const Color(0xFF101418)
        : baseScheme.surface;
    final darkSurf = pureBlack
        ? const Color(0xFF0A0A0A)
        : isNeutralDark
        ? const Color(0xFF171C20)
        : baseScheme.surfaceContainerLow;
    final darkSurfHigh = pureBlack
        ? const Color(0xFF111111)
        : isNeutralDark
        ? const Color(0xFF242B30)
        : baseScheme.surfaceContainerHigh;

    final background = isNeutralDark
        ? darkBase
        : _mix(darkBase, seedBase, pureBlack ? 0.0 : 0.42);
    final surface = isNeutralDark
        ? darkSurf
        : _mix(darkSurf, seedRaised, pureBlack ? 0.0 : 0.52);
    final surfaceHigh = isNeutralDark
        ? darkSurfHigh
        : _mix(darkSurfHigh, seedHigh, pureBlack ? 0.0 : 0.58);
    var colorScheme = baseScheme.copyWith(
      surface: surface,
      surfaceContainerHighest: surfaceHigh,
      surfaceContainerHigh: isNeutralDark
          ? surfaceHigh
          : _mix(
              pureBlack
                  ? const Color(0xFF0E0E0E)
                  : baseScheme.surfaceContainerHigh,
              seedHigh,
              pureBlack ? 0.0 : 0.28,
            ),
      surfaceContainer: surface,
      surfaceContainerLow: isNeutralDark
          ? const Color(0xFF12171B)
          : _mix(
              pureBlack
                  ? const Color(0xFF060606)
                  : baseScheme.surfaceContainerLow,
              seedRaised,
              pureBlack ? 0.0 : 0.22,
            ),
      surfaceContainerLowest: background,
    );
    if (isNeutralDark) {
      colorScheme = colorScheme.copyWith(
        primary: seedColor,
        onPrimary: _foregroundFor(seedColor),
      );
    }

    final darkDivider = Colors.white.withValues(alpha: 0.08);
    final cardBorderColor = isNeutralDark
        ? Colors.white.withValues(alpha: 0.08)
        : _mix(seedColor, Colors.white, 0.35).withValues(alpha: 0.13);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: surface.withValues(alpha: 0.86),
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cardBorderColor, width: 0.5),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: filledButtonSoftStyle
              ? colorScheme.primaryContainer
              : colorScheme.primary,
          foregroundColor: filledButtonSoftStyle
              ? colorScheme.onPrimaryContainer
              : colorScheme.onPrimary,
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
        fillColor: colorScheme.surfaceContainerHigh,
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
        backgroundColor: surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: 0.88),
        indicatorColor: colorScheme.primary.withValues(alpha: 0.28),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            );
          }
          return TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
      ),
      dividerTheme: DividerThemeData(
        color: darkDivider,
        thickness: 0.5,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        selectedColor: colorScheme.primary.withValues(alpha: 0.2),
        labelStyle: TextStyle(fontSize: 13, color: colorScheme.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide.none,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
