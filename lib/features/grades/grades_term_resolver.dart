import '../schedule/schedule_term_context.dart';
import 'grades_model.dart';

/// 成绩页学期切换的纯逻辑层，便于单元测试且复用 [ScheduleTermContext]。
class GradesTermResolver {
  const GradesTermResolver._();

  /// 「全部学期」聚合选项的固定 key，用于查看所有学期的成绩。
  static const String allTermKey = '__all__';

  /// 成绩中学年学期组合的去重 key：`"$academicYear|$semester"`。
  static String keyOf(GradeEntry g) => '${g.academicYear}|${g.semester}';

  /// 展示用的学期标签：`"$academicYear $semester"`（不再拼接"第…学期"后缀）。
  static String labelOf(String academicYear, String semester) =>
      '$academicYear $semester';

  /// 根据 [ScheduleTermContext.current] 推导当前学期 key。
  static String currentTermKey([DateTime? now]) {
    final ctx = ScheduleTermContext.current(now);
    final yearStr = '${ctx.academicYear}-${ctx.academicYear + 1}';
    return '$yearStr|${ctx.termLabel}';
  }

  /// 从成绩列表中提取去重、排序后的学期组合，最新学期排在最前。
  static List<({String academicYear, String semester})> availableTerms(
    List<GradeEntry> grades,
  ) {
    final seen = <String>{};
    final list = <({String academicYear, String semester})>[];
    for (final g in grades) {
      final key = keyOf(g);
      if (seen.add(key)) {
        list.add((academicYear: g.academicYear, semester: g.semester));
      }
    }
    list.sort((a, b) {
      final yearCmp = b.academicYear.compareTo(a.academicYear);
      if (yearCmp != 0) return yearCmp;
      if (a.semester == '第二学期' && b.semester == '第一学期') return -1;
      if (a.semester == '第一学期' && b.semester == '第二学期') return 1;
      return 0;
    });
    return list;
  }

  /// 选择默认学期：若 [previousKey] 仍可用则保持，否则默认选**最新可用学期**
  ///（即排序后第一个），而非当前学期——用户最关心的是最近出分的结果。
  static String? pickDefault(List<GradeEntry> grades, {String? previousKey}) {
    final terms = availableTerms(grades);
    if (terms.isEmpty) return null;
    final keys = terms.map((t) => '${t.academicYear}|${t.semester}').toSet();
    if (previousKey != null && keys.contains(previousKey)) return previousKey;
    return '${terms.first.academicYear}|${terms.first.semester}';
  }

  /// 按选中的学期 key 过滤成绩。[allTermKey] 表示全部学期。
  static List<GradeEntry> filterByTermKey(
    List<GradeEntry> grades,
    String? key,
  ) {
    if (key == null || key == allTermKey) return grades;
    return grades.where((g) => keyOf(g) == key).toList();
  }
}
