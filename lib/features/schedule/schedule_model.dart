class CourseEntry {
  const CourseEntry({
    required this.courseName,
    required this.teacherName,
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
    required this.weekRange,
    required this.classroom,
    required this.campus,
    required this.typeSymbol,
  });

  final String courseName;
  final String teacherName;
  final int weekday;      // 1=Mon … 7=Sun
  final int startLesson;
  final int endLesson;
  final String weekRange; // e.g. "1-9周,11-16周"
  final String classroom;
  final String campus;
  final String typeSymbol; // ◆★□●◇

  /// 判断课程是否在指定周次
  bool isInWeek(int week) {
    // weekRange 格式: "1-9周,11-16周" 或 "1-16周"
    final ranges = weekRange.replaceAll('周', '').split(',');
    for (final range in ranges) {
      final parts = range.trim().split('-');
      if (parts.length == 2) {
        final start = int.tryParse(parts[0]) ?? 0;
        final end = int.tryParse(parts[1]) ?? 0;
        if (week >= start && week <= end) return true;
      } else if (parts.length == 1) {
        final single = int.tryParse(parts[0]) ?? 0;
        if (week == single) return true;
      }
    }
    return false;
  }

  factory CourseEntry.fromJson(Map<String, dynamic> json) {
    final jcs = (json['jcs'] as String? ?? '1-1');
    final parts = jcs.split('-');
    final start = int.tryParse(parts.first.trim()) ?? 1;
    final end = int.tryParse(parts.last.trim()) ?? start;
    return CourseEntry(
      courseName: json['kcmc'] as String? ?? '',
      teacherName: json['xm'] as String? ?? '',
      weekday: int.tryParse(json['xqj'] as String? ?? '1') ?? 1,
      startLesson: start,
      endLesson: end,
      weekRange: json['zcd'] as String? ?? '',
      classroom: json['cdmc'] as String? ?? '',
      campus: json['xqmc'] as String? ?? '',
      typeSymbol: json['xslxbj'] as String? ?? '',
    );
  }
}
