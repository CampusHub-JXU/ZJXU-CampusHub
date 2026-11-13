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
/// 深浅切换全部交给资源限定符（`drawable-night` / `values-night`）随系统夜间
/// 模式自动渲染：跟随主题色用 `LauncherTheme{N}Auto`，青瓷用默认
/// `LauncherCeladon`；运行时不再随主题模式翻转 alias（禁用当前启动组件会把
/// 任务退回桌面）。
String resolveAppIconLauncherAlias({
  required AppIconStyle style,
  required Color seedColor,
  int? presetPaletteIndex,
}) {
  if (style == AppIconStyle.crimsonClassic) {
    return 'LauncherCrimson';
  }
  if (style == AppIconStyle.themeInverted) {
    return 'LauncherRedBlack';
  }
  if (style == AppIconStyle.followTheme) {
    final index = _resolvePaletteIndex(seedColor, presetPaletteIndex);
    return 'LauncherTheme${index}Auto';
  }
  return 'LauncherCeladon';
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
///
/// 跟随主题色时浅/深两条路径都走色彩系统派生，不做粗暴反色：
/// - 浅色：白底掺 6% 种子色，帆用种子色本体（过亮时压回 HSL L0.35）；
/// - 深色：帆用 `ColorScheme.fromSeed(seed, dark).primary`（tonalSpot T80，
///   即应用深色主题的同源强调色），底用与 `AppThemeBuilder._darkSeedTone`
///   同款的种子调暗面（HSL 饱和 ×0.72 夹紧、明度 0.14），波纹沿用帆→底
///   24%/48% 渐变带。
/// Android 侧由 `tools/brand/make_icons.py::_palette_dark_spec` 按同一公式
/// 烘焙（TonalPalette(hue, 36).get(80) ≡ tonalSpot T80），改公式必须两端同步。
@immutable
class AppIconColors {
  const AppIconColors(this.top, this.bottom, this.sail, this.waves);

  final Color top;
  final Color bottom;
  final Color sail;
  final List<Color> waves;

  static const ivory = Color(0xFFF3F2EE);
  static const redBlack = Color(0xFF160609);
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

  /// 与 alias 资源逐款对应：深色只取资源限定符那套（青瓷→05a 黛瓦、
  /// 跟随主题色→种子调暗面），「深色反色 · 红黑」是固定风格不随模式变化。
  static AppIconColors resolve({
    required AppIconStyle style,
    required Color seed,
    required bool isDark,
  }) {
    return switch (style) {
      AppIconStyle.celadonSlate => isDark ? slate : celadon,
      AppIconStyle.crimsonClassic => _crimson(),
      AppIconStyle.themeInverted => _redBlack(),
      AppIconStyle.followTheme => isDark ? _themeDark(seed) : _themeLight(seed),
    };
  }

  static AppIconColors _redBlack() => AppIconColors(redBlack, redBlack, ivory, [
    ivory,
    Color.lerp(ivory, redBlack, 0.24)!,
    Color.lerp(ivory, redBlack, 0.48)!,
  ]);

  static AppIconColors _crimson() =>
      AppIconColors(AppColors.primary, AppColors.primary, ivory, [
        ivory,
        Color.lerp(ivory, AppColors.primary, 0.24)!,
        Color.lerp(ivory, AppColors.primary, 0.48)!,
      ]);

  static AppIconColors _themeLight(Color seed) {
    final background = Color.lerp(Colors.white, seed, 0.06)!;
    final sail = seed.computeLuminance() > 0.65
        ? HSLColor.fromColor(seed).withLightness(0.35).toColor()
        : seed;
    return AppIconColors(background, background, sail, [
      sail,
      Color.lerp(sail, background, 0.24)!,
      Color.lerp(sail, background, 0.48)!,
    ]);
  }

  static AppIconColors _themeDark(Color seed) {
    final sail = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).primary;
    final hsl = HSLColor.fromColor(seed);
    final background = hsl
        .withSaturation((hsl.saturation * 0.72).clamp(0.28, 0.78))
        .withLightness(0.14)
        .toColor();
    return AppIconColors(background, background, sail, [
      sail,
      Color.lerp(sail, background, 0.24)!,
      Color.lerp(sail, background, 0.48)!,
    ]);
  }
}
