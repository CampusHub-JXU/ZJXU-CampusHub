import 'package:flutter/material.dart';

/// A named palette entry for the theme picker.
class ThemePalette {
  final String label;
  final Color primary;

  const ThemePalette({required this.label, required this.primary});
}

/// Built-in palette presets.
const themePalettes = <ThemePalette>[
  ThemePalette(label: '嘉大蓝', primary: Color(0xFF1565C0)),
  ThemePalette(label: '湖青', primary: Color(0xFF00A6A6)),
  ThemePalette(label: '紫罗兰', primary: Color(0xFF6C5CE7)),
  ThemePalette(label: '樱粉', primary: Color(0xFFE94B9B)),
  ThemePalette(label: '暖橙', primary: Color(0xFFFF8A00)),
  ThemePalette(label: '松绿', primary: Color(0xFF2E7D32)),
  ThemePalette(label: '石墨', primary: Color(0xFF455A64)),
];

/// Generate preview colors for the palette card (quartered circle).
/// Uses the seed's dark ColorScheme to derive secondary/tertiary.
({Color primary, Color secondary, Color tertiary, Color surface})
previewColorsFromSeed(Color seed) {
  final cs = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
  return (
    primary: seed,
    secondary: cs.secondary,
    tertiary: cs.tertiary,
    surface: cs.surface,
  );
}
