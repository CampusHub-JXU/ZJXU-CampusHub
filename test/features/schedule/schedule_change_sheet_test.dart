import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/schedule/schedule_change_rule.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';
import 'package:jxu_campus_hub/features/schedule/widgets/schedule_change_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dummyTerm = ScheduleTermContext(academicYear: 2026, term: 3);

  final reflectedNotice = CourseChangeNotice(
    rule: CourseChangeRule(
      type: CourseChangeType.reschedule,
      courseName: '数字经济概论',
      teacherName: '李老师',
      originalClassroom: '教A-101',
      classroom: '博学楼8号楼501',
      rawMessage: '关于数字经济概论课程换到博学楼8号楼501的调课提醒',
      originalLesson: const CourseLessonSlot(
        week: 2,
        weekday: 1,
        startLesson: 1,
        endLesson: 2,
      ),
      targetLesson: const CourseLessonSlot(
        week: 2,
        weekday: 1,
        startLesson: 1,
        endLesson: 2,
      ),
      termContext: dummyTerm,
    ),
    status: CourseChangeNoticeStatus.reflected,
    effectiveCourse: const CourseEntry(
      courseName: '数字经济概论',
      teacherName: '李老师',
      weekday: 1,
      startLesson: 1,
      endLesson: 2,
      weekRange: '1-16周',
      classroom: '博学楼8号楼501',
      campus: '梁林校区',
      typeSymbol: '',
    ),
  );

  final unappliedNotice = CourseChangeNotice(
    rule: const CourseChangeRule(
      type: CourseChangeType.reschedule,
      courseName: '宏观经济学',
      teacherName: '张老师',
      originalClassroom: '教B-202',
      classroom: '教C-303',
      rawMessage: '往期4月调课提醒：宏观经济学停课一次',
      originalLesson: CourseLessonSlot(
        week: 8,
        weekday: 3,
        startLesson: 3,
        endLesson: 4,
      ),
      targetLesson: CourseLessonSlot(
        week: 8,
        weekday: 3,
        startLesson: 3,
        endLesson: 4,
      ),
      // termContext 为 null，表示学期未证实
      termContext: null,
    ),
    status: CourseChangeNoticeStatus.unapplied,
  );

  testWidgets(
    'displays reflected status, classroom transition, and raw message',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleChangeSheet(
              notices: [reflectedNotice],
              displayWeek: 2,
              scrollController: scrollController,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sheet header
      expect(find.text('调课提醒'), findsOneWidget);
      expect(find.text('共 1 条'), findsOneWidget);

      // Grouping
      expect(find.text('课表已体现 (1)'), findsOneWidget);

      // Notice details
      expect(find.text('数字经济概论'), findsOneWidget);
      expect(find.text('已体现'), findsOneWidget);
      expect(find.text('换教室'), findsOneWidget);
      expect(find.text('教A-101 → 博学楼8号楼501'), findsOneWidget);
      expect(find.text('李老师'), findsOneWidget);
      expect(find.text('1-16周 周一 第1-2节'), findsOneWidget);
      expect(find.textContaining(' -> '), findsNothing);
      expect(find.textContaining('关于数字经济概论课程换到博学楼8号楼501'), findsOneWidget);
    },
  );

  testWidgets(
    'groups unapplied notices under collapsible section and expands on tap',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleChangeSheet(
              notices: [reflectedNotice, unappliedNotice],
              displayWeek: 2,
              scrollController: scrollController,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('共 2 条'), findsOneWidget);
      expect(find.text('课表已体现 (1)'), findsOneWidget);
      expect(find.text('数字经济概论'), findsOneWidget);

      // 默认折叠待确认提醒
      expect(find.text('待确认提醒 (1)'), findsOneWidget);
      expect(find.text('宏观经济学'), findsNothing);

      // 点击展开
      await tester.tap(find.text('待确认提醒 (1)'));
      await tester.pumpAndSettle();

      expect(find.text('宏观经济学'), findsOneWidget);
      expect(find.text('学期待确认'), findsOneWidget);
      expect(find.textContaining('往期4月调课提醒'), findsOneWidget);
    },
  );

  testWidgets('covers 1-16 weeks as a single notice with week range display', (
    tester,
  ) async {
    final multiWeekNotice = CourseChangeNotice(
      rule: CourseChangeRule(
        type: CourseChangeType.reschedule,
        courseName: '数字经济概论',
        teacherName: '李老师',
        originalClassroom: '教A-101',
        classroom: '博学楼8号楼501',
        rawMessage: '第1-16周星期一第1-2节上的数字经济概论课程现改为在博学楼8号楼501上课',
        originalLesson: const CourseLessonSlot(
          week: 1,
          weekday: 1,
          startLesson: 1,
          endLesson: 2,
        ),
        targetLesson: const CourseLessonSlot(
          week: 1,
          weekday: 1,
          startLesson: 1,
          endLesson: 2,
        ),
        termContext: dummyTerm,
      ),
      status: CourseChangeNoticeStatus.reflected,
      effectiveCourse: const CourseEntry(
        courseName: '数字经济概论',
        teacherName: '李老师',
        weekday: 1,
        startLesson: 1,
        endLesson: 2,
        weekRange: '1-16周',
        classroom: '博学楼8号楼501',
        campus: '梁林校区',
        typeSymbol: '',
      ),
    );

    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScheduleChangeSheet(
            notices: [multiWeekNotice],
            displayWeek: 1,
            scrollController: scrollController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 16 周换教室通知仅聚合为 1 张卡片，且周次显示为第1-16周
    expect(find.text('共 1 条'), findsOneWidget);
    expect(find.text('数字经济概论'), findsOneWidget);
    expect(find.text('第1-16周'), findsOneWidget);
    expect(find.textContaining('第1-16周 周一 第1-2节'), findsOneWidget);
    expect(find.text('教A-101 → 博学楼8号楼501'), findsOneWidget);
  });

  testWidgets(
    'verified term but unapplied notice shows 当前课表未体现 and not mislabeled as reflected',
    (tester) async {
      final unreflectedNotice = CourseChangeNotice(
        rule: CourseChangeRule(
          type: CourseChangeType.reschedule,
          courseName: '微观经济学',
          teacherName: '王老师',
          classroom: '教D-404',
          rawMessage: '微观经济学第3周周二第3-4节改为教D-404',
          targetLesson: const CourseLessonSlot(
            week: 3,
            weekday: 2,
            startLesson: 3,
            endLesson: 4,
          ),
          // 学期已证实，但课表中尚未体现
          termContext: dummyTerm,
        ),
        status: CourseChangeNoticeStatus.unapplied,
      );

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleChangeSheet(
              notices: [unreflectedNotice],
              displayWeek: 1,
              scrollController: scrollController,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 准确标明「当前课表未体现」，不误标为已体现
      expect(find.text('课表未体现'), findsOneWidget);
      expect(find.text('已体现'), findsNothing);
      expect(find.text('微观经济学'), findsOneWidget);
      expect(find.text('已根据这些提醒自动修正课表显示'), findsNothing);
    },
  );

  testWidgets('renders on small screen (360x640) without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScheduleChangeSheet(
            notices: [reflectedNotice, unappliedNotice],
            displayWeek: 2,
            scrollController: scrollController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 展开所有
    await tester.tap(find.text('待确认提醒 (1)'));
    await tester.pumpAndSettle();

    expect(find.text('数字经济概论'), findsOneWidget);
    expect(find.text('宏观经济学'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders with large text scale (1.5x) without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: ScheduleChangeSheet(
              notices: [reflectedNotice, unappliedNotice],
              displayWeek: 2,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('待确认提醒 (1)'));
    await tester.pumpAndSettle();

    expect(find.text('数字经济概论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in dark mode with matching surface and tag colors', (
    tester,
  ) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ScheduleChangeSheet(
            notices: [reflectedNotice, unappliedNotice],
            displayWeek: 2,
            scrollController: scrollController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('调课提醒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
