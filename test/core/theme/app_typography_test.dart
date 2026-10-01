import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/core/theme/app_typography.dart';

void main() {
  test('fromScheme 按角色给出字号 / 字重 / 颜色', () {
    final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF8B1A2D));
    final t = AppTypography.fromScheme(cs);

    expect(t.label.fontSize, 13);
    expect(t.label.fontWeight, FontWeight.w600);
    expect(t.label.color, cs.onSurfaceVariant);
    expect(t.listTitle.fontSize, 16);
    expect(t.rowTitle.fontSize, 15);
    expect(t.rowTitle.fontWeight, FontWeight.w600);
    expect(t.secondary.fontSize, 13);
    expect(t.meta.fontSize, 12);
    expect(t.tag.fontSize, 11);
    expect(t.unit.fontSize, 22);

    // 数字三档：76 / 48 / 24，全部等宽数字。
    expect(t.readout.fontSize, 76);
    expect(t.overview.fontSize, 48);
    expect(t.rowValue.fontSize, 24);
    for (final style in [t.readout, t.overview, t.rowValue]) {
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    }

    // 不写字体家族：继承 ThemeData.fontFamily（打包的 Inter）。
    expect(t.readout.fontFamily, isNull);
  });

  test('AppThemeBuilder 亮 / 暗主题都注册了扩展，颜色跟随各自 ColorScheme', () {
    const seed = Color(0xFF455A64);
    final themes = {
      'light': AppThemeBuilder.light(seed),
      'dark': AppThemeBuilder.dark(seed),
      'pureBlack': AppThemeBuilder.dark(seed, pureBlack: true),
    };
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      final t = theme.extension<AppTypography>();
      expect(t, isNotNull, reason: name);
      expect(t!.label.color, theme.colorScheme.onSurfaceVariant);
      expect(t.readout.color, theme.colorScheme.onSurface);
    }
  });

  testWidgets('context.appText 在未注册扩展的主题下按当前配色现算', (tester) async {
    late AppTypography resolved;
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            resolved = context.appText;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(resolved.label.color, theme.colorScheme.onSurfaceVariant);
    expect(resolved.readout.fontSize, 76);
  });

  test('lerp 在两端返回对应值', () {
    final a = AppTypography.fromScheme(
      ColorScheme.fromSeed(seedColor: Colors.red),
    );
    final b = AppTypography.fromScheme(
      ColorScheme.fromSeed(seedColor: Colors.red, brightness: Brightness.dark),
    );
    expect(a.lerp(b, 0).label.color, a.label.color);
    expect(a.lerp(b, 1).label.color, b.label.color);
    expect(a.lerp(null, 0.5), same(a));
  });
}
