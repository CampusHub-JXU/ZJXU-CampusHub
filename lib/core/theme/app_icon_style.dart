import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_theme_palette.dart';

enum AppIconStyle {
  celadonSlate('青瓷 · 黛瓦'),
  followTheme('跟随主题色'),
  themeInverted('深色反色 · 红黑'),
  crimsonClassic('嘉大红');

  const AppIconStyle(this.label);
  final String label;
}

/// 按 sRGB 距离找与 [color] 最接近的预设主题色下标（Android 桌面仅支持预设 alias）。
int nearestIconPaletteIndex(Color color) {
  final target = color.toARGB32();
  final tr = (target >> 16) & 0xFF;
  final tg = (target >> 8) & 0xFF;
  final tb = target & 0xFF;
  var bestIndex = 0;
  var bestDistance = 1 << 30;
  for (var i = 0; i < themePalettes.length; i++) {
    final p = themePalettes[i].primary.toARGB32();
    final dr = ((p >> 16) & 0xFF) - tr;
    final dg = ((p >> 8) & 0xFF) - tg;
    final db = (p & 0xFF) - tb;
    final dist = dr * dr + dg * dg + db * db;
    if (dist < bestDistance) {
      bestDistance = dist;
      bestIndex = i;
    }
  }
  return bestIndex;
}

/// 把用户偏好映射为 `AndroidManifest.xml` 中注册的 `<activity-alias>` 后缀名。
///
/// [themeMode] 取值 `'system'` / `'light'` / `'dark'`（避免 `app_icon_style` 与
/// `app_preferences_controller` 循环 import）。
String resolveAppIconLauncherAlias({
  required AppIconStyle style,
  required Color seedColor,
  int? presetPaletteIndex,
  required bool followThemeColor,
  required bool darkInvert,
  required String themeModeName,
}) {
  if (style == AppIconStyle.crimsonClassic) {
    return 'LauncherCrimson';
  }
  final follows = followThemeColor || style == AppIconStyle.followTheme;
  if (style == AppIconStyle.themeInverted) {
    if (!follows) {
      return 'LauncherRedBlack';
    }
    final index = _resolvePaletteIndex(seedColor, presetPaletteIndex);
    return 'LauncherTheme${index}Dark';
  }
  if (follows) {
    final index = _resolvePaletteIndex(seedColor, presetPaletteIndex);
    if (!darkInvert || themeModeName == 'light') {
      return 'LauncherTheme$index';
    }
    if (themeModeName == 'dark') {
      return 'LauncherTheme${index}Dark';
    }
    return 'LauncherTheme${index}Auto';
  }
  return darkInvert ? 'LauncherCeladon' : 'LauncherCeladonDay';
}

int _resolvePaletteIndex(Color seedColor, int? presetPaletteIndex) {
  if (presetPaletteIndex != null &&
      presetPaletteIndex >= 0 &&
      presetPaletteIndex < themePalettes.length) {
    return presetPaletteIndex;
  }
  return nearestIconPaletteIndex(seedColor);
}

/// Nanhu Sail 品牌配色；04b 汝窑天青与 05 烟雨黛瓦沿用品牌母稿。
@immutable
class AppIconColors {
  const AppIconColors(this.top, this.bottom, this.sail, this.waves);

  final Color top;
  final Color bottom;
  final Color sail;
  final List<Color> waves;

  static const ivory = Color(0xFFF3F2EE);
  static const redBlack = Color(0xFF160609);
  static const brightRed = Color(0xFFE64D63);
  static const celadon = AppIconColors(
    Color(0xFFDDE5E9),
    Color(0xFFC7D3DA),
    Color(0xFF18262F),
    [Color(0xFF283C48), Color(0xFF4E6573), Color(0xFF7A919E)],
  );
  static const slate = AppIconColors(
    Color(0xFF293138),
    Color(0xFF1C2227),
    ivory,
    [Color(0xFFCFD5D9), Color(0xFF929CA4), Color(0xFF5C666E)],
  );

  static AppIconColors resolve({
    required AppIconStyle style,
    required Color primary,
    required bool isDark,
    bool followThemeColor = false,
    bool darkInvert = false,
  }) {
    final follows = followThemeColor || style == AppIconStyle.followTheme;
    final inverted =
        style == AppIconStyle.themeInverted ||
        (follows && isDark && darkInvert);
    if (inverted) {
      final sail = follows
          ? (primary.computeLuminance() < 0.18 ? brightRed : primary)
          : ivory;
      return AppIconColors(redBlack, redBlack, sail, [
        ivory,
        Color.lerp(ivory, redBlack, 0.24)!,
        Color.lerp(ivory, redBlack, 0.48)!,
      ]);
    }
    if (follows) {
      final background = Color.lerp(Colors.white, primary, 0.06)!;
      final sail = primary.computeLuminance() > 0.65
          ? HSLColor.fromColor(primary).withLightness(0.35).toColor()
          : primary;
      return AppIconColors(background, background, sail, [
        sail,
        Color.lerp(sail, background, 0.24)!,
        Color.lerp(sail, background, 0.48)!,
      ]);
    }
    if (style == AppIconStyle.crimsonClassic) {
      return AppIconColors(AppColors.primary, AppColors.primary, ivory, [
        ivory,
        Color.lerp(ivory, AppColors.primary, 0.24)!,
        Color.lerp(ivory, AppColors.primary, 0.48)!,
      ]);
    }
    return isDark ? slate : celadon;
  }
}
