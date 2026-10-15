import 'notice_model.dart';

/// 通知与用户年级的相关性判定（纯函数，供展示层排序沉底使用）。
///
/// 规则保守、宁多勿漏：仅当标题**明确点名年级**（如「2024级」）且与用户
/// 入学年级冲突，或提及的学年全部在用户入学之前结束（回顾性通知，如
/// 旧学年缓补考安排）时，才判为不相关。选课、教学安排等面向全体的
/// 通知不含这些标记，一律保持可见。
class NoticeRelevance {
  NoticeRelevance._();

  /// 「级」的匹配按连写整段取（「2024级」「2023、2024级」）：
  /// 顿号/斜杠列举的末位带「级」时，列举中每个年份都是点名年级。
  static final RegExp _cohortPattern = RegExp(
    '(20\\d{2}(?:\\s*[、,，/]\\s*20\\d{2})*)\\s*级',
  );
  static final RegExp _yearTokenPattern = RegExp('20\\d{2}');
  static final RegExp _academicYearPattern = RegExp(
    '(20\\d{2})\\s*[-—~至]\\s*(20\\d{2})\\s*学年',
  );

  /// 从学号推断入学年份：取开头的 20XX（2000–2035 视为合理）。
  /// 学号不含年份前缀时返回 null（此时年级未知，通知相关性 fail-open）。
  static int? inferEnrollmentYearFromId(String id) {
    final match = RegExp(r'^(20\d{2})').firstMatch(id.trim());
    if (match == null) return null;
    final year = int.tryParse(match.group(1) ?? '');
    if (year == null || year < 2000 || year > 2035) return null;
    return year;
  }

  /// 标题中明确点名的年级集合（「2024级」「2023、2024级」）。
  static Set<int> extractCohortYears(String title) => {
    for (final match in _cohortPattern.allMatches(title)) //
      ..._yearTokenPattern
          .allMatches(match.group(1)!)
          .map((token) => int.parse(token.group(0)!)),
  };

  /// 标题中提及学年的结束年份集合（「2025-2026学年」→ {2026}）。
  static Set<int> extractAcademicYearEnds(String title) => {
    for (final match in _academicYearPattern.allMatches(title)) //
      int.parse(match.group(2)!),
  };

  /// 该通知是否与入学年级 [enrollmentYear] 的用户相关。
  /// 年级未知时一律视为相关（不做任何下沉）。
  static bool isRelevant(Notice notice, int? enrollmentYear) {
    if (enrollmentYear == null) return true;
    final cohorts = extractCohortYears(notice.title);
    if (cohorts.isNotEmpty) return cohorts.contains(enrollmentYear);
    final academicEnds = extractAcademicYearEnds(notice.title);
    if (academicEnds.isNotEmpty &&
        academicEnds.every((end) => end < enrollmentYear)) {
      // 所有提及学年都在入学前结束：与本用户无关的回顾性通知。
      return false;
    }
    return true;
  }

  /// 排序：相关优先、组内按日期倒序（缺日期沉底），不相关整体沉底
  /// （不打丢，需要时下滑仍可见）。
  static List<Notice> orderByRelevanceThenDate(
    List<Notice> notices,
    int? enrollmentYear,
  ) {
    final dated = Notice.sortByDateDescStable(notices);
    if (enrollmentYear == null) return dated;
    final relevant = <Notice>[];
    final others = <Notice>[];
    for (final notice in dated) {
      if (isRelevant(notice, enrollmentYear)) {
        relevant.add(notice);
      } else {
        others.add(notice);
      }
    }
    return [...relevant, ...others];
  }
}
