import '../semester/schedule_term_context.dart';
import 'schedule_change_rule.dart';
import 'schedule_model.dart';

/// 按周计算「有效课程」：权威课表 + 调课通知规则（纯函数，无 IO / 无状态）。
///
/// 由课表页、首页聚合与课表日历投影共用；原为 `ScheduleService` 的实例方法。
List<CourseEntry> buildEffectiveWeekCourses({
  required List<CourseEntry> courses,
  required int week,
  List<CourseChangeRule> changeRules = const [],
  ScheduleTermContext? termContext,
}) {
  final applicableRules = changeRules.where(
    (rule) =>
        rule.termContext != null &&
        (termContext == null || rule.termContext == termContext) &&
        !_isProtectedByAuthoritativeCourse(rule, courses),
  );
  final effectiveCourses = courses
      .where((course) => course.isInWeek(week))
      .where(
        (course) =>
            !applicableRules.any((rule) => rule.removesCourse(course, week)),
      )
      .toList();

  for (final rule in applicableRules.where(
    (rule) => rule.addsCourseToWeek(week),
  )) {
    final syntheticCourse = _buildSyntheticCourse(
      rule: rule,
      week: week,
      courses: courses,
    );
    if (syntheticCourse != null) {
      effectiveCourses.add(syntheticCourse);
    }
  }

  final deduped = <CourseEntry>[];
  final seen = <String>{};
  for (final course in effectiveCourses) {
    final signature = [
      course.courseName,
      course.teacherName,
      course.weekday,
      course.startLesson,
      course.endLesson,
      course.classroom,
      course.weekRange,
    ].join('|');
    if (seen.add(signature)) {
      deduped.add(course);
    }
  }

  return deduped;
}

bool _isProtectedByAuthoritativeCourse(
  CourseChangeRule rule,
  List<CourseEntry> courses,
) {
  final lesson = rule.targetLesson ?? rule.originalLesson;
  if (lesson == null) return false;

  // 即使通知只覆盖了部分节次，权威课表的调课标记也不能被通知反向覆盖。
  for (final course in courses) {
    if (!course.hasScheduleChange || !course.isInWeek(lesson.week)) {
      continue;
    }
    if (course.weekday != lesson.weekday ||
        !lesson.overlaps(course) ||
        !matchesCourseName(course.courseName, rule.courseName ?? '')) {
      continue;
    }
    final teacher = rule.teacherName?.trim() ?? '';
    if (teacher.isEmpty || course.teacherName.trim() == teacher) return true;
  }
  return false;
}

CourseEntry? _buildSyntheticCourse({
  required CourseChangeRule rule,
  required int week,
  required List<CourseEntry> courses,
}) {
  final targetLesson = rule.targetLesson;
  if (targetLesson == null || targetLesson.week != week) return null;

  final template = _findTemplateCourse(rule, courses);
  final courseName = (rule.courseName?.trim().isNotEmpty ?? false)
      ? rule.courseName!.trim()
      : template?.courseName ?? '调课课程';
  final teacherName = (rule.teacherName?.trim().isNotEmpty ?? false)
      ? rule.teacherName!.trim()
      : template?.teacherName ?? '';
  final classroom = (rule.classroom?.trim().isNotEmpty ?? false)
      ? rule.classroom!.trim()
      : template?.classroom ?? '';

  return CourseEntry(
    courseName: courseName,
    teacherName: teacherName,
    weekday: targetLesson.weekday,
    startLesson: targetLesson.startLesson,
    endLesson: targetLesson.endLesson,
    weekRange: '$week周',
    classroom: classroom,
    campus: template?.campus ?? '',
    typeSymbol: template?.typeSymbol ?? '',
  );
}

CourseEntry? _findTemplateCourse(
  CourseChangeRule rule,
  List<CourseEntry> courses,
) {
  final lesson = rule.originalLesson;
  final ruleCourseName = rule.courseName?.trim() ?? '';

  if (lesson != null) {
    for (final course in courses) {
      if (!course.isInWeek(lesson.week) || !lesson.overlaps(course)) {
        continue;
      }
      if (ruleCourseName.isEmpty ||
          matchesCourseName(course.courseName, ruleCourseName)) {
        return course;
      }
    }
  }

  if (ruleCourseName.isNotEmpty) {
    for (final course in courses) {
      if (matchesCourseName(course.courseName, ruleCourseName)) {
        return course;
      }
    }
  }

  return null;
}
