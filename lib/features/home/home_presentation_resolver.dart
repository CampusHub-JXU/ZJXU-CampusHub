import '../exam/exam_model.dart';
import '../schedule/schedule_model.dart';
import '../schedule/schedule_service.dart';
import 'models/home_presentation.dart';
import 'models/home_snapshot.dart';

/// 事件提醒阈值：余额 ≤ ¥20 / 电量 ≤ 10 度视为需要提醒。
const _lowBalanceThreshold = 20.0;
const _lowElectricityThreshold = 10.0;

const _weekDayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 首页展示层派生：输入 [HomeSnapshot]，输出 [HomePresentation]。
///
/// 约定：本函数不取 [DateTime.now]、不触网、不读可变单例状态；
/// 周次换算复刻 `SemesterCalendar.weekForDate` 的纯公式
/// （以开学日所在周的周一为第 1 周起点，钳制 1..20），
/// 课表「周有效课」复用 [ScheduleService.buildEffectiveWeekCourses]
/// （仅做过滤与调课变换，无 IO）。
HomePresentation resolveHomePresentation(HomeSnapshot snapshot) {
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
  );

  final nextCourseState = _resolveNextCourseState(
    snapshot: snapshot,
    today: today,
    now: now,
    weekOneStart: weekOneStart,
    scanningToday: scanningToday,
    scanStart: scanStart,
  );

  final hero = _resolveHero(
    snapshot: snapshot,
    now: now,
    today: today,
    normalizedSemesterStart: normalizedSemesterStart,
    hasCourseData: hasCourseData,
    currentCourse: todayState.currentCourse,
    nextCourse: nextCourseState.course,
    nextCourseLabel: nextCourseState.label,
    nextCourseDate: nextCourseState.date,
  );

  // 周次标签：开学前 / 学期结束后 / 教学周内，供首页环境行使用。
  final weekLabel = snapshot.isBeforeSemesterStart
      ? '未开学'
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
    today: HomeTodayPresentation(
      courses: todayState.rows,
      exams: todayState.exams,
    ),
    weekLabel: weekLabel,
  );
}

class _TodayState {
  const _TodayState({
    required this.rows,
    required this.exams,
    this.currentCourse,
  });

  final List<HomeTodayCourseRow> rows;
  final List<HomeTodayExamRow> exams;
  final CourseEntry? currentCourse;
}

/// 今天剩余课程（含正在上的课）与今日考试。
_TodayState _resolveTodayState({
  required HomeSnapshot snapshot,
  required DateTime today,
  required DateTime now,
  required DateTime weekOneStart,
  required bool scanningToday,
}) {
  final rows = <HomeTodayCourseRow>[];
  final exams = <HomeTodayExamRow>[];
  CourseEntry? currentCourse;

  if (scanningToday && snapshot.courseLoggedIn && snapshot.hasScheduleCache) {
    final week = _weekForDate(today, weekOneStart);
    final effectiveCourses = _effectiveWeekCourses(snapshot, week);
    final dayCourses =
        effectiveCourses
            .where((course) => course.weekday == today.weekday)
            .toList()
          ..sort((a, b) => a.startLesson.compareTo(b.startLesson));
    for (final course in dayCourses) {
      final start = _lessonStartTime(course.startLesson, today);
      final end = _lessonEndTime(course.endLesson, today);
      if (now.isAfter(end)) continue;
      final isOngoing = !now.isBefore(start) && !now.isAfter(end);
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

  return _TodayState(rows: rows, exams: exams, currentCourse: currentCourse);
}

class _NextCourseState {
  const _NextCourseState({this.course, this.label = '', this.date});

  final CourseEntry? course;
  final String label;
  final DateTime? date;
}

/// 下一节课扫描（移植自 home_page._buildNextCourseState）：
/// 从今天（未开学时从开学日起算，避免把假期里的今天映射到第 1 周的课上）
/// 起最多向后扫 14 天，找到第一门「尚未开始」的课。
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
    final week = _weekForDate(date, weekOneStart);
    final effectiveCourses = _effectiveWeekCourses(snapshot, week);
    final dayCourses =
        effectiveCourses
            .where((course) => course.weekday == date.weekday)
            .where(
              (course) =>
                  offset > 0 ||
                  !scanningToday ||
                  course.startLesson >= nextLessonToday,
            )
            .toList()
          ..sort((a, b) => a.startLesson.compareTo(b.startLesson));
    if (dayCourses.isNotEmpty) {
      return _NextCourseState(
        course: dayCourses.first,
        label: _labelForDate(date, today),
        date: date,
      );
    }
  }
  return const _NextCourseState();
}

/// Hero 优先级：
/// 正在上课 > 下一节课(今天) > 24h 内考试 > 未开学倒计时 >
/// 学期已结束 > 今天没课(近期无课) > 未登录。
HomeHeroPresentation _resolveHero({
  required HomeSnapshot snapshot,
  required DateTime now,
  required DateTime today,
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

  // P2：未开学倒计时（不依赖登录态）。
  if (snapshot.isBeforeSemesterStart) {
    final days = normalizedSemesterStart.difference(today).inDays;
    final course = nextCourse;
    return HomeHeroPresentation(
      kind: HomeHeroKind.beforeSemester,
      headline: days <= 0 ? '即将开学' : '距离开学还有 $days 天',
      timeText: course == null || nextCourseDate == null
          ? '${normalizedSemesterStart.month}月${normalizedSemesterStart.day}日'
          : '${nextCourseDate.month}月${nextCourseDate.day}日 '
                '${ScheduleSlotTimes.startTime(course.startLesson)}',
      courseName: course?.courseName,
      locationText: course == null
          ? null
          : _locationText(campus: course.campus, classroom: course.classroom),
      lessonText: course == null
          ? null
          : _lessonText(course.startLesson, course.endLesson),
    );
  }

  // P3：学期已结束。
  if (snapshot.isAfterSemesterEnd) {
    return const HomeHeroPresentation(
      kind: HomeHeroKind.semesterOver,
      headline: '学期已结束',
    );
  }

  // P3：今天没课 / 近期无课。
  if (snapshot.courseLoggedIn) {
    if (nextCourse != null) {
      return HomeHeroPresentation(
        kind: HomeHeroKind.noCourseToday,
        headline: '今天没课',
        timeText:
            '下一节：$nextCourseLabel '
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

/// 事件提醒（最多一条，优先级：考试 > 低电量 > 低余额）。
/// 考试已是 Hero 时不重复提醒；余额/电费为 '--' 时不判定。
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

  final balanceValue = double.tryParse(snapshot.campusCardBalance);
  if (balanceValue != null && balanceValue <= _lowBalanceThreshold) {
    return HomeAlertPresentation(
      kind: HomeAlertKind.lowBalance,
      message: '校园卡余额 ¥${snapshot.campusCardBalance}，余额偏低，建议尽快充值',
      routeName: 'campus-card',
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
    lowBalance: balanceValue != null && balanceValue <= _lowBalanceThreshold,
    lowElectricity:
        electricityValue != null &&
        electricityValue <= _lowElectricityThreshold,
  );
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

List<CourseEntry> _effectiveWeekCourses(HomeSnapshot snapshot, int week) {
  return ScheduleService.instance.buildEffectiveWeekCourses(
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
