import '../../core/academic/effective_week_courses.dart';
import '../../core/academic/exam_model.dart';
import '../../core/academic/schedule_model.dart';
import '../../core/semester/china_public_holidays.dart';
import 'models/home_presentation.dart';
import 'models/home_snapshot.dart';

/// 事件提醒阈值：电量 ≤ 10 度视为需要提醒。
///
/// 校园卡低余额不再参与首页强调（横幅与资产行红字均已停用），
/// 阈值常量一并删除。
const _lowElectricityThreshold = 10.0;

/// 次日预览（开学首日/明天）最多展示的课程条数。
const _previewRowLimit = 3;

const _weekDayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 首页展示层派生：输入 [HomeSnapshot]，输出 [HomePresentation]。
///
/// 约定：本函数不取 [DateTime.now]、不触网、不读可变单例状态；
/// 周次换算复刻 `SemesterCalendar.weekForDate` 的纯公式
/// （以开学日所在周的周一为第 1 周起点，钳制 1..20），
/// 课表「周有效课」复用 [buildEffectiveWeekCourses]
/// （仅做过滤与调课变换，无 IO）。
///
/// [fullDayCourses]：首页个性化「今日全部课程」开关。开启时 Today
/// 段落列出今天一整天的课程（已结束行灰显）；关闭时保持原有
/// 「仅剩余课程」行为。
HomePresentation resolveHomePresentation(
  HomeSnapshot snapshot, {
  bool fullDayCourses = false,
}) {
  final now = snapshot.now;
  final today = DateTime(now.year, now.month, now.day);
  final normalizedSemesterStart = _normalizeDate(snapshot.semesterStartDate);
  final weekOneStart = _weekOneStartDate(normalizedSemesterStart);
  final scanningToday = !today.isBefore(normalizedSemesterStart);
  final scanStart = scanningToday ? today : normalizedSemesterStart;
  final hasCourseData = snapshot.courseLoggedIn && snapshot.hasScheduleCache;

  final todayState = _resolveTodayState(
    snapshot: snapshot,
    today: today,
    now: now,
    weekOneStart: weekOneStart,
    scanningToday: scanningToday,
    fullDay: fullDayCourses,
  );

  final nextCourseState = _resolveNextCourseState(
    snapshot: snapshot,
    today: today,
    now: now,
    weekOneStart: weekOneStart,
    scanningToday: scanningToday,
    scanStart: scanStart,
  );

  final holiday = hasCourseData && scanningToday
      ? _resolveHoliday(
          snapshot: snapshot,
          today: today,
          weekOneStart: weekOneStart,
        )
      : null;

  final hero = _resolveHero(
    snapshot: snapshot,
    now: now,
    today: today,
    holiday: holiday,
    normalizedSemesterStart: normalizedSemesterStart,
    hasCourseData: hasCourseData,
    currentCourse: todayState.currentCourse,
    nextCourse: nextCourseState.course,
    nextCourseLabel: nextCourseState.label,
    nextCourseDate: nextCourseState.date,
  );

  // 周次标签：开学前为空（环境行省略状态段，「开学」语义由 Hero
  // 倒计时唯一承担，避免一屏四处开学文案）；学期结束后 / 教学周内照常。
  final weekLabel = snapshot.isBeforeSemesterStart
      ? ''
      : snapshot.isAfterSemesterEnd
      ? '学期已结束'
      : '第 ${snapshot.currentWeek} 周';

  return HomePresentation(
    hero: hero,
    alert: _resolveAlert(
      snapshot: snapshot,
      today: today,
      now: now,
      heroKind: hero.kind,
    ),
    status: _resolveStatus(snapshot),
    today: _resolveTodayPresentation(
      snapshot: snapshot,
      todayState: todayState,
      nextCourseState: nextCourseState,
      hasCourseData: hasCourseData,
      today: today,
      heroKind: hero.kind,
      fullDay: fullDayCourses,
    ),
    weekLabel: weekLabel,
  );
}

/// Today 段落展示：正常输出今天剩余课程；今天没有剩余安排且能扫到
/// 之后某天的课时，降级为「次日预览」——开学前显示开学首日的前几节课，
/// 学期中（晚间/无课日）显示明天或下一个有课日，避免首页上半屏空置、
/// 功能区过早进入视口。
///
/// 全天形态（[fullDay]）：今天有任何剩余课程或考试时，列出它们
/// （进行中保留胶囊），已结束课程不展示；今天没有剩余安排时仍走
/// 次日预览兜底。
///
/// 预览段与 Hero 的分工：Hero 已用课程大字展示命中日首课（今天没课态）
/// 时，预览折叠为单行「之后还有 N 门」摘要并剔除首课，命中日仅此一门
/// 时整段消失——次日列表不得与 Hero 抢视觉权重；开学前 Hero 是倒计时，
/// 预览仍完整展示前 [_previewRowLimit] 条。
HomeTodayPresentation _resolveTodayPresentation({
  required HomeSnapshot snapshot,
  required _TodayState todayState,
  required _NextCourseState nextCourseState,
  required bool hasCourseData,
  required DateTime today,
  required HomeHeroKind heroKind,
  required bool fullDay,
}) {
  if (fullDay) {
    if (todayState.rows.isNotEmpty || todayState.exams.isNotEmpty) {
      return HomeTodayPresentation(
        courses: todayState.rows,
        exams: todayState.exams,
        isFullDay: true,
      );
    }
  } else if (todayState.rows.isNotEmpty || todayState.exams.isNotEmpty) {
    return HomeTodayPresentation(
      courses: todayState.rows,
      exams: todayState.exams,
    );
  }

  final previewDate = nextCourseState.date;
  if (!hasCourseData ||
      previewDate == null ||
      !_normalizeDate(previewDate).isAfter(today)) {
    return HomeTodayPresentation(
      courses: todayState.rows,
      exams: todayState.exams,
    );
  }

  // Hero 已把「下一节课是什么」以课程大字完整呈现(今天没课态):
  // 折叠摘要行「之后还有 N 门课 · 下一门 ...」与 hero 抢视觉权重,
  // 直接让出首页空间 — 用户想看后续其他课程直接进课表。
  if (heroKind == HomeHeroKind.nextCourseUpcoming) {
    return const HomeTodayPresentation(courses: [], exams: []);
  }

  // 其他情况(开学前倒计时 / 学期中次日预览)正常呈现前几条预览。
  final previewCourses = nextCourseState.dayCourses
      .take(_previewRowLimit)
      .toList();
  if (previewCourses.isEmpty) {
    return HomeTodayPresentation(courses: const [], exams: const []);
  }

  final title = snapshot.isBeforeSemesterStart
      ? '开学首日'
      : _labelForDate(previewDate, today);
  return HomeTodayPresentation(
    title: title,
    isPreview: true,
    courses: [
      for (final course in previewCourses)
        HomeTodayCourseRow(
          timeText: ScheduleSlotTimes.startTime(course.startLesson),
          lessonText: _lessonText(course.startLesson, course.endLesson),
          courseName: course.courseName,
          locationText: _locationText(
            campus: course.campus,
            classroom: course.classroom,
          ),
          isOngoing: false,
        ),
    ],
    exams: const [],
  );
}

class _TodayState {
  const _TodayState({
    required this.rows,
    required this.exams,
    this.currentCourse,
  });

  /// 展示行：已剔除已结束课程。
  final List<HomeTodayCourseRow> rows;
  final List<HomeTodayExamRow> exams;
  final CourseEntry? currentCourse;
}

/// 今天课程行（含已结束/正在上状态标记）与今日考试；剩余/全天两种
/// 模式的行过滤在返回值处完成。
_TodayState _resolveTodayState({
  required HomeSnapshot snapshot,
  required DateTime today,
  required DateTime now,
  required DateTime weekOneStart,
  required bool scanningToday,
  required bool fullDay,
}) {
  final rows = <HomeTodayCourseRow>[];
  final exams = <HomeTodayExamRow>[];
  CourseEntry? currentCourse;

  if (scanningToday && snapshot.courseLoggedIn && snapshot.hasScheduleCache) {
    final dayCourses = _dayCourses(snapshot, today, weekOneStart);
    for (final course in dayCourses) {
      final start = _lessonStartTime(course.startLesson, today);
      final end = _lessonEndTime(course.endLesson, today);
      final isOngoing = !now.isBefore(start) && !now.isAfter(end);
      final isDone = now.isAfter(end);
      if (isOngoing && currentCourse == null) currentCourse = course;
      rows.add(
        HomeTodayCourseRow(
          timeText: ScheduleSlotTimes.startTime(course.startLesson),
          lessonText: _lessonText(course.startLesson, course.endLesson),
          courseName: course.courseName,
          locationText: _locationText(
            campus: course.campus,
            classroom: course.classroom,
          ),
          isOngoing: isOngoing,
          isDone: isDone,
        ),
      );
    }
  }

  final exam = snapshot.nextExam;
  if (exam != null && exam.examDate != null) {
    final examDay = _normalizeDate(exam.examDate!);
    if (examDay == today) {
      exams.add(
        HomeTodayExamRow(
          timeText: exam.timeRange.isEmpty ? '时间待定' : exam.timeRange,
          courseName: exam.courseName,
          locationText: _locationText(
            campus: exam.campus,
            classroom: exam.location,
          ),
        ),
      );
    }
  }

  return _TodayState(
    // 已结束的课一律不进「今天」列表，全天/剩余模式行为一致。
    rows: rows.where((row) => !row.isDone).toList(),
    exams: exams,
    currentCourse: currentCourse,
  );
}

class _NextCourseState {
  const _NextCourseState({
    this.course,
    this.label = '',
    this.date,
    this.dayCourses = const [],
  });

  final CourseEntry? course;
  final String label;
  final DateTime? date;

  /// 命中日当天的全部课程（按节次升序），供 Today 段落的次日预览使用。
  final List<CourseEntry> dayCourses;
}

/// 下一节课扫描（移植自 home_page._buildNextCourseState）：
/// 从今天（未开学时从开学日起算，避免把假期里的今天映射到第 1 周的课上）
/// 起最多向后扫 14 天，找到第一门「尚未开始」的课；法定假期当天视为
/// 无课（见 [_dayCourses]）。
_NextCourseState _resolveNextCourseState({
  required HomeSnapshot snapshot,
  required DateTime today,
  required DateTime now,
  required DateTime weekOneStart,
  required bool scanningToday,
  required DateTime scanStart,
}) {
  if (!snapshot.hasScheduleCache) return const _NextCourseState();
  final nextLessonToday = _nextStartLesson(now);

  for (int offset = 0; offset < 14; offset++) {
    final date = scanStart.add(Duration(days: offset));
    final dayCourses = _dayCourses(snapshot, date, weekOneStart)
        .where(
          (course) =>
              offset > 0 ||
              !scanningToday ||
              course.startLesson >= nextLessonToday,
        )
        .toList();
    if (dayCourses.isNotEmpty) {
      return _NextCourseState(
        course: dayCourses.first,
        label: _labelForDate(date, today),
        date: date,
        dayCourses: dayCourses,
      );
    }
  }
  return const _NextCourseState();
}

/// Hero 优先级：
/// 正在上课 > 下一节课(今天) > 24h 内考试 > 未开学倒计时 >
/// 学期已结束 > 假期(明天不上课) > 今天没课(下一节大字/近期无课) > 未登录。
HomeHeroPresentation _resolveHero({
  required HomeSnapshot snapshot,
  required DateTime now,
  required DateTime today,
  required _HolidayState? holiday,
  required DateTime normalizedSemesterStart,
  required bool hasCourseData,
  required CourseEntry? currentCourse,
  required CourseEntry? nextCourse,
  required String nextCourseLabel,
  required DateTime? nextCourseDate,
}) {
  // P0：正在上课。
  final current = currentCourse;
  if (current != null) {
    return HomeHeroPresentation(
      kind: HomeHeroKind.currentCourse,
      headline: '正在上课',
      timeText: '${ScheduleSlotTimes.endTime(current.endLesson)} 下课',
      courseName: current.courseName,
      locationText: _locationText(
        campus: current.campus,
        classroom: current.classroom,
      ),
      lessonText: _lessonText(current.startLesson, current.endLesson),
    );
  }

  // P1：今天还有课。
  if (hasCourseData && nextCourse != null && nextCourseLabel == '今天') {
    final start = _lessonStartTime(nextCourse.startLesson, today);
    final minutes = start.difference(now).inMinutes;
    if (minutes > 0) {
      return HomeHeroPresentation(
        kind: HomeHeroKind.nextCourseToday,
        headline: _countdownHeadline(minutes),
        timeText: ScheduleSlotTimes.startTime(nextCourse.startLesson),
        courseName: nextCourse.courseName,
        locationText: _locationText(
          campus: nextCourse.campus,
          classroom: nextCourse.classroom,
        ),
        lessonText: _lessonText(nextCourse.startLesson, nextCourse.endLesson),
      );
    }
    // 已开始（且已结束）的课程不再作为「即将上课」，继续向下判定。
  }

  // P1：24 小时内考试。
  final examHero = _examWithin24h(snapshot.nextExam, today, now);
  if (examHero != null) {
    final exam = examHero;
    return HomeHeroPresentation(
      kind: HomeHeroKind.examSoon,
      headline: _examDelta(exam, today) == 0 ? '今天考试' : '明天考试',
      timeText: exam.startTime.isEmpty ? null : exam.startTime,
      courseName: exam.courseName,
      locationText: _locationText(
        campus: exam.campus,
        classroom: exam.location,
      ),
    );
  }

  // P2：未开学倒计时（不依赖登录态）。只保留「还有几天 + 开学日期」
  // 两个信息，且都不再重复「开学」字样以外的语义——首日课程详情全部
  // 交给下方「开学首日」预览段落，全屏「开学」文案不超过两处。
  if (snapshot.isBeforeSemesterStart) {
    final days = normalizedSemesterStart.difference(today).inDays;
    return HomeHeroPresentation(
      kind: HomeHeroKind.beforeSemester,
      headline: days <= 0 ? '即将开学' : '距离开学还有 $days 天',
      timeText:
          '${normalizedSemesterStart.month}月${normalizedSemesterStart.day}日',
    );
  }

  // P3：学期已结束。
  if (snapshot.isAfterSemesterEnd) {
    return const HomeHeroPresentation(
      kind: HomeHeroKind.semesterOver,
      headline: '学期已结束',
    );
  }

  // P3：假期。今天是法定假期或整天停课，且明天也不上课时，换成
  // 轻松的假期文案；明天就有课则老老实实走下方「今天没课 · 下一节」。
  if (holiday != null && nextCourseLabel != '明天') {
    return HomeHeroPresentation(
      kind: HomeHeroKind.holiday,
      kicker: holiday.name == null ? '放假中' : '${holiday.name} · 放假中',
      headline: _holidayHeadline(holiday, today),
      timeText: nextCourse == null ? null : '$nextCourseLabel 恢复上课',
    );
  }

  // P3：今天没课。近期有课时「下一节课」仍是第一屏最重要的信息——
  // 升级为课程大字形态（kicker「今天没课 · 下一节」，日期标签并入
  // 时间行），当天剩余课程由 Today 段落折叠承接；近期无课才回落纯文字。
  if (snapshot.courseLoggedIn) {
    if (nextCourse != null) {
      return HomeHeroPresentation(
        kind: HomeHeroKind.nextCourseUpcoming,
        headline: '今天没课',
        timeText:
            '$nextCourseLabel '
            '${ScheduleSlotTimes.startTime(nextCourse.startLesson)}',
        courseName: nextCourse.courseName,
        locationText: _locationText(
          campus: nextCourse.campus,
          classroom: nextCourse.classroom,
        ),
        lessonText: _lessonText(nextCourse.startLesson, nextCourse.endLesson),
      );
    }
    return const HomeHeroPresentation(
      kind: HomeHeroKind.noCourseToday,
      headline: '近期无课',
    );
  }

  // P4：未登录且无缓存。
  return const HomeHeroPresentation(
    kind: HomeHeroKind.loggedOut,
    headline: '登录后查看课程',
  );
}

/// 事件提醒（最多一条，优先级：考试 > 低电量）。
/// 考试已是 Hero 时不重复提醒；电费为 '--' 时不判定。
/// 校园卡低余额不再产生提醒（[HomeStatusPresentation.lowBalance] 恒为
/// false，低余额不触发任何首页强调）。
HomeAlertPresentation? _resolveAlert({
  required HomeSnapshot snapshot,
  required DateTime today,
  required DateTime now,
  required HomeHeroKind heroKind,
}) {
  if (heroKind != HomeHeroKind.examSoon) {
    final exam = _examWithin24h(snapshot.nextExam, today, now);
    if (exam != null) {
      final isToday = _examDelta(exam, today) == 0;
      final timeText = exam.startTime.isEmpty ? '' : ' ${exam.startTime}';
      return HomeAlertPresentation(
        kind: HomeAlertKind.examSoon,
        message: '${isToday ? '今天' : '明天'}$timeText ${exam.courseName}考试',
        routeName: 'exam',
      );
    }
  }

  final electricityValue = double.tryParse(snapshot.dormElectricity);
  if (electricityValue != null &&
      electricityValue <= _lowElectricityThreshold) {
    return HomeAlertPresentation(
      kind: HomeAlertKind.lowElectricity,
      message: '宿舍剩余 ${snapshot.dormElectricity} 度，电量偏低，建议及时充值',
      routeName: 'dorm-electricity',
    );
  }

  return null;
}

HomeStatusPresentation _resolveStatus(HomeSnapshot snapshot) {
  final balanceValue = double.tryParse(snapshot.campusCardBalance);
  final electricityValue = double.tryParse(snapshot.dormElectricity);
  return HomeStatusPresentation(
    campusCardBalance: snapshot.campusCardBalance,
    dormElectricity: snapshot.dormElectricity,
    hasCampusCardData: balanceValue != null,
    hasElectricityData: electricityValue != null,
    // 字段保留兼容构造，但首页不再对低余额做强调（红字 / 横幅均不触发）。
    lowBalance: false,
    lowElectricity:
        electricityValue != null &&
        electricityValue <= _lowElectricityThreshold,
  );
}

class _HolidayState {
  const _HolidayState({this.name, this.isFirstDay = false});

  /// 法定节日名（如「国庆节」）；课表停课推断出的假期为 null。
  final String? name;

  /// 今天是否为该法定假期第一天（用节日问候替代轮换文案）。
  final bool isFirstDay;
}

/// 今天是否放假：
/// 1. 命中法定节假日表（[chinaPublicHolidayOn]）；
/// 2. 或课表推断：权威课表今天原本有课，但被调课/停课规则全部取消
///    （学校自行安排的停课日，如运动会、校庆）。
///
/// 本来就没课的日子（周末、空课日）不算放假，保持原有「今天没课」。
_HolidayState? _resolveHoliday({
  required HomeSnapshot snapshot,
  required DateTime today,
  required DateTime weekOneStart,
}) {
  final publicHoliday = chinaPublicHolidayOn(today);
  if (publicHoliday != null) {
    return _HolidayState(
      name: publicHoliday.name,
      isFirstDay: _normalizeDate(publicHoliday.start) == today,
    );
  }
  final week = _weekForDate(today, weekOneStart);
  final hadCourses = snapshot.courses.any(
    (course) => course.isInWeek(week) && course.weekday == today.weekday,
  );
  if (hadCourses && _dayCourses(snapshot, today, weekOneStart).isEmpty) {
    return const _HolidayState();
  }
  return null;
}

const _holidayGreetings = {
  '元旦': '新年快乐，享受假期吧～',
  '春节': '过年好，享受假期吧～',
  '劳动节': '劳动节快乐，好好歇歇～',
  '端午节': '端午安康，记得吃粽子～',
  '中秋节': '中秋快乐，记得吃月饼～',
  '国庆节': '国庆快乐，享受假期吧～',
};

const _holidayHeadlines = [
  '放假啦，享受假期吧～',
  '今天不用上课，好好放松～',
  '没有早八，多睡一会儿～',
  '假期愉快，出去走走吧～',
  '充好电，假期也要开心～',
];

/// 假期大字：法定假期首日用节日问候，其余日子按日期轮换（同一天稳定）。
String _holidayHeadline(_HolidayState holiday, DateTime today) {
  final greeting = _holidayGreetings[holiday.name];
  if (holiday.isFirstDay && greeting != null) return greeting;
  final dayOfYear = today.difference(DateTime(today.year)).inDays;
  return _holidayHeadlines[dayOfYear % _holidayHeadlines.length];
}

// ---------------------------------------------------------------------------
// 内部工具：时间 / 周次 / 文案。均为纯函数。
// ---------------------------------------------------------------------------

/// 当前节次之后的第一节课；全天已过完时返回节次总数（无课可上）。
int _nextStartLesson(DateTime now) {
  final times = ScheduleSlotTimes.slotTimes;
  for (int i = 0; i < times.length; i++) {
    final parts = times[i][0].split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    if (now.hour < hour || (now.hour == hour && now.minute < minute)) {
      return i + 1;
    }
  }
  return times.length;
}

DateTime _parseSlotTime(String hhmm, DateTime baseDay) {
  final parts = hhmm.split(':');
  return DateTime(
    baseDay.year,
    baseDay.month,
    baseDay.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
}

DateTime _lessonStartTime(int lesson, DateTime baseDay) {
  final times = ScheduleSlotTimes.slotTimes;
  return _parseSlotTime(times[lesson.clamp(1, times.length) - 1][0], baseDay);
}

DateTime _lessonEndTime(int lesson, DateTime baseDay) {
  final times = ScheduleSlotTimes.slotTimes;
  return _parseSlotTime(times[lesson.clamp(1, times.length) - 1][1], baseDay);
}

/// 第 1 教学周的周一（开学日所在周的周一）。
DateTime _weekOneStartDate(DateTime semesterStartDate) {
  final day = _normalizeDate(semesterStartDate);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// 复刻 `SemesterCalendar.weekForDate` 的纯公式。
int _weekForDate(DateTime date, DateTime weekOneStart) {
  final diff = _normalizeDate(date).difference(weekOneStart).inDays;
  return ((diff ~/ 7) + 1).clamp(1, 20);
}

DateTime _normalizeDate(DateTime date) =>
    DateTime(date.year, date.month, date.day);

/// [date] 当天的有效课程（按节次升序）。法定节假日当天一律视为无课：
/// 权威课表不知道放假，放假与补课由学校调课通知另行处理。
List<CourseEntry> _dayCourses(
  HomeSnapshot snapshot,
  DateTime date,
  DateTime weekOneStart,
) {
  if (chinaPublicHolidayOn(date) != null) return const [];
  final week = _weekForDate(date, weekOneStart);
  return _effectiveWeekCourses(
      snapshot,
      week,
    ).where((course) => course.weekday == date.weekday).toList()
    ..sort((a, b) => a.startLesson.compareTo(b.startLesson));
}

List<CourseEntry> _effectiveWeekCourses(HomeSnapshot snapshot, int week) {
  return buildEffectiveWeekCourses(
    courses: snapshot.courses,
    week: week,
    changeRules: snapshot.changeRules,
  );
}

String _lessonText(int startLesson, int endLesson) {
  if (startLesson == endLesson) return '第 $startLesson 节';
  return '第 $startLesson-$endLesson 节';
}

/// 校区 + 教室合并展示；两者皆空时为「地点待定」。
String _locationText({required String campus, required String classroom}) {
  final trimmedCampus = campus.trim();
  final trimmedClassroom = classroom.trim();
  if (trimmedCampus.isEmpty && trimmedClassroom.isEmpty) return '地点待定';
  if (trimmedCampus.isEmpty) return trimmedClassroom;
  if (trimmedClassroom.isEmpty) return trimmedCampus;
  return '$trimmedCampus $trimmedClassroom';
}

String _labelForDate(DateTime date, DateTime today) {
  final delta = _normalizeDate(date).difference(_normalizeDate(today)).inDays;
  if (delta == 0) return '今天';
  if (delta == 1) return '明天';
  return '${date.month}/${date.day} ${_weekDayLabels[date.weekday - 1]}';
}

/// 「42 分钟后上课」式倒计时文案。
String _countdownHeadline(int minutes) {
  if (minutes <= 0) return '即将上课';
  if (minutes < 60) return '$minutes 分钟后上课';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时后上课' : '$hours 小时 $rest 分钟后上课';
}

/// 24 小时内（今天 / 明天）且尚未结束的考试；否则返回 null。
ExamEntry? _examWithin24h(ExamEntry? exam, DateTime today, DateTime now) {
  if (exam == null || exam.examDate == null) return null;
  final delta = _examDelta(exam, today);
  if (delta < 0 || delta > 1) return null;
  if (_isExamPast(exam, now)) return null;
  return exam;
}

int _examDelta(ExamEntry exam, DateTime today) =>
    _normalizeDate(exam.examDate!).difference(today).inDays;

bool _isExamPast(ExamEntry exam, DateTime now) {
  final examDate = exam.examDate;
  if (examDate == null) return false;
  final endTime = exam.endTime;
  if (endTime.isNotEmpty) {
    final parts = endTime.split(':');
    if (parts.length == 2) {
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour != null && minute != null) {
        return now.isAfter(
          DateTime(examDate.year, examDate.month, examDate.day, hour, minute),
        );
      }
    }
  }
  return now.isAfter(_normalizeDate(examDate).add(const Duration(days: 1)));
}
