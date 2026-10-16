import 'package:flutter/painting.dart';

import '../../../core/theme/app_theme_builder.dart';

/// 桌面组件卡面底色（与 `docs/desktop-widget-v2.md` §7.1 一致：浅 #FFFFFF /
/// 深 #1C1D21）。这是原生 RemoteViews 卡面的固定色，不属于 App 的
/// ColorScheme，故以分量写出（不是 App 内 UI 配色）。
const Color campusWidgetCardLight = Color.fromARGB(255, 255, 255, 255);
const Color campusWidgetCardDark = Color.fromARGB(255, 28, 29, 33);

/// 强调色对卡面底的最低对比度（WCAG AA 正文）。
const double campusWidgetMinAccentContrast = 4.5;

/// WCAG 相对亮度对比度，范围 1..21。
double campusWidgetContrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 「进行中」行的强调底：强调色按此不透明度叠在卡面上（§7.1，浅 8% / 深 14%）。
const double campusWidgetTintAlphaLight = 0.08;
const double campusWidgetTintAlphaDark = 0.14;

/// [color] 作文字时的最差对比度：既对卡面 [background]，也对叠了
/// [tintAlpha] 强调底的那一行（强调色文字就画在这层底上）。
double _worstContrast(Color color, Color background, double tintAlpha) {
  final onCard = campusWidgetContrastRatio(color, background);
  if (tintAlpha <= 0) return onCard;
  final tinted = Color.alphaBlend(
    color.withValues(alpha: tintAlpha),
    background,
  );
  final onTint = campusWidgetContrastRatio(color, tinted);
  return onCard < onTint ? onCard : onTint;
}

/// 保持色相 / 饱和度，沿 HSL 亮度逐步压暗（[darken] = true）或提亮，直到
/// 对 [background]（以及叠了 [tintAlpha] 强调底的行）的对比度都 ≥ [minRatio]；
/// 已达标则原样返回。
Color ensureCampusWidgetContrast(
  Color color, {
  required Color background,
  required bool darken,
  double tintAlpha = 0,
  double minRatio = campusWidgetMinAccentContrast,
}) {
  final opaque = color.withValues(alpha: 1);
  if (_worstContrast(opaque, background, tintAlpha) >= minRatio) return opaque;
  final hsl = HSLColor.fromColor(opaque);
  var lightness = hsl.lightness;
  var candidate = opaque;
  while (_worstContrast(candidate, background, tintAlpha) < minRatio) {
    lightness += darken ? -0.01 : 0.01;
    if (lightness <= 0 || lightness >= 1) {
      lightness = lightness.clamp(0.0, 1.0);
      candidate = hsl.withLightness(lightness).toColor();
      break;
    }
    candidate = hsl.withLightness(lightness).toColor();
  }
  return candidate;
}

/// `#RRGGBB`（大写，丢弃 alpha）。
String campusWidgetColorHex(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// 由设置里的主题色种子取桌面组件强调色：App 自己的 light / dark 主题
/// `colorScheme.primary`，再做对比度兜底。
({String light, String dark}) resolveCampusWidgetAccents(Color seed) {
  final light = AppThemeBuilder.light(seed).colorScheme.primary;
  final dark = AppThemeBuilder.dark(seed).colorScheme.primary;
  return (
    light: campusWidgetColorHex(
      ensureCampusWidgetContrast(
        light,
        background: campusWidgetCardLight,
        darken: true,
        tintAlpha: campusWidgetTintAlphaLight,
      ),
    ),
    dark: campusWidgetColorHex(
      ensureCampusWidgetContrast(
        dark,
        background: campusWidgetCardDark,
        darken: false,
        tintAlpha: campusWidgetTintAlphaDark,
      ),
    ),
  );
}
