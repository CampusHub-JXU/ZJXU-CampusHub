import 'package:flutter/foundation.dart' show immutable;

import '../core/calendar/calendar_sync_models.dart';
import '../core/semester/schedule_term_context.dart';
import '../core/academic/effective_week_courses.dart';
import '../core/academic/schedule_cache_snapshot.dart';
import '../core/academic/schedule_constants.dart';
import '../core/academic/schedule_model.dart';
// `normalizeCourseName` 由 schedule_service.dart 转出（schedule_change_rule.dart）。
import '../features/schedule/schedule_service.dart';

/// 投影被拒绝的原因（全部 fail closed，调用方据此不做差量删除）。
enum CalendarProjectionFailure {
  /// 未提供非空的正方已验证身份。
  ownerUnverified,

  /// 快照归属与已验证身份不一致。
  ownerMismatch,

  /// 快照学期与已确认当前学期不一致（如上一学期回退快照）。
  termMismatch,

  /// 已确认学期与按 `now` 推算的当前学期不一致。
  termNotCurrent,

  /// 开学日不落在已确认学期（起始日与学期错配）。
  semesterStartMismatch,

  /// 开学日不可信（年份离谱 / 距当前过远 / 已超出本学期教学周范围）。
  semesterStartUnreasonable,

  /// 缺少课表刷新时间或课程为空。
  scheduleMissing,

  /// 课表快照已过期。
  scheduleStale,

  /// 调课规则未按当前学期抓取（`changeRulesCurrentScoped` /
  /// `changeRulesDateAware` 未置位），无法证明没有停课/调课。
  changeRulesUntrusted,

  /// 调课规则缺少刷新时间或已过期。
  changeRulesStale,

  /// 课程结构无法映射（星期/节次/周次/标题/教室非法或超长）。
  invalidCourse,

  /// 课程时间无法确定（节次作息不可解析 / 结束不晚于开始）。
  invalidCourseTime,
}

/// 投影 fail closed 的 typed failure。
///
/// [message] 只含结构性信息（周次/星期/节次），绝不包含学号、课程名或教室，
/// 可直接进入日志。
class CalendarProjectionException implements Exception {
  const CalendarProjectionException(this.reason, this.message);

  final CalendarProjectionFailure reason;
  final String message;

  @override
  String toString() => 'CalendarProjectionException(${reason.name}): $message';
}

/// 单次课程事件投影（每次课一条，不是 RRULE 重复事件）。
///
/// [businessKey] 只允许留在 App 私有内存/账本（[CalendarSyncEventPlan]）；
/// 写进系统日历 `CUSTOM_APP_URI` 的只能是账本批次提供的随机 opaqueId。
@immutable
class ProjectedCourseOccurrence {
  const ProjectedCourseOccurrence({
    required this.businessKey,
    required this.title,
    required this.location,
    required this.week,
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
    required this.startTimeUtc,
    required this.endTimeUtc,
    this.reminderMinutes = defaultReminderMinutes,
  });

  /// 默认课前提醒提前量（分钟）；提醒由系统日历负责，不是 App 闹钟。
  ///
  /// 实际写入值由设置页持久化（`CalendarReminderSettings`，默认 20）经
  /// [projectCurrentTermCalendarEvents] 的 `reminderMinutes` 参数传入。
  static const int defaultReminderMinutes = 20;

  /// 写入系统日历的固定时区 ID（校历作息按北京时间墙钟）。
  static const String timeZoneId = 'Asia/Shanghai';

  /// 只进私有账本的稳定业务键：学期 + 课程 + 教师 + 星期 + 节次 + 周次 + 教室。
  ///
  /// 确定性（同输入必同键）、不含学号、不是 URI，也不是 opaqueId。
  final String businessKey;

  final String title;
  final String location;

  /// 教学周（1–20）。
  final int week;

  /// 星期（1=周一 … 7=周日）。
  final int weekday;

  final int startLesson;
  final int endLesson;

  /// 绝对开始/结束时刻（UTC，设备本地时区无关）。
  final DateTime startTimeUtc;
  final DateTime endTimeUtc;

  final int reminderMinutes;

  int get startMillis => startTimeUtc.millisecondsSinceEpoch;

  int get endMillis => endTimeUtc.millisecondsSinceEpoch;

  /// 映射为平台通道事件；[opaqueId] 必须由账本批次提供，投影绝不生成随机值。
  CalendarSyncEventDraft toEventDraft({required String opaqueId}) {
    return CalendarSyncEventDraft(
      opaqueId: opaqueId,
      title: title,
      location: location,
      startMillis: startMillis,
      endMillis: endMillis,
      reminderMinutes: reminderMinutes,
      timeZone: timeZoneId,
    );
  }

  /// 映射为私有账本计划；同样只接受调用方提供的 [opaqueId]。
  CalendarSyncEventPlan toEventPlan({required String opaqueId}) =>
      CalendarSyncEventPlan(opaqueId: opaqueId, businessKey: businessKey);

  @override
  bool operator ==(Object other) =>
      other is ProjectedCourseOccurrence &&
      other.businessKey == businessKey &&
      other.title == title &&
      other.location == location &&
      other.week == week &&
      other.weekday == weekday &&
      other.startLesson == startLesson &&
      other.endLesson == endLesson &&
      other.startTimeUtc == startTimeUtc &&
      other.endTimeUtc == endTimeUtc &&
      other.reminderMinutes == reminderMinutes;

  @override
  int get hashCode => Object.hash(
    businessKey,
    title,
    location,
    week,
    weekday,
    startLesson,
    endLesson,
    startTimeUtc,
    endTimeUtc,
    reminderMinutes,
  );

  /// 不输出标题/教室（隐私），只留结构性信息。
  @override
  String toString() =>
      'ProjectedCourseOccurrence(week: $week, weekday: $weekday, '
      'lessons: $startLesson-$endLesson, startMillis: $startMillis)';
}

/// 把「已验证当前学期课表快照」投影为系统日历事件（纯函数）。
///
/// 职责与边界：
/// - 只读入调用方已验证的 [snapshot]（正方 owner、已确认当前学期、已校对
///   开学日），不访问网络、不读写系统日历 provider、不读写凭据、不生成随机
///   opaqueId，也不读 `SemesterCalendar` 单例（开学日由参数传入）；
/// - 逐周（1–`scheduleWeekCount`）调用 [buildEffectiveWeekCourses]
///   （纯计算：单双周过滤 + 停课/调课/补课/换教室），把每节课投影为一条绝对
///   时间事件；日期按开学日所在周的周一 + (周次-1)*7 + (星期-1) 校准，因此
///   非周一开学时第 1 周周一的课程不会被丢弃；
/// - 作息走 `ScheduleSlotTimes`，墙钟固定按 Asia/Shanghai（UTC+8）换算为 UTC
///   毫秒，不读取设备时区（旅行改时区不偏移）；
/// - [reminderMinutes] 由调用方（前台协调器读持久化设置）传入，逐条写入事件
///   的课前提醒提前量；默认取 [ProjectedCourseOccurrence.defaultReminderMinutes]
///   （20），本函数不读取设置单例、不做范围裁剪（由设置层消毒）；
/// - 任何无法证明「身份 / 学期 / 开学日 / 快照时效 / 调课规则可信度 / 课程
///   时间」的情况一律 **fail closed**：抛 [CalendarProjectionException]，
///   绝不返回部分结果或空列表——调用方据此不做差量删除，避免少同步后误删；
/// - 单条调课规则若没有可证明的学期（`termContext == null`），与课表
///   「当前课表已体现/未应用」的既有语义一致地**不应用**；本函数不额外放宽。
///
/// 返回结果按 (startMillis, businessKey) 排序且已按 businessKey 稳定去重，
/// 每次课一条，供调用方按账本差量 upsert/delete。
List<ProjectedCourseOccurrence> projectCurrentTermCalendarEvents({
  required ScheduleCacheSnapshot snapshot,
  required String verifiedOwner,
  required ScheduleTermContext confirmedCurrentTerm,
  required DateTime semesterStartDate,
  required DateTime now,
  Duration maxScheduleAge = const Duration(days: 7),
  Duration maxChangeRulesAge = const Duration(days: 1),
  int reminderMinutes = ProjectedCourseOccurrence.defaultReminderMinutes,
}) {
  _verifyIdentity(snapshot: snapshot, verifiedOwner: verifiedOwner);
  _verifyTerm(
    snapshot: snapshot,
    confirmedCurrentTerm: confirmedCurrentTerm,
    now: now,
  );
  final weekOneStart = _resolveWeekOneStart(
    semesterStartDate: semesterStartDate,
    confirmedCurrentTerm: confirmedCurrentTerm,
    now: now,
  );
  _verifyScheduleFreshness(
    snapshot: snapshot,
    now: now,
    maxScheduleAge: maxScheduleAge,
  );
  _verifyChangeRulesTrust(
    snapshot: snapshot,
    now: now,
    maxChangeRulesAge: maxChangeRulesAge,
  );

  // 先对源课表做整体形状校验：即使某门课在 1–20 周内没有任何命中（无法确定
  // 它的日期），也必须整体 fail closed，而不是静默少同步。
  for (final course in snapshot.courses) {
    _validateCourse(course, requireWeekInTerm: true);
  }

  final occurrences = <ProjectedCourseOccurrence>[];
  final seenKeys = <String>{};
  for (var week = 1; week <= scheduleWeekCount; week++) {
    final weekCourses = buildEffectiveWeekCourses(
      courses: snapshot.courses,
      week: week,
      changeRules: snapshot.changeRules,
      dateOverrides: snapshot.dateOverrides,
      termContext: confirmedCurrentTerm,
    );
    for (final course in weekCourses) {
      final occurrence = _projectCourse(
        course: course,
        week: week,
        weekOneStart: weekOneStart,
        termContext: confirmedCurrentTerm,
        reminderMinutes: reminderMinutes,
      );
      // 重复课程按 businessKey 稳定去重：周次递增遍历 + 同周课表顺序固定，
      // 保留先出现的一条；两条同键记录在标题/教室/节次/周次上等价。
      if (seenKeys.add(occurrence.businessKey)) {
        occurrences.add(occurrence);
      }
    }
  }

  occurrences.sort((a, b) {
    final byStart = a.startMillis.compareTo(b.startMillis);
    if (byStart != 0) return byStart;
    return a.businessKey.compareTo(b.businessKey);
  });
  return List<ProjectedCourseOccurrence>.unmodifiable(occurrences);
}

/// Asia/Shanghai 固定偏移（UTC+8，无夏令时）。
const Duration _shanghaiUtcOffset = Duration(hours: 8);

const int _minPlausibleYear = 2000;
const int _maxPlausibleYear = 2100;

/// 今天最多允许早于「第 1 周周一」多少天（开学前提前同步窗口）。
const int _maxPreSemesterLeadDays = 60;

/// 第 20 周结束后的宽限天数；再往后视为开学日已不可信。
const int _maxPostSemesterGraceDays = 14;

const String _businessKeyVersion = 'calendar-course-v1';

/// businessKey 字段分隔符（unit separator，正常课程字段不会包含）。
const String _businessKeySeparator = '\u001F';

void _verifyIdentity({
  required ScheduleCacheSnapshot snapshot,
  required String verifiedOwner,
}) {
  final owner = verifiedOwner.trim();
  if (owner.isEmpty) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.ownerUnverified,
      '缺少已验证的正方身份，拒绝投影',
    );
  }
  final snapshotOwner = snapshot.studentId.trim();
  if (snapshotOwner.isEmpty || snapshotOwner != owner) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.ownerMismatch,
      '快照归属与已验证身份不一致，拒绝投影',
    );
  }
}

void _verifyTerm({
  required ScheduleCacheSnapshot snapshot,
  required ScheduleTermContext confirmedCurrentTerm,
  required DateTime now,
}) {
  if (snapshot.termContext != confirmedCurrentTerm) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.termMismatch,
      '快照学期与已确认当前学期不一致，拒绝投影',
    );
  }
  if (confirmedCurrentTerm != ScheduleTermContext.current(now)) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.termNotCurrent,
      '已确认学期不是按当前日期推算的当前学期，拒绝投影',
    );
  }
}

DateTime _resolveWeekOneStart({
  required DateTime semesterStartDate,
  required ScheduleTermContext confirmedCurrentTerm,
  required DateTime now,
}) {
  final startDay = DateTime.utc(
    semesterStartDate.year,
    semesterStartDate.month,
    semesterStartDate.day,
  );
  if (startDay.year < _minPlausibleYear || startDay.year > _maxPlausibleYear) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.semesterStartUnreasonable,
      '开学日年份不可信，拒绝投影',
    );
  }
  if (ScheduleTermContext.current(startDay) != confirmedCurrentTerm) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.semesterStartMismatch,
      '开学日与已确认学期不一致，拒绝投影',
    );
  }

  // 第 1 教学周的周一：开学日所在周的周一（开学日为周一时即当天）。
  final weekOneStart = startDay.subtract(Duration(days: startDay.weekday - 1));
  final today = DateTime.utc(now.year, now.month, now.day);
  final daysFromWeekOne = today.difference(weekOneStart).inDays;
  if (daysFromWeekOne < -_maxPreSemesterLeadDays) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.semesterStartUnreasonable,
      '开学日距当前过远，尚未进入可投影窗口，拒绝投影',
    );
  }
  if (daysFromWeekOne > scheduleWeekCount * 7 + _maxPostSemesterGraceDays) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.semesterStartUnreasonable,
      '开学日已超出本学期教学周范围，拒绝投影',
    );
  }
  return weekOneStart;
}

void _verifyScheduleFreshness({
  required ScheduleCacheSnapshot snapshot,
  required DateTime now,
  required Duration maxScheduleAge,
}) {
  if (snapshot.scheduleUpdatedAt == null || snapshot.courses.isEmpty) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.scheduleMissing,
      '课表快照缺少刷新时间或课程，拒绝投影',
    );
  }
  if (snapshot.needsScheduleRefresh(now, maxAge: maxScheduleAge)) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.scheduleStale,
      '课表快照已过期，拒绝投影',
    );
  }
}

void _verifyChangeRulesTrust({
  required ScheduleCacheSnapshot snapshot,
  required DateTime now,
  required Duration maxChangeRulesAge,
}) {
  if (!snapshot.changeRulesCurrentScoped || !snapshot.changeRulesDateAware) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.changeRulesUntrusted,
      '调课规则未按当前学期抓取或缺少日期语义，拒绝投影',
    );
  }
  if (snapshot.needsChangeRulesRefresh(now, maxAge: maxChangeRulesAge)) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.changeRulesStale,
      '调课规则缺少刷新时间或已过期，拒绝投影',
    );
  }
}

void _validateCourse(CourseEntry course, {required bool requireWeekInTerm}) {
  final title = course.courseName.trim();
  if (title.isEmpty) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.invalidCourse,
      '课程标题为空，拒绝投影',
    );
  }
  if (title.length > CalendarSyncProtocol.maxTitleLength) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.invalidCourse,
      '课程标题超长，拒绝投影',
    );
  }
  if (course.classroom.trim().length > CalendarSyncProtocol.maxLocationLength) {
    throw const CalendarProjectionException(
      CalendarProjectionFailure.invalidCourse,
      '教室超长，拒绝投影',
    );
  }
  if (course.weekday < 1 || course.weekday > 7) {
    throw CalendarProjectionException(
      CalendarProjectionFailure.invalidCourse,
      '星期 ${course.weekday} 超出 1–7，拒绝投影',
    );
  }
  if (course.startLesson < 1 ||
      course.startLesson > scheduleSlotCount ||
      course.endLesson < course.startLesson ||
      course.endLesson > scheduleSlotCount) {
    throw CalendarProjectionException(
      CalendarProjectionFailure.invalidCourse,
      '节次 ${course.startLesson}-${course.endLesson} 超出 1–$scheduleSlotCount，'
      '拒绝投影',
    );
  }
  if (requireWeekInTerm) {
    if (course.weekRange.trim().isEmpty) {
      throw const CalendarProjectionException(
        CalendarProjectionFailure.invalidCourse,
        '课程缺少周次信息，拒绝投影',
      );
    }
    var matchesTerm = false;
    for (var week = 1; week <= scheduleWeekCount; week++) {
      if (course.isInWeek(week)) {
        matchesTerm = true;
        break;
      }
    }
    if (!matchesTerm) {
      throw CalendarProjectionException(
        CalendarProjectionFailure.invalidCourse,
        '课程周次与 1–$scheduleWeekCount 周无交集，拒绝投影',
      );
    }
  }
}

ProjectedCourseOccurrence _projectCourse({
  required CourseEntry course,
  required int week,
  required DateTime weekOneStart,
  required ScheduleTermContext termContext,
  required int reminderMinutes,
}) {
  _validateCourse(course, requireWeekInTerm: false);

  final startClock = _parseSlotClock(
    ScheduleSlotTimes.startTime(course.startLesson),
    course.startLesson,
  );
  final endClock = _parseSlotClock(
    ScheduleSlotTimes.endTime(course.endLesson),
    course.endLesson,
  );

  final day = weekOneStart.add(
    Duration(days: (week - 1) * 7 + (course.weekday - 1)),
  );
  final startMillis = _shanghaiWallClockMillis(
    day,
    startClock.hour,
    startClock.minute,
  );
  final endMillis = _shanghaiWallClockMillis(
    day,
    endClock.hour,
    endClock.minute,
  );
  if (endMillis <= startMillis) {
    throw CalendarProjectionException(
      CalendarProjectionFailure.invalidCourseTime,
      '第 $week 周 星期${course.weekday} 第 ${course.startLesson}-'
      '${course.endLesson} 节结束时间不晚于开始时间，拒绝投影',
    );
  }

  final businessKey = _buildBusinessKey(
    termContext: termContext,
    course: course,
    week: week,
  );
  if (businessKey.length > CalendarSyncProtocol.maxBusinessKeyLength) {
    throw CalendarProjectionException(
      CalendarProjectionFailure.invalidCourse,
      '第 $week 周 星期${course.weekday} 第 ${course.startLesson}-'
      '${course.endLesson} 节业务键超长，拒绝投影',
    );
  }

  return ProjectedCourseOccurrence(
    businessKey: businessKey,
    title: course.courseName.trim(),
    location: course.classroom.trim(),
    week: week,
    weekday: course.weekday,
    startLesson: course.startLesson,
    endLesson: course.endLesson,
    startTimeUtc: DateTime.fromMillisecondsSinceEpoch(startMillis, isUtc: true),
    endTimeUtc: DateTime.fromMillisecondsSinceEpoch(endMillis, isUtc: true),
    reminderMinutes: reminderMinutes,
  );
}

/// 解析 `ScheduleSlotTimes` 的 `HH:mm`；`??` 或任何非严格格式都 fail closed。
({int hour, int minute}) _parseSlotClock(String raw, int lesson) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
  final hour = match == null ? null : int.tryParse(match.group(1)!);
  final minute = match == null ? null : int.tryParse(match.group(2)!);
  if (hour == null || minute == null || hour > 23 || minute > 59) {
    throw CalendarProjectionException(
      CalendarProjectionFailure.invalidCourseTime,
      '第 $lesson 节作息时间不可解析，拒绝投影',
    );
  }
  return (hour: hour, minute: minute);
}

/// 把 Asia/Shanghai 墙钟（年月日 + 时分）换算为 UTC 毫秒。
///
/// 只用 `DateTime.utc` 构造墙钟再减去固定 +8 偏移：不读取设备本地时区，
/// 设备在任何时区（含旅行改时区）得到同一毫秒值。
int _shanghaiWallClockMillis(DateTime day, int hour, int minute) {
  final wall = DateTime.utc(day.year, day.month, day.day, hour, minute);
  return wall.millisecondsSinceEpoch - _shanghaiUtcOffset.inMilliseconds;
}

String _buildBusinessKey({
  required ScheduleTermContext termContext,
  required CourseEntry course,
  required int week,
}) {
  String field(String value) => value
      .replaceAll(_businessKeySeparator, ' ')
      .replaceAll(RegExp(r'[\r\n\t]'), ' ')
      .trim();

  return <String>[
    _businessKeyVersion,
    termContext.key,
    field(normalizeCourseName(course.courseName)),
    field(course.teacherName),
    '${course.weekday}',
    '${course.startLesson}-${course.endLesson}',
    '$week',
    field(course.classroom),
  ].join(_businessKeySeparator);
}
