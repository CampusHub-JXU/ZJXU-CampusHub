import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/theme/app_surface_tokens.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/core/theme/app_typography.dart';

void main() {
  test('fromScheme 按角色给出字号 / 字重 / 颜色（v2 基础阶梯）', () {
    final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF8B1A2D));
    final t = AppTypography.fromScheme(cs);

    expect(t.group.fontSize, 13);
    expect(t.group.fontWeight, FontWeight.w600);
    expect(t.group.color, cs.onSurfaceVariant);
    expect(t.label, same(t.group), reason: 'label 是 group 的历史别名');
    expect(t.meta.fontSize, 13);
    expect(t.meta.fontWeight, FontWeight.w400);
    expect(t.rowTitle.fontSize, 16);
    expect(t.rowTitle.fontWeight, FontWeight.w500);
    expect(t.rowTitleStrong.fontSize, 16);
    expect(t.rowTitleStrong.fontWeight, FontWeight.w600);
    expect(t.section.fontSize, 19);
    expect(t.section.fontWeight, FontWeight.w600);
    expect(t.body.fontSize, 15);
    expect(t.body.fontWeight, FontWeight.w400);
    expect(t.title.fontSize, 26);
    expect(t.display.fontSize, 36);
    expect(t.tag.fontSize, 11);
    expect(t.tag.fontWeight, FontWeight.w600);

    // 数字四档：68 / 46 / 24 + 14-12 单位，全部等宽数字。
    expect(t.numReadout.fontSize, 68);
    expect(t.numStat.fontSize, 46);
    expect(t.numValue.fontSize, 24);
    expect(t.numUnit.fontSize, 14);
    expect(t.numUnitCompact.fontSize, 12);
    for (final style in [t.numReadout, t.numStat, t.numValue]) {
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    }
    expect(t.numUnit.fontFeatures, isNull);
    expect(t.numUnitCompact.fontFeatures, isNull);

    // v0 别名必须指向 v2 角色，避免旧调用点悄悄留在老字号上。
    expect(t.readout, same(t.numReadout));
    expect(t.overview, same(t.numStat));
    expect(t.rowValue, same(t.numValue));
    expect(t.unit, same(t.numUnit));
    expect(t.listTitle, same(t.rowTitle));
    expect(t.secondary, same(t.meta));

    // 不写字体家族：继承 ThemeData.fontFamily（打包的 Inter）。
    expect(t.numReadout.fontFamily, isNull);
  });

  test('O1–O5 白名单 Override 的数值与规范一致', () {
    expect(AppScheduleType.cellTitle.fontSize, 11);
    expect(AppScheduleType.cellRoom.fontSize, 9.5);
    expect(AppScheduleType.weekday.fontSize, 12);
    expect(AppScheduleType.date.fontSize, 10.5);
    expect(AppArticleType.body.fontSize, 17);
    expect(AppArticleType.body.height, 1.75);
    expect(AppCompactMetricType.value.fontSize, 20);
    expect(AppChromeType.segment.fontSize, 13.5);
    expect(AppChromeType.dock.fontSize, 11);

    // O4 按字数三档下台阶。
    expect(AppHeroType.forTitle('高等数学A').fontSize, 34);
    expect(AppHeroType.forTitle('计算机组成原理实验').fontSize, 28);
    expect(AppHeroType.forTitle('习近平新时代中国特色社会主义思想概论').fontSize, 22);
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
      expect(t!.group.color, theme.colorScheme.onSurfaceVariant);
      expect(t.numReadout.color, theme.colorScheme.onSurface);
    }
  });

  test('三套表面令牌各自独立，纯黑模式关掉提亮', () {
    const seed = Color(0xFF455A64);
    final lightS = AppThemeBuilder.light(seed).extension<AppSurfaces>()!;
    final darkS = AppThemeBuilder.dark(seed).extension<AppSurfaces>()!;
    final amoledS = AppThemeBuilder.dark(
      seed,
      pureBlack: true,
    ).extension<AppSurfaces>()!;

    expect(lightS.amoled, isFalse);
    expect(darkS.amoled, isFalse);
    expect(amoledS.amoled, isTrue);

    expect(lightS.card, const Color(0xFFFFFFFF));
    expect(darkS.card, const Color(0xFF1A1D21));
    expect(amoledS.card, const Color(0xFF0D0F12));
    expect(amoledS.scaffold, const Color(0xFF000000));

    // 8 色色板齐全，且色相稳定（同一门课永远同一色）。
    expect(lightS.hues, hasLength(8));
    expect(darkS.hues, hasLength(8));
    expect(amoledS.hues, hasLength(8));
    for (final s in [lightS, darkS, amoledS]) {
      expect(s.hueFor('高等数学A'), same(s.hueFor('高等数学A')));
      expect(s.hueFor('高等数学A').background, isNot(s.dimmedHue.background));
    }
    // 色相由内容决定，与主题无关。
    expect(
      lightS.hues.indexOf(lightS.hueFor('数据结构')),
      darkS.hues.indexOf(darkS.hueFor('数据结构')),
    );
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
    expect(resolved.group.color, theme.colorScheme.onSurfaceVariant);
    expect(resolved.numReadout.fontSize, 68);
  });

  test('lerp 在两端返回对应值', () {
    final a = AppTypography.fromScheme(
      ColorScheme.fromSeed(seedColor: Colors.red),
    );
    final b = AppTypography.fromScheme(
      ColorScheme.fromSeed(seedColor: Colors.red, brightness: Brightness.dark),
    );
    expect(a.lerp(b, 0).group.color, a.group.color);
    expect(a.lerp(b, 1).group.color, b.group.color);
    expect(a.lerp(null, 0.5), same(a));
  });
}
