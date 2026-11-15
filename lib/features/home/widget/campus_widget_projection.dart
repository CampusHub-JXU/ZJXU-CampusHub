import '../../../core/academic/effective_week_courses.dart';
import '../../../core/academic/exam_model.dart';
import '../../../core/academic/schedule_change_rule.dart';
import '../../../core/academic/schedule_date_override.dart';
import '../../../core/academic/schedule_model.dart';
import '../../../core/notice/notice_model.dart';
import '../../../core/notice/notice_sync_store.dart';
import '../../../core/semester/china_public_holidays.dart';
import '../../../core/semester/semester_calendar.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/theme/personalization_controller.dart';
import '../campus_snapshot_coordinator.dart';
import '../home_presentation_resolver.dart';
import '../models/home_presentation.dart';
import '../models/home_snapshot.dart';
import 'campus_widget_accent.dart';

/// 快照 schema 版本（`docs/desktop-widget-v2.md` §2）。
const campusWidgetSchemaVersion = 2;

/// 快照里的天数（今天 + 之后 6 天）。
const campusWidgetDayCount = 7;

/// 近期考试 / 通知条数上限。
const campusWidgetListLimit = 5;

/// 无课表可展示时的整体状态（序列化为枚举名）。
enum CampusWidgetEmptyState {
  notLoggedIn,
  noCache,
  beforeSemester,
  afterSemester;

  String get text => switch (this) {
    notLoggedIn => '登录教务后显示课表',
    noCache => '打开 App 加载课表',
    beforeSemester => '开学后显示课表',
    afterSemester => '本学期课程已结束',
  };
}

/// 桌面组件展示投影（PRD §12/§13；v2 见 `docs/desktop-widget-v2.md` §2）。
///
/// 只包含展示文本与时间戳，**不含任何凭据 / 学号 / 姓名**；由 CampusSnapshot
/// 派生，Home、Widget、系统入口共享同一份数据。v1 兼容字段（heroHeadline …
/// unreadNoticeCount）原样保留，供旧原生实现读取。
class CampusWidgetProjection {
  const CampusWidgetProjection({
    required this.generatedAt,
    required this.weekLabel,
    required this.heroHeadline,
    required this.todayCourses,
    required this.hasTodayCourses,
    this.todayTitle = '今天',
    this.heroTimeText,
    this.heroCourseName,
    this.heroLocationText,
    this.nextExamCourseName,
    this.nextExamTimeText,
    this.nextExamLocationText,
    required this.campusCardBalance,
    required this.hasCampusCardData,
    required this.dormElectricity,
    required this.hasElectricityData,
    required this.unreadNoticeCount,
    this.emptyState,
    this.days = const [],
    this.exams = const [],
    this.campusCardLow = false,
    this.electricityLow = false,
    this.noticeItems = const [],
    this.accentLight,
    this.accentDark,
  });

  final DateTime generatedAt;
  final String weekLabel;

  final String heroHeadline;
  final String? heroTimeText;
  final String? heroCourseName;
  final String? heroLocationText;

  /// 今日课程：[{timeText, courseName, locationText, isOngoing}]
  final List<Map<String, Object?>> todayCourses;
  final bool hasTodayCourses;

  /// 今日课程段标题：'今天'，或次日预览形态的 '明天' / '开学首日'（原生中组件据此命名）。
  final String todayTitle;

  final String? nextExamCourseName;
  final String? nextExamTimeText;
  final String? nextExamLocationText;

  final String campusCardBalance;
  final bool hasCampusCardData;
  final String dormElectricity;
  final bool hasElectricityData;

  final int unreadNoticeCount;

  // —— v2 ——

  /// null = 正常；其余见 [CampusWidgetEmptyState]。
  final CampusWidgetEmptyState? emptyState;

  /// 从今天起连续 7 天（含无课日）：
  /// `{date, weekLabel, holidayName, courses: [...]}`。
  final List<Map<String, Object?>> days;

  /// 未结束的考试（≤5，按开始时间升序）。
  final List<Map<String, Object?>> exams;

  final bool campusCardLow;
  final bool electricityLow;

  /// 最新通知（≤5）：`{title, publishedAt}`。
  final List<Map<String, Object?>> noticeItems;

  /// `#RRGGBB`；为 null 时快照不带 `theme`（原生沿用已保存值）。
  final String? accentLight;
  final String? accentDark;

  Map<String, Object?> toMap() => {
    'schemaVersion': campusWidgetSchemaVersion,
    'generatedAt': formatCampusWidgetDateTime(generatedAt),
    'emptyState': emptyState?.name,
    'emptyStateText': emptyState?.text,
    'weekLabel': weekLabel,
    'days': days,
    'exams': exams,
    'campusCard': {
      'hasData': hasCampusCardData,
      'balance': hasCampusCardData ? campusCardBalance : '',
      'low': campusCardLow,
    },
    'electricity': {
      'hasData': hasElectricityData,
      'value': hasElectricityData ? dormElectricity : '',
      'low': electricityLow,
    },
    if (accentLight != null && accentDark != null)
      'theme': {'accentLight': accentLight, 'accentDark': accentDark},
    'notices': {'unreadCount': unreadNoticeCount, 'items': noticeItems},
    // —— v1 兼容字段（旧原生实现读取；新原生实现不得依赖）——
    'heroHeadline': heroHeadline,
    'heroTimeText': heroTimeText,
    'heroCourseName': heroCourseName,
    'heroLocationText': heroLocationText,
    'todayCourses': todayCourses,
    'hasTodayCourses': hasTodayCourses,
    'todayTitle': todayTitle,
    'nextExamCourseName': nextExamCourseName,
    'nextExamTimeText': nextExamTimeText,
    'nextExamLocationText': nextExamLocationText,
    'campusCardBalance': campusCardBalance,
    'hasCampusCardData': hasCampusCardData,
    'dormElectricity': dormElectricity,
    'hasElectricityData': hasElectricityData,
    'unreadNoticeCount': unreadNoticeCount,
  };

  static CampusWidgetProjection fromPresentation(
    HomePresentation presentation, {
    required DateTime generatedAt,
    required int unreadNoticeCount,
    CampusWidgetEmptyState? emptyState,
    List<Map<String, Object?>> days = const [],
    List<Map<String, Object?>> exams = const [],
    List<Map<String, Object?>> noticeItems = const [],
    String? accentLight,
    String? accentDark,
  }) {
    final exam = presentation.today.exams.isEmpty
        ? null
        : presentation.today.exams.first;
    return CampusWidgetProjection(
      generatedAt: generatedAt,
      weekLabel: presentation.weekLabel,
      heroHeadline: presentation.hero.headline,
      heroTimeText: presentation.hero.timeText,
      heroCourseName: presentation.hero.courseName,
      heroLocationText: presentation.hero.locationText,
      todayCourses: [
        for (final course in presentation.today.courses)
          {
            'timeText': course.timeText,
            'courseName': course.courseName,
            'locationText': course.locationText,
            'isOngoing': course.isOngoing,
          },
      ],
      hasTodayCourses: presentation.today.courses.isNotEmpty,
      todayTitle: presentation.today.title,
      nextExamCourseName: exam?.courseName,
      nextExamTimeText: exam?.timeText,
      nextExamLocationText: exam?.locationText,
      campusCardBalance: presentation.status.campusCardBalance,
      hasCampusCardData: presentation.status.hasCampusCardData,
      dormElectricity: presentation.status.dormElectricity,
      hasElectricityData: presentation.status.hasElectricityData,
      unreadNoticeCount: unreadNoticeCount,
      emptyState: emptyState,
      days: days,
      exams: exams,
      campusCardLow: presentation.status.lowBalance,
      electricityLow: presentation.status.lowElectricity,
      noticeItems: noticeItems,
      accentLight: accentLight,
      accentDark: accentDark,
    );
  }
}

// ---------------------------------------------------------------------------
// v2：日程 / 考试 / 通知（纯函数，输入全部显式传入以便测试）
// ---------------------------------------------------------------------------

const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String _two(int value) => value.toString().padLeft(2, '0');

String _dateText(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// 本地时间 ISO-8601，**无时区后缀、无小数秒**：`2026-10-16T07:58:00`。
String formatCampusWidgetDateTime(DateTime value) =>
    '${_dateText(value)}T${_two(value.hour)}:${_two(value.minute)}:'
    '${_two(value.second)}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime? _tryClock(DateTime day, String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return DateTime(day.year, day.month, day.day, h, m);
}

/// 地点：教室优先（组件地点栏很窄），缺教室退回校区，皆空为「地点待定」。
String _widgetLocationText(String classroom, String campus) {
  final room = classroom.trim();
  if (room.isNotEmpty) return room;
  final fallback = campus.trim();
  return fallback.isNotEmpty ? fallback : '地点待定';
}

/// 构建「今天起 7 天」。每个课程带绝对起止时间（节次→钟点取自
/// `ScheduleSlotTimes`，与课表页 / 首页同一张表）。
///
/// - 调课规则经 [buildEffectiveWeekCourses] 应用；法定节假日整日无课
///   （`holidayName` = 节日名）；权威课表当天本有课却被调课全部取消视为停课
///   （`holidayName` = '停课'），判定与首页 Hero 的放假判定一致。
/// - 教学周之外的日期课程为空；[hasCourseData] 为 false（未登录 / 无缓存）
///   时所有 `courses` 为空且不推断假期。
/// - 已结束的课**保留**：原生按绝对时间自行判定进行中 / 已结束，因此「今日
///   全部课程」开关只影响 v1 兼容字段，不影响这里。
List<Map<String, Object?>> buildCampusWidgetDays({
  required DateTime now,
  required bool hasCourseData,
  required List<CourseEntry> courses,
  required List<CourseChangeRule> changeRules,
  List<ScheduleDateOverride> dateOverrides = const [],
  required DateTime semesterStartDate,
}) {
  final today = _day(now);
  final semesterStart = _day(semesterStartDate);
  final weekOneStart = semesterStart.subtract(
    Duration(days: semesterStart.weekday - 1),
  );
  final result = <Map<String, Object?>>[];
  for (var i = 0; i < campusWidgetDayCount; i++) {
    final date = DateTime(today.year, today.month, today.day + i);
    final weekday = _weekdayLabels[date.weekday - 1];
    final inSemester =
        !date.isBefore(weekOneStart) &&
        date.difference(semesterStart).inDays < 20 * 7;
    // 与 SemesterCalendar.weekForDate 同一公式（钳制 1..20）。
    final week = ((date.difference(weekOneStart).inDays ~/ 7) + 1).clamp(1, 20);

    String? holidayName;
    final dayCourses = <CourseEntry>[];
    if (hasCourseData && inSemester) {
      final publicHoliday = chinaPublicHolidayOn(date);
      if (publicHoliday != null) {
        holidayName = publicHoliday.name;
      } else {
        final effective = buildEffectiveWeekCourses(
          courses: courses,
          week: week,
          changeRules: changeRules,
          dateOverrides: dateOverrides,
        ).where((c) => c.weekday == date.weekday).toList();
        if (effective.isEmpty &&
            courses.any((c) => c.isInWeek(week) && c.weekday == date.weekday)) {
          holidayName = '停课';
        }
        dayCourses.addAll(effective);
      }
    }
    dayCourses.sort((a, b) => a.startLesson.compareTo(b.startLesson));

    result.add({
      'date': _dateText(date),
      'weekLabel': inSemester ? '第 $week 周 · $weekday' : weekday,
      'holidayName': holidayName,
      'courses': [for (final c in dayCourses) _courseMap(c, date)],
    });
  }
  return result;
}

Map<String, Object?> _courseMap(CourseEntry course, DateTime date) {
  final last = ScheduleSlotTimes.slotTimes.length;
  final startLesson = course.startLesson.clamp(1, last);
  final endLesson = course.endLesson.clamp(startLesson, last);
  final startText = ScheduleSlotTimes.startTime(startLesson);
  final endText = ScheduleSlotTimes.endTime(endLesson);
  return {
    'startAt': formatCampusWidgetDateTime(_tryClock(date, startText)!),
    'endAt': formatCampusWidgetDateTime(_tryClock(date, endText)!),
    'timeText': '$startText-$endText',
    'lessonText': startLesson == endLesson
        ? '$startLesson 节'
        : '$startLesson-$endLesson 节',
    'courseName': course.courseName,
    'locationText': _widgetLocationText(course.classroom, course.campus),
  };
}

/// 未结束的考试，按开始时间升序，最多 [campusWidgetListLimit] 条。
///
/// 无日期的考试不输出；缺开始时间按 00:00。缺结束时间时**显式**补一个结束时刻
/// 写进 `endAt`（有开始时间 → 开始 + 2 小时；连开始时间也没有 → 当天 23:59:59），
/// 免得原生按自己的默认值提前把考试当成已结束。
List<Map<String, Object?>> buildCampusWidgetExams({
  required DateTime now,
  required List<ExamEntry> exams,
}) {
  final rows = <({DateTime start, Map<String, Object?> map})>[];
  for (final exam in exams) {
    final date = exam.examDate;
    if (date == null) continue;
    final day = _day(date);
    final start = _tryClock(day, exam.startTime) ?? day;
    final knownStart = _tryClock(day, exam.startTime) != null;
    final end =
        _tryClock(day, exam.endTime) ??
        (knownStart
            ? start.add(const Duration(hours: 2))
            : DateTime(day.year, day.month, day.day, 23, 59, 59));
    final over = now.isAfter(end);
    if (over) continue;
    final range = exam.timeRange;
    rows.add((
      start: start,
      map: {
        'startAt': formatCampusWidgetDateTime(start),
        'endAt': formatCampusWidgetDateTime(end),
        'timeText': range.isEmpty
            ? '${day.month}月${day.day}日'
            : '${day.month}月${day.day}日 $range',
        'courseName': exam.courseName,
        'locationText': _widgetLocationText(exam.location, exam.campus),
      },
    ));
  }
  rows.sort((a, b) => a.start.compareTo(b.start));
  return [for (final row in rows.take(campusWidgetListLimit)) row.map];
}

/// 最新通知（≤5）：`{title, publishedAt: 'YYYY-MM-DD' 或 ''}`。
List<Map<String, Object?>> buildCampusWidgetNoticeItems(
  Iterable<Notice> notices,
) => [
  for (final notice in notices.take(campusWidgetListLimit))
    {
      'title': notice.title,
      'publishedAt': notice.parsedDate == null
          ? ''
          : _dateText(notice.parsedDate!),
    },
];

/// 无课表可展示时的整体状态；有课程可展示（含 7 天窗口内进入教学周）为 null。
CampusWidgetEmptyState? resolveCampusWidgetEmptyState({
  required bool courseLoggedIn,
  required bool hasScheduleCache,
  required bool isBeforeSemesterStart,
  required bool isAfterSemesterEnd,
  required List<Map<String, Object?>> days,
}) {
  if (!courseLoggedIn) return CampusWidgetEmptyState.notLoggedIn;
  if (!hasScheduleCache) return CampusWidgetEmptyState.noCache;
  final anyCourse = days.any((d) => (d['courses'] as List).isNotEmpty);
  if (anyCourse) return null;
  if (isBeforeSemesterStart) return CampusWidgetEmptyState.beforeSemester;
  if (isAfterSemesterEnd) return CampusWidgetEmptyState.afterSemester;
  return null;
}

/// 从当前缓存态构建投影（仅读缓存，不发起网络请求）。
CampusWidgetProjection buildCampusWidgetProjection({DateTime? now}) {
  final at = now ?? DateTime.now();
  final coordinator = CampusSnapshotCoordinator.instance;
  final restore = coordinator.restore(at);
  final calendar = SemesterCalendar.instance;
  final snapshot = HomeSnapshot(
    now: at,
    courseLoggedIn: restore.courseLoggedIn,
    hasScheduleCache: restore.hasScheduleCache,
    courses: restore.scheduleSnapshot?.courses ?? const [],
    changeRules: restore.scheduleSnapshot?.changeRules ?? const [],
    dateOverrides: restore.scheduleSnapshot?.dateOverrides ?? const [],
    isBeforeSemesterStart: calendar.isBeforeSemesterStart(at),
    isAfterSemesterEnd: calendar.isAfterSemesterEnd(at),
    currentWeek: calendar.weekForDate(at),
    semesterStartDate: calendar.semesterStartDate.value,
    campusCardBalance: restore.campusCardBalance,
    dormElectricity: restore.dormElectricity,
    nextExam: restore.nextExam,
  );
  final presentation = resolveHomePresentation(
    snapshot,
    fullDayCourses:
        PersonalizationController.instance.fullDayCoursesEnabled.value,
  );

  // 课程只在「已验证 owner 的课表缓存」存在时输出（与首页同一 owner 规则：
  // restore.hasScheduleCache 来自 preferredSnapshot，要求当前已验证正方身份）。
  final days = buildCampusWidgetDays(
    now: at,
    hasCourseData: restore.courseLoggedIn && restore.hasScheduleCache,
    courses: snapshot.courses,
    changeRules: snapshot.changeRules,
    dateOverrides: snapshot.dateOverrides,
    semesterStartDate: snapshot.semesterStartDate,
  );
  final unread = NoticeSyncStore.instance.unreadSummary.value;
  final accents = resolveCampusWidgetAccents(
    AppThemeController.instance.seedColor.value,
  );
  return CampusWidgetProjection.fromPresentation(
    presentation,
    generatedAt: at,
    unreadNoticeCount: unread.count,
    emptyState: resolveCampusWidgetEmptyState(
      courseLoggedIn: restore.courseLoggedIn,
      hasScheduleCache: restore.hasScheduleCache,
      isBeforeSemesterStart: snapshot.isBeforeSemesterStart,
      isAfterSemesterEnd: snapshot.isAfterSemesterEnd,
      days: days,
    ),
    days: days,
    exams: buildCampusWidgetExams(
      now: at,
      exams: coordinator.cachedExams ?? const [],
    ),
    noticeItems: buildCampusWidgetNoticeItems(unread.latest),
    accentLight: accents.light,
    accentDark: accents.dark,
  );
}
