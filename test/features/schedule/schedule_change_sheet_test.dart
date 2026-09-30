import 'dart:io';

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


  Future<void> pumpSheet(
    WidgetTester tester,
    List<CourseChangeNotice> notices, {
    int displayWeek = 2,
    int? currentWeek,
    ThemeData? theme,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: ScheduleChangeSheet(
            notices: notices,
            displayWeek: displayWeek,
            currentWeek: currentWeek,
            scrollController: scrollController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('reflected room change: segment, single room line, raw folded', (
    tester,
  ) async {
    await pumpSheet(tester, [reflectedNotice]);

    expect(find.text('调课提醒'), findsOneWidget);
    expect(find.text('共 1 条'), findsOneWidget);
    expect(find.text('已显示 1'), findsOneWidget);
    expect(find.text('待确认 0'), findsOneWidget);

    expect(find.text('数字经济概论'), findsOneWidget);
    expect(find.text('换教室'), findsOneWidget);
    expect(find.text('李老师'), findsOneWidget);
    expect(
      find.textContaining('第1-16周 周一 1–2 节  教A-101 → 博学楼8号楼501'),
      findsOneWidget,
    );
    expect(find.textContaining(' -> '), findsNothing);

    // 原文默认收起。
    expect(find.textContaining('关于数字经济概论课程换到'), findsNothing);
    await tester.tap(find.text('查看原文'));
    await tester.pumpAndSettle();
    expect(find.textContaining('关于数字经济概论课程换到'), findsOneWidget);
    expect(find.text('收起原文'), findsOneWidget);
  });

  testWidgets('segments show one group at a time, pending cards explain why', (
    tester,
  ) async {
    await pumpSheet(tester, [reflectedNotice, unappliedNotice]);

    expect(find.text('共 2 条'), findsOneWidget);
    // 有已显示项时默认看已显示。
    expect(find.text('数字经济概论'), findsOneWidget);
    expect(find.text('宏观经济学'), findsNothing);

    await tester.tap(find.text('待确认 1'));
    await tester.pumpAndSettle();

    expect(find.text('数字经济概论'), findsNothing);
    expect(find.text('宏观经济学'), findsOneWidget);
    expect(find.text('换教室 · 待确认'), findsOneWidget);
    expect(find.text('学期未标注，请核对原文'), findsOneWidget);

    await tester.tap(find.text('查看原文'));
    await tester.pumpAndSettle();
    expect(find.textContaining('往期4月调课提醒'), findsOneWidget);
  });

  testWidgets('only pending notices selects the pending segment by default', (
    tester,
  ) async {
    await pumpSheet(tester, [unappliedNotice]);

    expect(find.text('宏观经济学'), findsOneWidget);
    final segments = tester.widget<SegmentedButton<CourseChangeNoticeStatus>>(
      find.byKey(const Key('schedule_change_segments')),
    );
    expect(segments.selected, {CourseChangeNoticeStatus.unapplied});
  });

  testWidgets('current week shows 本周 header and omits this week in slots', (
    tester,
  ) async {
    await pumpSheet(tester, [unappliedNotice], displayWeek: 8, currentWeek: 8);

    expect(find.text('本周 · 第 8 周'), findsOneWidget);
    expect(find.textContaining('共 '), findsNothing);
    expect(
      find.textContaining('周三 3–4 节  教B-202 → 教C-303'),
      findsOneWidget,
    );
    expect(find.textContaining('第8周'), findsNothing);
  });

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
    );

    await pumpSheet(tester, [multiWeekNotice], displayWeek: 1, currentWeek: 1);

    // 16 周换教室通知仅聚合为 1 张卡片；跨周范围不等于本周，保留周次前缀。
    expect(find.text('已显示 1'), findsOneWidget);
    expect(find.text('数字经济概论'), findsOneWidget);
    expect(
      find.textContaining('第1-16周 周一 1–2 节  教A-101 → 博学楼8号楼501'),
      findsOneWidget,
    );
  });

  testWidgets(
    'verified term but unapplied notice says 课表未显示, never 已显示',
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
          // 学期已证实，但课表中尚未显示
          termContext: dummyTerm,
        ),
        status: CourseChangeNoticeStatus.unapplied,
      );

      await pumpSheet(tester, [unreflectedNotice], displayWeek: 1);

      expect(find.text('课表未显示'), findsOneWidget);
      expect(find.text('换教室 · 待确认'), findsOneWidget);
      expect(find.text('换教室'), findsNothing);
      expect(find.textContaining('第3周 周二 3–4 节  改到 教D-404'), findsOneWidget);
      expect(find.text('已根据这些提醒自动修正课表显示'), findsNothing);
    },
  );

  testWidgets('reschedule, cancel and makeup render their own layouts', (
    tester,
  ) async {
    CourseChangeNotice notice(CourseChangeRule rule) => CourseChangeNotice(
      rule: rule,
      status: CourseChangeNoticeStatus.reflected,
    );
    await pumpSheet(tester, [
      notice(
        CourseChangeRule(
          type: CourseChangeType.reschedule,
          courseName: '线性代数',
          classroom: '9-102',
          originalLesson: const CourseLessonSlot(
            week: 5,
            weekday: 4,
            startLesson: 8,
            endLesson: 9,
          ),
          targetLesson: const CourseLessonSlot(
            week: 5,
            weekday: 5,
            startLesson: 8,
            endLesson: 9,
          ),
          termContext: dummyTerm,
        ),
      ),
      notice(
        CourseChangeRule(
          type: CourseChangeType.cancel,
          courseName: '体育',
          originalLesson: const CourseLessonSlot(
            week: 5,
            weekday: 1,
            startLesson: 3,
            endLesson: 3,
          ),
          termContext: dummyTerm,
        ),
      ),
      notice(
        CourseChangeRule(
          type: CourseChangeType.makeup,
          courseName: '概率论',
          classroom: '11-210',
          targetLesson: const CourseLessonSlot(
            week: 6,
            weekday: 6,
            startLesson: 1,
            endLesson: 2,
          ),
          termContext: dummyTerm,
        ),
      ),
    ], displayWeek: 5, currentWeek: 5);

    // 调课：原/改对照，本周省略周次。
    expect(find.text('调课'), findsOneWidget);
    expect(find.text('原'), findsOneWidget);
    expect(find.text('改'), findsOneWidget);
    expect(find.text('周四 8–9 节'), findsOneWidget);
    expect(find.text('周五 8–9 节 · 9-102'), findsOneWidget);
    // 停课：删除线原时段 + 停课。
    expect(find.textContaining('周一 3 节  停课'), findsOneWidget);
    // 补课：跨周保留周次，只有「补」一行。
    expect(find.text('补'), findsOneWidget);
    expect(find.text('第6周 周六 1–2 节 · 11-210'), findsOneWidget);
  });

  group('isRoomOnlyChange', () {
    const slot = CourseLessonSlot(
      week: 2,
      weekday: 1,
      startLesson: 1,
      endLesson: 2,
    );
    const otherSlot = CourseLessonSlot(
      week: 2,
      weekday: 3,
      startLesson: 1,
      endLesson: 2,
    );

    test('same slot with a different classroom', () {
      expect(
        isRoomOnlyChange(
          const CourseChangeRule(
            type: CourseChangeType.reschedule,
            originalClassroom: 'A',
            classroom: 'B',
            originalLesson: slot,
            targetLesson: slot,
          ),
        ),
        isTrue,
      );
    });

    test('different slot, same room, cancel or missing room is not', () {
      expect(
        isRoomOnlyChange(
          const CourseChangeRule(
            type: CourseChangeType.reschedule,
            originalClassroom: 'A',
            classroom: 'B',
            originalLesson: slot,
            targetLesson: otherSlot,
          ),
        ),
        isFalse,
      );
      expect(
        isRoomOnlyChange(
          const CourseChangeRule(
            type: CourseChangeType.reschedule,
            originalClassroom: 'A',
            classroom: 'A',
            originalLesson: slot,
            targetLesson: slot,
          ),
        ),
        isFalse,
      );
      expect(
        isRoomOnlyChange(
          const CourseChangeRule(
            type: CourseChangeType.cancel,
            classroom: 'B',
            originalLesson: slot,
          ),
        ),
        isFalse,
      );
      expect(
        isRoomOnlyChange(
          const CourseChangeRule(
            type: CourseChangeType.reschedule,
            originalLesson: slot,
            targetLesson: slot,
          ),
        ),
        isFalse,
      );
    });
  });

  testWidgets('360x640 with raw message expanded has no overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpSheet(tester, [reflectedNotice, unappliedNotice]);
    await tester.tap(find.text('查看原文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待确认 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看原文'));
    await tester.pumpAndSettle();

    expect(find.text('宏观经济学'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1.5x text scale with raw message expanded has no overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpSheet(
      tester,
      [reflectedNotice, unappliedNotice],
      currentWeek: 2,
      textScaler: const TextScaler.linear(1.5),
    );
    await tester.tap(find.text('查看原文'));
    await tester.pumpAndSettle();

    expect(find.text('数字经济概论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark mode uses scheme containers for tags', (tester) async {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF8B1A2D),
        brightness: Brightness.dark,
      ),
    );
    await pumpSheet(tester, [reflectedNotice, unappliedNotice], theme: theme);

    final cs = theme.colorScheme;
    BoxDecoration tagDecoration(String label) =>
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text(label),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;

    expect(tagDecoration('换教室').color, cs.secondaryContainer);
    await tester.tap(find.text('待确认 1'));
    await tester.pumpAndSettle();
    expect(tagDecoration('换教室 · 待确认').color, cs.tertiaryContainer);
    expect(tester.takeException(), isNull);
  });

  test('sheet source contains no hard-coded Color literals', () {
    final source = File(
      'lib/features/schedule/widgets/schedule_change_sheet.dart',
    ).readAsStringSync();
    expect(source.contains('Color(0x'), isFalse);
    expect(source.contains('Colors.'), isFalse);
  });
}
