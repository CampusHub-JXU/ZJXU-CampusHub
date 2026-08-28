/// 学年学期上下文。
///
/// `academicYear` 为学年的起始年份（如 2025-2026 学年记为 2025）；
/// `term` 使用正方教务的学期代码：3 为第一学期，12 为第二学期。
class ScheduleTermContext {
  const ScheduleTermContext({required this.academicYear, required this.term});

  final int academicYear;
  final int term;

  /// 按日期推算当前学期（启发式，仅作教务系统解析失败时的兜底）：
  /// 8 月-次年 1 月为第一学期，2 月-7 月为第二学期。
  factory ScheduleTermContext.current([DateTime? now]) {
    final date = now ?? DateTime.now();
    return ScheduleTermContext(
      academicYear: date.month < 8 ? date.year - 1 : date.year,
      term: date.month >= 2 && date.month < 8 ? 12 : 3,
    );
  }

  String get key => '$academicYear-$term';

  String get termLabel => term == 12 ? '第二学期' : '第一学期';

  /// 上一个学期：`(2025, 3)` -> `(2024, 12)`；`(2025, 12)` -> `(2025, 3)`。
  ScheduleTermContext previous() {
    if (term == 12) {
      return ScheduleTermContext(academicYear: academicYear, term: 3);
    }
    return ScheduleTermContext(academicYear: academicYear - 1, term: 12);
  }

  ScheduleTermContext copyWith({int? academicYear, int? term}) {
    return ScheduleTermContext(
      academicYear: academicYear ?? this.academicYear,
      term: term ?? this.term,
    );
  }

  Map<String, dynamic> toJson() => {'academicYear': academicYear, 'term': term};

  factory ScheduleTermContext.fromJson(Map<String, dynamic> json) {
    return ScheduleTermContext(
      academicYear: json['academicYear'] as int? ?? 0,
      term: json['term'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleTermContext &&
      other.academicYear == academicYear &&
      other.term == term;

  @override
  int get hashCode => Object.hash(academicYear, term);

  @override
  String toString() => 'ScheduleTermContext($academicYear-$term)';
}
