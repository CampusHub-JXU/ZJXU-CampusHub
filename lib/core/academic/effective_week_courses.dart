import '../semester/schedule_term_context.dart';
import 'schedule_change_rule.dart';
import 'schedule_date_override.dart';
import 'schedule_model.dart';

/// 按周计算「有效课程」：权威课表 + 调课通知规则 + 用户特定日期编辑
/// （纯函数，无 IO / 无状态）。
///
/// 由课表页、首页聚合与课表日历投影共用；原为 `ScheduleService` 的实例方法。
///
/// [dateOverrides] 是用户对「某一次课」的本地编辑（移动时间 / 改教室 /
/// 改老师）：源周里命中 [ScheduleDateOverride.matchesSource] 的原课程被移除，
/// 目标周里按目标槽位合成一条 `hasScheduleChange = true` 的课程。
/// `ScheduleDateOverride.termContext` 为 null 时随调用方给定的学期生效。
List<CourseEntry> buildEffectiveWeekCourses({
  required List<CourseEntry> courses,
  required int week,
  List<CourseChangeRule> changeRules = const [],
  List<ScheduleDateOverride> dateOverrides = const [],
  ScheduleTermContext? termContext,
}) {
  final applicableRules = changeRules.where(
    (rule) =>
        rule.termContext != null &&
        (termContext == null || rule.termContext == termContext) &&
        !_isProtectedByAuthoritativeCourse(rule, courses),
  );
  final applicableOverrides = dateOverrides.where(
    (override) =>
        termContext == null ||
        override.termContext == null ||
        override.termContext == termContext,
  );
  final effectiveCourses = courses
      .where((course) => course.isInWeek(week))
      .where(
        (course) =>
            course.fromLabSchedule ||
            !applicableRules.any((rule) => rule.removesCourse(course, week)),
      )
      .where(
        (course) => !applicableOverrides.any(
          (override) => override.matchesSource(week, course),
        ),
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

  for (final override in applicableOverrides) {
    if (override.targetWeek != week) continue;
    effectiveCourses.add(
      _buildOverrideCourse(override: override, week: week, courses: courses),
    );
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
      course.typeSymbol,
      course.courseCode,
      course.labProject,
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

  // 附表已排到通知目标槽时，无需再造一张相同的调课卡片。
  final name = rule.courseName?.trim() ?? '';
  final teacher = rule.teacherName?.trim() ?? '';
  if (name.isNotEmpty &&
      courses.any(
        (course) =>
            course.fromLabSchedule &&
            course.isInWeek(week) &&
            course.weekday == targetLesson.weekday &&
            course.startLesson == targetLesson.startLesson &&
            course.endLesson == targetLesson.endLesson &&
            matchesCourseName(course.courseName, name) &&
            (teacher.isEmpty || teacher == course.teacherName.trim()),
      )) {
    return null;
  }
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

/// 为一条用户特定日期编辑合成目标周的展示课程。
///
/// 课名始终沿用源课名（编辑不换课）；教室 / 老师取编辑后的目标值。
/// `hasScheduleChange = true` 沿用权威调课课程的既有视觉语义（UI 标「调」），
/// 用户的移动编辑本质就是一次本地调课。校区 / 类型标记从源原课程继承；
/// 找不到原课程模板时留空（编辑仍可生效，只是丢失校区 / 类型徽标）。
CourseEntry _buildOverrideCourse({
  required ScheduleDateOverride override,
  required int week,
  required List<CourseEntry> courses,
}) {
  final template = _findOverrideTemplateCourse(override, courses);
  return CourseEntry(
    courseName: override.sourceCourseName,
    teacherName: override.targetTeacherName,
    weekday: override.targetWeekday,
    startLesson: override.targetStartLesson,
    endLesson: override.targetEndLesson,
    weekRange: '$week周',
    classroom: override.targetClassroom,
    campus: template?.campus ?? '',
    typeSymbol: template?.typeSymbol ?? '',
    courseCode: template?.courseCode ?? '',
    labProject: template?.labProject ?? '',
    fromLabSchedule: template?.fromLabSchedule ?? false,
    hasScheduleChange: true,
  );
}

/// 在权威课表中定位 override 的「原课程」，供合成课程继承校区 / 类型。
CourseEntry? _findOverrideTemplateCourse(
  ScheduleDateOverride override,
  List<CourseEntry> courses,
) {
  for (final course in courses) {
    if (override.matchesSource(override.sourceWeek, course)) {
      return course;
    }
  }
  return null;
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
