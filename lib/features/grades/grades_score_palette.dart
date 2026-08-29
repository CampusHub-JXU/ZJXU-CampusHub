import 'package:flutter/material.dart';

/// 成绩分段语义色（grades feature 私有 token 表）。
///
/// 设计约束：主题色（`colorScheme.primary`，默认嘉大红）是全 App 唯一强调色，
/// 成绩不再使用硬编码的 Material 蓝/绿/橙红，而是：
/// - 及格分段（优/良/中/及格）：以 primary 为基色的 HSL 深浅梯度 ——
///   分数越高 accent 越浓，越低越浅、饱和度越低（浅色下向浅褪，
///   深色下向暗收，保证两套主题都可读）；
/// - 不及格：走 `colorScheme.error` 语义色，并校准亮度/饱和度，
///   保证在深浅两套主题下都与「优」的 accent 梯度可区分。
///
/// 所有颜色均从当前 [ColorScheme] 派生，随调色板（嘉大红/嘉大蓝/…）与
/// 深浅模式自动适配；深浅两套在 `grades_score_palette_test.dart` 与
/// 页面测试中验证。
enum GradeBand { excellent, good, medium, pass, fail }

/// 百分制分数 → 分段（分布卡与成绩卡共用的唯一口径）。
GradeBand gradeBandForScore(double score) {
  if (score >= 90) return GradeBand.excellent;
  if (score >= 80) return GradeBand.good;
  if (score >= 70) return GradeBand.medium;
  if (score >= 60) return GradeBand.pass;
  return GradeBand.fail;
}

/// 分段 → 语义色。
Color gradeBandColor(ColorScheme colorScheme, GradeBand band) {
  if (band == GradeBand.fail) return _failColor(colorScheme);
  return _passColor(colorScheme, band);
}

/// 按分数直接取分段语义色的便捷入口。
Color gradeBandColorForScore(ColorScheme colorScheme, double score) =>
    gradeBandColor(colorScheme, gradeBandForScore(score));

/// 及格分段：primary 基色的深浅梯度。
///
/// `(lightnessDelta, saturationScale)` 描述各分段相对 primary 的偏移；
/// 亮度钳制在深浅两套下分别保证：浅色不过暗（seed 本身偏深时仍可读）、
/// 深色不过亮（tone 80 primary 偏亮时梯度仍然单调）。
Color _passColor(ColorScheme colorScheme, GradeBand band) {
  final isDark = colorScheme.brightness == Brightness.dark;
  final base = HSLColor.fromColor(colorScheme.primary);

  final (lightnessDelta, saturationScale) = switch (band) {
    GradeBand.excellent => (0.0, 1.0),
    GradeBand.good => (isDark ? -0.08 : 0.08, 0.95),
    GradeBand.medium => (isDark ? -0.15 : 0.15, 0.85),
    GradeBand.pass => (isDark ? -0.22 : 0.22, 0.72),
    // fail 在 gradeBandColor 中提前走 error 分支，仅为穷举兜底。
    GradeBand.fail => (0.0, 1.0),
  };

  final lightness = (base.lightness + lightnessDelta).clamp(
    isDark ? 0.52 : 0.30,
    isDark ? 0.86 : 0.58,
  );

  return base
      .withLightness(lightness)
      .withSaturation((base.saturation * saturationScale).clamp(0.0, 1.0))
      .toColor();
}

/// 不及格：error 语义色 + 亮度校准。
///
/// 酒红主题下 primary 与 error 色相接近，这里强制错开亮度：
/// 浅色模式比 primary 亮（更刺眼的警示红），深色模式比 primary 暗且
/// 保持高饱和（暗背景上依然醒目），避免「优」与「不及格」混淆。
Color _failColor(ColorScheme colorScheme) {
  final isDark = colorScheme.brightness == Brightness.dark;
  final error = HSLColor.fromColor(colorScheme.error);
  final lightness = isDark ? 0.62 : error.lightness.clamp(0.50, 0.58);

  return error
      .withSaturation(error.saturation.clamp(0.60, 1.0))
      .withLightness(lightness)
      .toColor();
}
