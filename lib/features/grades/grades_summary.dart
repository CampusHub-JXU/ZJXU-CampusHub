import 'grades_model.dart';
import 'grades_score_palette.dart';

/// 成绩概览统计（口径与旧 `_buildStatsRow` 一致）：
/// - [gpa]：`gpaPoints > 0` 课程的学分加权平均；
/// - [credits]：这些课程的学分和；
/// - [averageScore]：数值型 `percentageScore` 的算术平均，没有时为 null；
/// - [courseCount]：课程总数（含等级制 / 未计绩点课程）。
class GradesSummary {
  const GradesSummary({
    required this.gpa,
    required this.credits,
    required this.averageScore,
    required this.courseCount,
    required this.bandCounts,
  });

  final double gpa;
  final double credits;
  final double? averageScore;
  final int courseCount;

  /// 各分段课程数（固定 优→不及格 顺序，含 0）；无法识别分段的课程不计入。
  final Map<GradeBand, int> bandCounts;
}

GradesSummary computeGradesSummary(List<GradeEntry> grades) {
  double totalPoints = 0;
  double totalCredits = 0;
  double scoreSum = 0;
  var scoreCount = 0;
  final bandCounts = {for (final band in GradeBand.values) band: 0};
  for (final g in grades) {
    if (g.gpaPoints > 0) {
      totalPoints += g.gpaPoints * g.credits;
      totalCredits += g.credits;
    }
    final score = double.tryParse(g.percentageScore);
    if (score != null) {
      scoreSum += score;
      scoreCount++;
    }
    final band = gradeBandForEntry(g);
    if (band != null) bandCounts[band] = bandCounts[band]! + 1;
  }
  return GradesSummary(
    gpa: totalCredits > 0 ? totalPoints / totalCredits : 0,
    credits: totalCredits,
    averageScore: scoreCount > 0 ? scoreSum / scoreCount : null,
    courseCount: grades.length,
    bandCounts: bandCounts,
  );
}

/// 课程列表排序方式（纯前端本地状态，不落盘）。
enum GradesSortMode { score, term, credits }

extension GradesSortModeLabel on GradesSortMode {
  String get label => switch (this) {
    GradesSortMode.score => '按成绩 ↓',
    GradesSortMode.term => '按学期',
    GradesSortMode.credits => '按学分',
  };

  GradesSortMode get next =>
      GradesSortMode.values[(index + 1) % GradesSortMode.values.length];
}

/// 稳定排序：同键保持教务返回的原始顺序。
List<GradeEntry> sortGrades(List<GradeEntry> grades, GradesSortMode mode) {
  final indexed = grades.indexed.toList();
  int byOriginal((int, GradeEntry) a, (int, GradeEntry) b) =>
      a.$1.compareTo(b.$1);
  switch (mode) {
    case GradesSortMode.score:
      double key(GradeEntry g) =>
          gradeNumericScore(g) ?? _bandRank(gradeBandForEntry(g));
      indexed.sort((a, b) {
        final c = key(b.$2).compareTo(key(a.$2));
        return c != 0 ? c : byOriginal(a, b);
      });
    case GradesSortMode.credits:
      indexed.sort((a, b) {
        final c = b.$2.credits.compareTo(a.$2.credits);
        return c != 0 ? c : byOriginal(a, b);
      });
    case GradesSortMode.term:
      int termRank(GradeEntry g) => g.semester == '第二学期'
          ? 2
          : g.semester == '第一学期'
          ? 1
          : 0;
      indexed.sort((a, b) {
        final y = b.$2.academicYear.compareTo(a.$2.academicYear);
        if (y != 0) return y;
        final t = termRank(b.$2).compareTo(termRank(a.$2));
        return t != 0 ? t : byOriginal(a, b);
      });
  }
  return [for (final e in indexed) e.$2];
}

/// 等级制课程在「按成绩」排序中的等效分（分段中点；未知排最后）。
double _bandRank(GradeBand? band) => switch (band) {
  GradeBand.excellent => 95,
  GradeBand.good => 85,
  GradeBand.medium => 75,
  GradeBand.pass => 65,
  GradeBand.fail => 30,
  null => -1,
};
