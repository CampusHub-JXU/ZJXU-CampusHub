import 'package:flutter/material.dart';

/// 内容层字号角色（design-guidelines §1.1，docs/ui-unification-plan.md §4.1）。
///
/// 主题 [TextTheme] 只有 11/12/14/16/20… 几档，而内容层最常用的 13 号
/// （标签、次要文字）与 15 号（行标题）以及三档大数字没有对应位置，
/// 于是各页各写 `TextStyle(fontSize: …)`。这里把这些角色集中定义：
///
/// * 颜色随 [ColorScheme] 注入（[AppTypography.fromScheme]），调用方一般
///   直接用，需要强调色时再 `copyWith(color: …)`；
/// * 只给普通 `fontSize`，文字缩放由 `AppTextScaleScope` 在
///   `MediaQuery.textScaler` 层统一生效，不在这里乘倍率；
/// * 字体家族不写：继承 `ThemeData.fontFamily`（打包的 Inter 子集，中文
///   回退系统字体）。
///
/// 访问：`context.appText.label`。未注册扩展（如测试里的裸 `MaterialApp`）
/// 时按当前 [ColorScheme] 现算一份，不会抛错。
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.label,
    required this.listTitle,
    required this.rowTitle,
    required this.secondary,
    required this.meta,
    required this.tag,
    required this.readout,
    required this.overview,
    required this.rowValue,
    required this.unit,
  });

  factory AppTypography.fromScheme(ColorScheme cs) {
    const tabular = [FontFeature.tabularFigures()];
    return AppTypography(
      label: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
      listTitle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: cs.onSurface,
      ),
      rowTitle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      secondary: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.3,
        color: cs.onSurfaceVariant,
      ),
      meta: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.35,
        color: cs.onSurfaceVariant,
      ),
      tag: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: cs.onSurfaceVariant,
      ),
      readout: TextStyle(
        fontSize: 76,
        fontWeight: FontWeight.w700,
        height: 1.05,
        letterSpacing: -2.5,
        color: cs.onSurface,
        fontFeatures: tabular,
      ),
      overview: TextStyle(
        fontSize: 48,
        fontWeight: FontWeight.w600,
        height: 1.1,
        letterSpacing: -1,
        color: cs.onSurface,
        fontFeatures: tabular,
      ),
      rowValue: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.1,
        color: cs.onSurface,
        fontFeatures: tabular,
      ),
      unit: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  /// 13 w600 灰：数字上方的标签行、分组标题（`PlainSectionHeader`）。
  final TextStyle label;

  /// 16 w400：B 型分组列表行标题（设置风格，`PlainListRow`）。
  final TextStyle listTitle;

  /// 15 w600：数据页行标题、`DetailActionGrid` 标题。
  final TextStyle rowTitle;

  /// 13 w400 灰：次要文字、行副标题、横幅文字。
  final TextStyle secondary;

  /// 12 灰：元信息（「4 学分 · 考试」）、状态行、动作副标题。
  final TextStyle meta;

  /// 11 w600：状态标签 / 小徽标。
  final TextStyle tag;

  /// 76 w700 等宽：单值详情页主读数（`DetailReadout`）。
  final TextStyle readout;

  /// 48 w600 等宽：多指标页的主指标（成绩 GPA）。
  final TextStyle overview;

  /// 24 w700 等宽：列表行右侧关键值（成绩）。
  final TextStyle rowValue;

  /// 22 w600 灰：写在读数后的单位（「元」「度」）。
  final TextStyle unit;

  @override
  AppTypography copyWith({
    TextStyle? label,
    TextStyle? listTitle,
    TextStyle? rowTitle,
    TextStyle? secondary,
    TextStyle? meta,
    TextStyle? tag,
    TextStyle? readout,
    TextStyle? overview,
    TextStyle? rowValue,
    TextStyle? unit,
  }) {
    return AppTypography(
      label: label ?? this.label,
      listTitle: listTitle ?? this.listTitle,
      rowTitle: rowTitle ?? this.rowTitle,
      secondary: secondary ?? this.secondary,
      meta: meta ?? this.meta,
      tag: tag ?? this.tag,
      readout: readout ?? this.readout,
      overview: overview ?? this.overview,
      rowValue: rowValue ?? this.rowValue,
      unit: unit ?? this.unit,
    );
  }

  @override
  AppTypography lerp(covariant AppTypography? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return AppTypography(
      label: l(label, other.label),
      listTitle: l(listTitle, other.listTitle),
      rowTitle: l(rowTitle, other.rowTitle),
      secondary: l(secondary, other.secondary),
      meta: l(meta, other.meta),
      tag: l(tag, other.tag),
      readout: l(readout, other.readout),
      overview: l(overview, other.overview),
      rowValue: l(rowValue, other.rowValue),
      unit: l(unit, other.unit),
    );
  }
}

extension AppTypographyContext on BuildContext {
  /// 当前主题的 [AppTypography]；未注册时按当前 [ColorScheme] 现算。
  AppTypography get appText {
    final theme = Theme.of(this);
    return theme.extension<AppTypography>() ??
        AppTypography.fromScheme(theme.colorScheme);
  }
}
