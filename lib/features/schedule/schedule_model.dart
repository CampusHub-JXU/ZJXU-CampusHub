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
