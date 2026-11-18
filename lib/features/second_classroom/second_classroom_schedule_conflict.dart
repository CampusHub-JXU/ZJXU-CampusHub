import '../../core/academic/schedule_model.dart';

List<String> secondClassroomScheduleConflicts({
  required DateTime? activityStart,
  required DateTime? activityEnd,
  required DateTime semesterStart,
  required Iterable<CourseEntry> courses,
}) {
  if (activityStart == null ||
      activityEnd == null ||
      !activityEnd.isAfter(activityStart)) {
    return [];
  }
  final firstDay = DateTime(
    semesterStart.year,
    semesterStart.month,
    semesterStart.day,
  );
  final monday = firstDay.subtract(Duration(days: firstDay.weekday - 1));
  final names = <String>{};
  for (final course in courses) {
    if (course.weekday < 1 ||
        course.weekday > 7 ||
        course.startLesson > course.endLesson) {
      continue;
    }
    final startParts = ScheduleSlotTimes.startTime(course.startLesson)
        .split(':');
    final endParts = ScheduleSlotTimes.endTime(course.endLesson).split(':');
    if (startParts.length != 2 || endParts.length != 2) continue;
    final sh = int.tryParse(startParts[0]);
    final sm = int.tryParse(startParts[1]);
    final eh = int.tryParse(endParts[0]);
    final em = int.tryParse(endParts[1]);
    if (sh == null || sm == null || eh == null || em == null) continue;
    for (var week = 1; week <= 20; week++) {
      if (!course.isInWeek(week)) continue;
      final day = monday.add(
        Duration(days: (week - 1) * 7 + course.weekday - 1),
      );
      final start = DateTime(day.year, day.month, day.day, sh, sm);
      final end = DateTime(day.year, day.month, day.day, eh, em);
      if (start.isBefore(activityEnd) && activityStart.isBefore(end)) {
        names.add(course.courseName);
      }
    }
  }
  return names.toList();
}
