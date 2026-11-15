import '../../../core/academic/schedule_constants.dart';
import '../../../core/academic/schedule_date_override.dart';
import '../../../core/academic/schedule_model.dart';
import '../../../core/semester/semester_calendar.dart';
import '../../../core/semester/schedule_term_context.dart';

/// 把「某一次课」的 UI 编辑（拖拽移动 / 弹层改时间与地点老师）折算成
/// [ScheduleDateOverride]，供拖拽落点与编辑弹层共用，保证两处写入口径一致。
///
/// 已有 [ScheduleDateOverride] 命中本课程（源周或目标周）时走 `copyWith`：
/// 原课程定位字段（`source*`、`id`、`termContext`）一律保留，只更新
/// `target*` 与 `updatedAt`——「再次编辑已移动的课」仍是同一条 override，
/// 绝不叠加（去重由 `sourceSignature` 承担）。
ScheduleDateOverride buildCourseEditOverride({
  required int week,
  required CourseEntry course,
  required ScheduleDateOverride? existing,
  required int targetWeekday,
  required int targetStartLesson,
  required int targetEndLesson,
  required String targetClassroom,
  required String targetTeacherName,
  ScheduleTermContext? termContext,
  DateTime? updatedAt,
}) {
  final weekStart = SemesterCalendar.instance.weekStartFor(week);
  final sourceDate = weekStart.add(Duration(days: course.weekday - 1));
  final targetDate = weekStart.add(Duration(days: targetWeekday - 1));
  final now = updatedAt ?? DateTime.now();
  if (existing != null) {
    return existing.copyWith(
      targetDate: formatScheduleDate(targetDate),
      targetWeek: week,
      targetWeekday: targetWeekday,
      targetStartLesson: targetStartLesson,
      targetEndLesson: targetEndLesson,
      targetClassroom: targetClassroom.trim(),
      targetTeacherName: targetTeacherName.trim(),
      updatedAt: now,
    );
  }
  return ScheduleDateOverride(
    id: 'manual-${now.microsecondsSinceEpoch}',
    termContext: termContext,
    sourceDate: formatScheduleDate(sourceDate),
    sourceWeek: week,
    sourceWeekday: course.weekday,
    sourceStartLesson: course.startLesson,
    sourceEndLesson: course.endLesson,
    sourceCourseName: course.courseName,
    sourceTeacherName: course.teacherName,
    sourceClassroom: course.classroom,
    targetDate: formatScheduleDate(targetDate),
    targetWeek: week,
    targetWeekday: targetWeekday,
    targetStartLesson: targetStartLesson,
    targetEndLesson: targetEndLesson,
    targetClassroom: targetClassroom.trim(),
    targetTeacherName: targetTeacherName.trim(),
    updatedAt: now,
  );
}

/// `yyyy-MM-dd`，与 [ScheduleDateOverride.sourceDate] / `targetDate` 一致。
String formatScheduleDate(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)}';
}

/// 「周X 第a-b节」：拖拽预览框与日志文案共用。
String scheduleSlotLabel(int weekday, int startLesson, int endLesson) {
  return '周${scheduleWeekdayLabels[weekday - 1]} 第$startLesson'
      '${endLesson == startLesson ? '' : '-$endLesson'}节';
}
