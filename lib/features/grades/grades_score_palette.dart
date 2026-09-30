import 'package:flutter/material.dart';

import 'grades_model.dart';

/// 成绩分段语义色（grades feature 私有 token 表）。
///
/// 设计约束：主题色（`colorScheme.primary`，默认嘉大红）是全 App 唯一强调色，
/// 成绩不使用硬编码色，全部从当前 [ColorScheme] 派生：
/// - 分布条（[gradeBandColor]）：优/良/中 为 primary 的透明度梯度
///   （1.0 → 0.6 → 0.35），及格 `outline`，不及格 `error`；
/// - 课程行分数（[gradeScoreColor]）：优 `primary`、不及格 `error`，
///   其余 `onSurface` —— 只给两端着色，中间段不抢视线。
///
/// 随调色板（嘉大红/嘉大蓝/…）与深浅模式自动适配。
enum GradeBand { excellent, good, medium, pass, fail }

extension GradeBandLabel on GradeBand {
  String get label => switch (this) {
    GradeBand.excellent => '优',
    GradeBand.good => '良',
    GradeBand.medium => '中',
    GradeBand.pass => '及格',
    GradeBand.fail => '不及格',
  };
}

/// 百分制分数 → 分段（分布条与课程行共用的唯一口径）。
GradeBand gradeBandForScore(double score) {
  if (score >= 90) return GradeBand.excellent;
  if (score >= 80) return GradeBand.good;
  if (score >= 70) return GradeBand.medium;
  if (score >= 60) return GradeBand.pass;
  return GradeBand.fail;
}

/// 课程可比较的百分制分数：优先 `percentageScore`，其次数值型 `grade`；
/// 等级制且无百分制换算时返回 null。
double? gradeNumericScore(GradeEntry grade) =>
    double.tryParse(grade.percentageScore.trim()) ??
    double.tryParse(grade.grade.trim());

/// 课程 → 分段：数值分数按阈值；等级制按文字（优秀/良好/中等/及格/不及格、
/// 合格/不合格）；无法识别时返回 null（不计入分布，也不着色）。
GradeBand? gradeBandForEntry(GradeEntry grade) {
  final score = gradeNumericScore(grade);
  if (score != null) return gradeBandForScore(score);
  final text = grade.grade.trim();
  if (text.isEmpty) return null;
  if (text.contains('不及格') || text.contains('不合格')) return GradeBand.fail;
  if (text.contains('优')) return GradeBand.excellent;
  if (text.contains('良')) return GradeBand.good;
  if (text.contains('中')) return GradeBand.medium;
  if (text.contains('及格') || text.contains('合格')) return GradeBand.pass;
  return null;
}

/// 分段 → 分布条颜色。
Color gradeBandColor(ColorScheme colorScheme, GradeBand band) => switch (band) {
  GradeBand.excellent => colorScheme.primary,
  GradeBand.good => colorScheme.primary.withValues(alpha: 0.6),
  GradeBand.medium => colorScheme.primary.withValues(alpha: 0.35),
  GradeBand.pass => colorScheme.outline,
  GradeBand.fail => colorScheme.error,
};

/// 分段 → 课程行分数文字颜色（未知分段按普通文字）。
Color gradeScoreColor(ColorScheme colorScheme, GradeBand? band) =>
    switch (band) {
      GradeBand.excellent => colorScheme.primary,
      GradeBand.fail => colorScheme.error,
      _ => colorScheme.onSurface,
    };
