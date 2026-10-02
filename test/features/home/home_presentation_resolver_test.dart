import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/core/academic/schedule_change_rule.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/features/home/home_presentation_resolver.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/models/home_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 固定基准：2026-09-15 10:00（星期二，教学周第 2 周）。
  final baseNow = DateTime(2026, 9, 15, 10, 0);
  final baseSemesterStart = DateTime(2026, 9, 7); // 第 1 周周一

  HomeSnapshot buildSnapshot({
    DateTime? now,
    bool courseLoggedIn = true,
    bool hasScheduleCache = true,
    List<CourseEntry> courses = const [],
    List<CourseChangeRule> changeRules = const [],
    bool isBeforeSemesterStart = false,
    bool isAfterSemesterEnd = false,
    int currentWeek = 2,
    DateTime? semesterStartDate,
    ExamEntry? nextExam,
    String campusCardBalance = '--',
    String dormElectricity = '--',
  }) {
    return HomeSnapshot(
      now: now ?? baseNow,
      courseLoggedIn: courseLoggedIn,
      hasScheduleCache: hasScheduleCache,
      courses: courses,
      changeRules: changeRules,
      isBeforeSemesterStart: isBeforeSemesterStart,
      isAfterSemesterEnd: isAfterSemesterEnd,
      currentWeek: currentWeek,
      semesterStartDate: semesterStartDate ?? baseSemesterStart,
      nextExam: nextExam,
      campusCardBalance: campusCardBalance,
      dormElectricity: dormElectricity,
    );
  }

  CourseEntry courseAt(
    DateTime date, {
    required int startLesson,
    int endLesson = 1,
    String courseName = '线性代数',
    String weekRange = '1-16周',
  }) {
    return CourseEntry(
      courseName: courseName,
      teacherName: '张老师',
      weekday: date.weekday,
      startLesson: startLesson,
      endLesson: endLesson,
      weekRange: weekRange,
      classroom: '铭德楼240',
      campus: '梁林校区',
      typeSymbol: '',
    );
  }

  ExamEntry examAt(
    DateTime date, {
    String startTime = '09:00',
    String endTime = '11:00',
    String courseName = '微观经济学',
  }) {
    return ExamEntry(
      courseName: courseName,
      courseCode: 'ECO101',
      examTimeRaw: '',
      examDate: date,
      startTime: startTime,
      endTime: endTime,
      location: '1教302',
      campus: '梁林校区',
      seatNumber: '12',
      examName: '期末考试',
      department: '经济学院',
      isRetake: false,
      academicYear: '2026-2027',
      semester: '1',
      weekday: date.weekday,
      weekNumber: 0,
    );
  }

  group('Hero 优先级', () {
    test('正在上课 > 一切：显示下课时间与进行中标记', () {
      final today = DateTime(2026, 9, 15);
      // 第 3-4 节 09:45-11:10，now=10:00 正在上课。
      final snapshot = buildSnapshot(
        courses: [courseAt(today, startLesson: 3, endLesson: 4)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.currentCourse);
      expect(presentation.hero.headline, '正在上课');
      expect(presentation.hero.timeText, '11:10 下课');
      expect(presentation.hero.courseName, '线性代数');
      expect(presentation.hero.locationText, '梁林校区 铭德楼240');
      expect(presentation.hero.lessonText, '第 3-4 节');
      expect(presentation.today.courses.single.isOngoing, isTrue);
    });

    test('下一节课今天：42 分钟后上课（边界值）', () {
      final today = DateTime(2026, 9, 15);
      // 第 3 节 09:45 开始；now=09:03 → 42 分钟。
      final snapshot = buildSnapshot(
        now: DateTime(2026, 9, 15, 9, 3),
        courses: [courseAt(today, startLesson: 3)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseToday);
      expect(presentation.hero.headline, '42 分钟后上课');
      expect(presentation.hero.timeText, '09:45');
    });

    test('下一节课今天：跨小时倒计时', () {
      final today = DateTime(2026, 9, 15);
      // 第 3 节 09:45 开始；now=07:00 → 2 小时 45 分钟。
      final snapshot = buildSnapshot(
        now: DateTime(2026, 9, 15, 7, 0),
        courses: [courseAt(today, startLesson: 3)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseToday);
      expect(presentation.hero.headline, '2 小时 45 分钟后上课');
    });

    test('今天没课：下一节课升级为课程大字形态', () {
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: [courseAt(tomorrow, startLesson: 1, courseName: '高等数学')],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
      expect(presentation.hero.headline, '今天没课');
      expect(presentation.hero.timeText, '明天 08:00');
      expect(presentation.hero.courseName, '高等数学');
    });

    test('深夜扫描到的今日最后一节课已结束：不显示"即将上课"', () {
      final today = DateTime(2026, 9, 15);
      // 第 13 节 20:00-20:40；now=22:00 已结束。
      final snapshot = buildSnapshot(
        now: DateTime(2026, 9, 15, 22, 0),
        courses: [courseAt(today, startLesson: 13)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
      expect(presentation.hero.headline, '今天没课');
      expect(presentation.hero.timeText, isNot(contains('即将上课')));
    });

    test('未开学：倒计时 + 开学日期，文案去重不携带首课信息', () {
      final semesterStart = DateTime(2026, 9, 24); // 距 baseNow 9 天
      final snapshot = buildSnapshot(
        isBeforeSemesterStart: true,
        currentWeek: 1,
        semesterStartDate: semesterStart,
        courses: [courseAt(semesterStart, startLesson: 1)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.beforeSemester);
      expect(presentation.hero.headline, '距离开学还有 9 天');
      expect(presentation.hero.timeText, '9月24日');
      expect(presentation.hero.courseName, isNull);
      expect(presentation.weekLabel, isEmpty);
    });

    test('学期已结束', () {
      final snapshot = buildSnapshot(isAfterSemesterEnd: true);

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.semesterOver);
      expect(presentation.hero.headline, '学期已结束');
      expect(presentation.weekLabel, '学期已结束');
    });

    test('未登录且无缓存：登录后查看课程', () {
      final snapshot = buildSnapshot(
        courseLoggedIn: false,
        hasScheduleCache: false,
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.loggedOut);
      expect(presentation.hero.headline, '登录后查看课程');
    });

    test('已登录但无课表数据：近期无课', () {
      final snapshot = buildSnapshot(hasScheduleCache: false);

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.noCourseToday);
      expect(presentation.hero.headline, '近期无课');
    });

    test('未开学优先展示倒计时，即使未登录', () {
      final semesterStart = DateTime(2026, 9, 24);
      final snapshot = buildSnapshot(
        courseLoggedIn: false,
        hasScheduleCache: false,
        isBeforeSemesterStart: true,
        currentWeek: 1,
        semesterStartDate: semesterStart,
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.beforeSemester);
      expect(presentation.hero.headline, '距离开学还有 9 天');
    });
  });

  group('考试 Hero 与事件提醒', () {
    test('24 小时内考试且无课：进入 Hero 且不重复提醒', () {
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: const [],
        nextExam: examAt(tomorrow),
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.examSoon);
      expect(presentation.hero.headline, '明天考试');
      expect(presentation.hero.timeText, '09:00');
      expect(presentation.hero.courseName, '微观经济学');
      expect(presentation.alert, isNull);
    });

    test('今天还有课时，明天考试降级为事件提醒', () {
      final today = DateTime(2026, 9, 15);
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: [courseAt(today, startLesson: 6)],
        nextExam: examAt(tomorrow),
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseToday);
      expect(presentation.alert, isNotNull);
      expect(presentation.alert!.kind, HomeAlertKind.examSoon);
      expect(presentation.alert!.message, '明天 09:00 微观经济学考试');
      expect(presentation.alert!.routeName, 'exam');
    });

    test('已结束的今日考试不进 Hero 也不提醒', () {
      final today = DateTime(2026, 9, 15);
      // 08:00-09:25 已结束（now=10:00）。
      final snapshot = buildSnapshot(
        nextExam: examAt(today, startTime: '08:00', endTime: '09:25'),
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.noCourseToday);
      expect(presentation.hero.headline, '近期无课');
      expect(presentation.alert, isNull);
    });
  });

  group('资产状态提醒', () {
    test('低电量（≤10 度）触发提醒', () {
      final snapshot = buildSnapshot(dormElectricity: '3.2');

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.alert, isNotNull);
      expect(presentation.alert!.kind, HomeAlertKind.lowElectricity);
      expect(presentation.alert!.message, contains('电量偏低'));
      expect(presentation.alert!.routeName, 'dorm-electricity');
      expect(presentation.status.lowElectricity, isTrue);
    });

    test('电量等于 10 度触发提醒，高于阈值不触发', () {
      final boundary = resolveHomePresentation(
        buildSnapshot(dormElectricity: '10'),
      );
      expect(boundary.alert!.kind, HomeAlertKind.lowElectricity);

      final safe = resolveHomePresentation(
        buildSnapshot(dormElectricity: '42'),
      );
      expect(safe.alert, isNull);
      expect(safe.status.lowElectricity, isFalse);
    });

    test('低余额（≤¥20）不再触发提醒，状态字段恒为 false', () {
      final snapshot = buildSnapshot(campusCardBalance: '18.5');

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.alert, isNull);
      expect(presentation.status.lowBalance, isFalse);
    });

    test('数据缺失（--）不触发提醒且状态条无数据', () {
      final snapshot = buildSnapshot();

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.alert, isNull);
      expect(presentation.status.hasCampusCardData, isFalse);
      expect(presentation.status.hasElectricityData, isFalse);
      expect(presentation.status.lowBalance, isFalse);
      expect(presentation.status.lowElectricity, isFalse);
    });

    test('事件提醒优先级：考试 > 低电量', () {
      final today = DateTime(2026, 9, 15);
      final tomorrow = DateTime(2026, 9, 16);
      // 今天仍有课，考试进不了 Hero，才能以事件提醒出现。
      final withExam = resolveHomePresentation(
        buildSnapshot(
          courses: [courseAt(today, startLesson: 6)],
          nextExam: examAt(tomorrow),
          dormElectricity: '3.2',
          campusCardBalance: '5',
        ),
      );
      expect(withExam.alert!.kind, HomeAlertKind.examSoon);

      final withLowElectricity = resolveHomePresentation(
        buildSnapshot(dormElectricity: '3.2', campusCardBalance: '5'),
      );
      expect(withLowElectricity.alert!.kind, HomeAlertKind.lowElectricity);
    });

    test('低余额不触发提醒（即使电量正常、无考试）', () {
      final presentation = resolveHomePresentation(
        buildSnapshot(campusCardBalance: '5'),
      );

      expect(presentation.alert, isNull);
      expect(presentation.status.lowBalance, isFalse);
    });
  });

  group('Today / 周次派生', () {
    test('Today 只含今天未结束的课程与今日考试', () {
      final today = DateTime(2026, 9, 15);
      final snapshot = buildSnapshot(
        courses: [
          courseAt(today, startLesson: 2, courseName: '已结束的课'),
          courseAt(today, startLesson: 6, endLesson: 6, courseName: '下午的课'),
          courseAt(DateTime(2026, 9, 16), startLesson: 1),
        ],
        nextExam: examAt(today, startTime: '09:00', endTime: '11:00'),
      );

      final presentation = resolveHomePresentation(snapshot);

      // now=10:00：第 2 节 08:45-09:25 已结束，被过滤。
      expect(presentation.today.courses.map((c) => c.courseName), ['下午的课']);
      expect(presentation.today.courses.single.timeText, '13:30');
      expect(presentation.today.courses.single.lessonText, '第 6 节');
      expect(presentation.today.exams.single.courseName, '微观经济学');
      expect(presentation.today.exams.single.timeText, '09:00-11:00');
      expect(presentation.today.isEmpty, isFalse);
    });

    test('今天没课且命中日多门课：Hero 大字首课，Today 整段隐藏让位 Hero', () {
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: [
          courseAt(tomorrow, startLesson: 1, courseName: '高等数学'),
          courseAt(tomorrow, startLesson: 3, courseName: '大学英语'),
          courseAt(tomorrow, startLesson: 6, courseName: '数据结构'),
        ],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
      expect(presentation.hero.courseName, '高等数学');
      expect(presentation.hero.timeText, '明天 08:00');
      // 折叠摘要不再作为次级信息占用视觉空间,首课由 Hero 课程大字
      // 单独承接,后续课程直接进课表查看 — Today 整段隐藏。
      expect(presentation.today.isEmpty, isTrue);
      expect(presentation.today.courses, isEmpty);
    });

    test('今天没课且命中日仅一门课：Today 段落整段消失', () {
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: [courseAt(tomorrow, startLesson: 1, courseName: '高等数学')],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
      expect(presentation.today.isEmpty, isTrue);
    });

    test('未开学的开学首日预览不折叠（Hero 为倒计时）', () {
      final semesterStart = DateTime(2026, 9, 24);
      final snapshot = buildSnapshot(
        isBeforeSemesterStart: true,
        currentWeek: 1,
        semesterStartDate: semesterStart,
        courses: [
          courseAt(semesterStart, startLesson: 1, courseName: '高等数学'),
          courseAt(semesterStart, startLesson: 3, courseName: '大学英语'),
        ],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.beforeSemester);
      expect(presentation.today.title, '开学首日');
      expect(presentation.today.isCollapsed, isFalse);
      expect(presentation.today.courses.map((c) => c.courseName), [
        '高等数学',
        '大学英语',
      ]);
    });

    test('全天与非全天模式都过滤已结束课程', () {
      final today = DateTime(2026, 9, 15);
      final snapshot = buildSnapshot(
        courses: [
          courseAt(today, startLesson: 2, courseName: '已结束的课'),
          courseAt(today, startLesson: 6, endLesson: 6, courseName: '下午的课'),
        ],
      );

      final fullDay = resolveHomePresentation(snapshot, fullDayCourses: true);
      expect(fullDay.today.isFullDay, isTrue);
      expect(fullDay.today.isCollapsed, isFalse);
      expect(fullDay.today.courses.map((c) => c.courseName).toList(), ['下午的课']);
      expect(fullDay.today.courses.first.isDone, isFalse);
      expect(fullDay.today.courses.first.isOngoing, isFalse);
      expect(fullDay.today.courses.last.isDone, isFalse);

      // 关闭开关：保持原有「仅剩余课程」行为。
      final remaining = resolveHomePresentation(snapshot);
      expect(remaining.today.isFullDay, isFalse);
      expect(remaining.today.courses.map((c) => c.courseName), ['下午的课']);
    });

    test('全天模式：进行中的课不带 isDone，整段不折叠', () {
      final today = DateTime(2026, 9, 15);
      // now=10:00：第 2 节 08:45-09:25 已结束，第 3-4 节 09:45-11:10 正在上。
      final snapshot = buildSnapshot(
        courses: [
          courseAt(today, startLesson: 2, courseName: '已结束的课'),
          courseAt(today, startLesson: 3, endLesson: 4, courseName: '正在上的课'),
        ],
      );

      final presentation = resolveHomePresentation(
        snapshot,
        fullDayCourses: true,
      );

      expect(presentation.hero.kind, HomeHeroKind.currentCourse);
      expect(presentation.today.isFullDay, isTrue);
      expect(presentation.today.isCollapsed, isFalse);
      expect(presentation.today.courses.map((c) => c.isDone), [isFalse]);
      expect(presentation.today.courses.last.isOngoing, isTrue);
    });

    test('全天模式：今天完全没课时仍回落次日预览（含折叠规则）', () {
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: [
          courseAt(tomorrow, startLesson: 1, courseName: '高等数学'),
          courseAt(tomorrow, startLesson: 3, courseName: '大学英语'),
        ],
      );

      final presentation = resolveHomePresentation(
        snapshot,
        fullDayCourses: true,
      );

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
      // 今天零课程：全天形态无内容，回落次日预览并按原规则折叠让位 Hero。
      expect(presentation.today.isFullDay, isFalse);
      expect(presentation.today.isEmpty, isTrue);
    });

    test('教学周内周次标签为「第 N 周」', () {
      final snapshot = buildSnapshot(currentWeek: 2);

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.weekLabel, '第 2 周');
    });

    test('未开学时周次标签为空（环境行省略状态段）', () {
      final semesterStart = DateTime(2026, 9, 24);
      final snapshot = buildSnapshot(
        isBeforeSemesterStart: true,
        currentWeek: 1,
        semesterStartDate: semesterStart,
        courses: [courseAt(semesterStart, startLesson: 1)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.weekLabel, isEmpty);
    });
  });

  group('假期', () {
    // 2026 国庆：10/1(周四)-10/7(周三)；开学 9/7，10/2 为第 4 周周五。
    final thursday = DateTime(2026, 10, 8);
    final friday = DateTime(2026, 10, 9);

    test('国庆假期中且明天不上课：假期文案 + 恢复上课日期', () {
      final snapshot = buildSnapshot(
        now: DateTime(2026, 10, 2, 10, 0),
        currentWeek: 4,
        courses: [
          courseAt(thursday, startLesson: 1, courseName: '高等数学'),
          courseAt(friday, startLesson: 1),
        ],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.holiday);
      expect(presentation.hero.kicker, '国庆节 · 放假中');
      expect(presentation.hero.headline, isNotEmpty);
      // 假期里的周四（10/1）、周五（10/2）不算课，恢复上课日是 10/8。
      expect(presentation.hero.timeText, '10/8 周四 恢复上课');
      expect(presentation.hero.courseName, isNull);
      expect(presentation.today.isPreview, isTrue);
      expect(presentation.today.title, '10/8 周四');
      expect(presentation.today.courses.single.courseName, '高等数学');
    });

    test('法定假期首日显示节日问候', () {
      final snapshot = buildSnapshot(
        now: DateTime(2026, 10, 1, 9, 0),
        currentWeek: 4,
        courses: [courseAt(thursday, startLesson: 1)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.holiday);
      expect(presentation.hero.headline, '国庆快乐，享受假期吧～');
    });

    test('假期当天课表上的课不算「正在上课」', () {
      final snapshot = buildSnapshot(
        now: DateTime(2026, 10, 2, 8, 30),
        currentWeek: 4,
        courses: [courseAt(friday, startLesson: 1, endLesson: 2)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.holiday);
      expect(presentation.today.courses.map((row) => row.isOngoing), [false]);
    });

    test('假期最后一天、明天有课：老老实实显示下一节课', () {
      final snapshot = buildSnapshot(
        now: DateTime(2026, 10, 7, 20, 0),
        currentWeek: 5,
        courses: [courseAt(thursday, startLesson: 1, courseName: '高等数学')],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
      expect(presentation.hero.courseName, '高等数学');
      expect(presentation.hero.timeText, '明天 08:00');
    });

    test('课表推断：今天的课被停课规则全部取消且明天没课时视为放假', () {
      final wednesday = DateTime(2026, 9, 16); // 第 2 周周三
      final snapshot = buildSnapshot(
        now: DateTime(2026, 9, 16, 7, 0),
        courses: [
          courseAt(wednesday, startLesson: 1, courseName: '大学物理'),
          courseAt(DateTime(2026, 9, 18), startLesson: 3),
        ],
        changeRules: const [
          CourseChangeRule(
            type: CourseChangeType.cancel,
            originalLesson: CourseLessonSlot(
              week: 2,
              weekday: 3,
              startLesson: 1,
              endLesson: 1,
            ),
            courseName: '大学物理',
            termContext: ScheduleTermContext(academicYear: 2026, term: 3),
          ),
        ],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.holiday);
      expect(presentation.hero.kicker, '放假中');
      expect(presentation.hero.timeText, '9/18 周五 恢复上课');
    });

    test('本来就没课的普通周末不算放假', () {
      final snapshot = buildSnapshot(
        now: DateTime(2026, 9, 19, 10, 0), // 周六
        courses: [courseAt(DateTime(2026, 9, 21), startLesson: 1)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.nextCourseUpcoming);
    });
  });
}
