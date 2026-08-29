import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/exam/exam_model.dart';
import 'package:jxu_campus_hub/features/home/home_presentation_resolver.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/models/home_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';

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
      changeRules: const [],
      isBeforeSemesterStart: isBeforeSemesterStart,
      isAfterSemesterEnd: isAfterSemesterEnd,
      currentWeek: currentWeek,
      semesterStartDate: semesterStartDate ?? baseSemesterStart,
      nextExam: nextExam,
      campusCardBalance: campusCardBalance,
      dormElectricity: dormElectricity,
      learningEntries: const [],
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

    test('今天没课：显示明天第一节课预告', () {
      final tomorrow = DateTime(2026, 9, 16);
      final snapshot = buildSnapshot(
        courses: [courseAt(tomorrow, startLesson: 1, courseName: '高等数学')],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.noCourseToday);
      expect(presentation.hero.headline, '今天没课');
      expect(presentation.hero.timeText, '下一节：明天 08:00');
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

      expect(presentation.hero.kind, HomeHeroKind.noCourseToday);
      expect(presentation.hero.headline, '今天没课');
      expect(presentation.hero.timeText, isNot(contains('即将上课')));
    });

    test('未开学：距离开学倒计时 + 开学首课信息', () {
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
      expect(presentation.hero.timeText, '9月24日 08:00');
      expect(presentation.week.weekLabel, '未开学');
    });

    test('学期已结束', () {
      final snapshot = buildSnapshot(isAfterSemesterEnd: true);

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.hero.kind, HomeHeroKind.semesterOver);
      expect(presentation.hero.headline, '学期已结束');
      expect(presentation.week.weekLabel, '学期已结束');
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

    test('低余额（≤¥20）触发提醒', () {
      final snapshot = buildSnapshot(campusCardBalance: '18.5');

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.alert!.kind, HomeAlertKind.lowBalance);
      expect(presentation.alert!.message, contains('余额偏低'));
      expect(presentation.alert!.routeName, 'campus-card');
      expect(presentation.status.lowBalance, isTrue);
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

    test('事件提醒优先级：考试 > 低电量 > 低余额', () {
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

      final withLowAssets = resolveHomePresentation(
        buildSnapshot(dormElectricity: '3.2', campusCardBalance: '5'),
      );
      expect(withLowAssets.alert!.kind, HomeAlertKind.lowElectricity);

      final withLowBalance = resolveHomePresentation(
        buildSnapshot(campusCardBalance: '5'),
      );
      expect(withLowBalance.alert!.kind, HomeAlertKind.lowBalance);
    });
  });

  group('Today / Week 派生', () {
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

    test('Week 按教学周统计课程节数与考试场次', () {
      final today = DateTime(2026, 9, 15); // 周二
      final tomorrow = DateTime(2026, 9, 16); // 周三
      final snapshot = buildSnapshot(
        courses: [
          courseAt(today, startLesson: 3),
          courseAt(today, startLesson: 6, courseName: '大学英语'),
          courseAt(tomorrow, startLesson: 1),
          // 下周的课程（仅第 3 周起）不计入本周。
          courseAt(
            DateTime(2026, 9, 22),
            startLesson: 1,
            courseName: '下周的课',
            weekRange: '3-16周',
          ),
        ],
        nextExam: examAt(tomorrow),
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.week.weekLabel, '第 2 周');
      expect(presentation.week.days[today.weekday - 1].courseCount, 2);
      expect(presentation.week.days[today.weekday - 1].isToday, isTrue);
      expect(presentation.week.days[tomorrow.weekday - 1].courseCount, 1);
      expect(presentation.week.days[tomorrow.weekday - 1].examCount, 1);
      // 无课日显示 0（7 天 - 周二 - 周三 = 5 天）。
      expect(
        presentation.week.days
            .where((d) => d.courseCount == 0 && d.examCount == 0)
            .length,
        5,
      );
    });

    test('未开学时 Week 无课程统计但仍给出周次标签', () {
      final semesterStart = DateTime(2026, 9, 24);
      final snapshot = buildSnapshot(
        isBeforeSemesterStart: true,
        currentWeek: 1,
        semesterStartDate: semesterStart,
        courses: [courseAt(semesterStart, startLesson: 1)],
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.week.weekLabel, '未开学');
      expect(presentation.week.days.every((d) => d.courseCount == 0), isTrue);
    });

    test('Quick Actions：静态入口在前，目录学习入口追加其后', () {
      const learningEntries = [
        HomeQuickActionPresentation(
          label: '图书馆',
          icon: Icons.local_library_outlined,
          routeName: 'library',
        ),
      ];
      final snapshot = HomeSnapshot(
        now: baseNow,
        courseLoggedIn: true,
        hasScheduleCache: true,
        courses: const [],
        changeRules: const [],
        isBeforeSemesterStart: false,
        isAfterSemesterEnd: false,
        currentWeek: 2,
        semesterStartDate: baseSemesterStart,
        campusCardBalance: '--',
        dormElectricity: '--',
        learningEntries: learningEntries,
      );

      final presentation = resolveHomePresentation(snapshot);

      expect(presentation.quickActions.map((a) => a.label), [
        '付款码',
        '课表',
        '成绩',
        '图书馆',
      ]);
    });
  });
}
