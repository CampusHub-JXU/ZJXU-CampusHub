import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_page.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    final today = DateTime.now();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      today.year,
      today.month,
      today.day,
    );
  });

  ScheduleCacheSnapshot cachedSnapshotFor(
    String studentId,
    String courseName,
    ScheduleTermContext termContext,
  ) {
    return ScheduleCacheSnapshot(
      studentId: studentId,
      termContext: termContext,
      courses: [
        CourseEntry(
          courseName: courseName,
          teacherName: '教师',
          weekday: 1,
          startLesson: 1,
          endLesson: 2,
          weekRange: '1-18周',
          classroom: '101',
          campus: '梁林校区',
          typeSymbol: '',
        ),
      ],
      scheduleUpdatedAt: DateTime.now(),
      changeRulesUpdatedAt: DateTime.now(),
    );
  }

  testWidgets('shows course change reminders above the schedule grid', (
    tester,
  ) async {
    final now = DateTime.now();
    final termContext = ScheduleTermContext.current(now);

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: '2025000001',
        termContext: termContext,
        courses: const [
          CourseEntry(
            courseName: 'AI+创新创业基础',
            teacherName: '胡亚楠',
            weekday: 5,
            startLesson: 8,
            endLesson: 9,
            weekRange: '1-18周',
            classroom: '铭德楼468',
            campus: '梁林校区',
            typeSymbol: '',
          ),
        ],
        changeRules: [
          CourseChangeRule(
            type: CourseChangeType.reschedule,
            originalLesson: CourseLessonSlot(
              week: 5,
              weekday: 4,
              startLesson: 8,
              endLesson: 9,
            ),
            targetLesson: CourseLessonSlot(
              week: 5,
              weekday: 5,
              startLesson: 8,
              endLesson: 9,
            ),
            courseName: 'AI+创新创业基础',
            teacherName: '胡亚楠',
            classroom: '铭德楼468',
            termContext: termContext,
          ),
        ],
        scheduleUpdatedAt: now,
        changeRulesUpdatedAt: now,
        changeRulesCurrentScoped: true,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byTooltip('调课提醒'), findsOneWidget);
    expect(find.text('已根据这些提醒自动修正课表显示'), findsNothing);

    // 页面在登录态下会保留一个后台刷新（顶部线性进度条持续动画），
    // 因此用固定时长 pump 完成弹层入场，而不是 pumpAndSettle。
    await tester.tap(find.byTooltip('调课提醒'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('调课提醒'), findsOneWidget);
    expect(find.text('AI+创新创业基础'), findsWidgets);
    expect(find.textContaining('第5周 周四 第8-9节 -> 第5周 周五 第8-9节'), findsOneWidget);
    expect(find.text('胡亚楠'), findsWidgets);
    expect(find.text('教室：铭德楼468'), findsOneWidget);
  });

  testWidgets('switching accounts replaces the visible schedule immediately', (
    tester,
  ) async {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', 'A班专属课程', termContext),
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000002', 'B班专属课程', termContext),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    expect(find.text('A班专属课程'), findsWidgets);
    expect(find.text('B班专属课程'), findsNothing);

    // 切账号必须让页面收到身份通知（debugSetSession 只改状态不通知）。
    await ZhengfangAuth.instance.markLoggedOut();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000002',
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    expect(find.text('B班专属课程'), findsWidgets);
    expect(find.text('A班专属课程'), findsNothing);
  });

  testWidgets('switching terms from the menu shows the selected term cache', (
    tester,
  ) async {
    final current = ScheduleTermContext.current();
    final other = current.copyWith(term: current.term == 3 ? 12 : 3);
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', '本学期专属课程', current),
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', '另一学期专属课程', other),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    expect(find.text('本学期专属课程'), findsWidgets);

    await tester.tap(find.byTooltip('切换学期'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(other.term == 12 ? '第二学期' : '第一学期'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('另一学期专属课程'), findsWidgets);
    expect(find.text('本学期专属课程'), findsNothing);
  });

  Future<void> pumpLoginView(
    WidgetTester tester, {
    required bool automaticLoginPaused,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildScheduleLoginView(
            automaticLoginPaused: automaticLoginPaused,
            onAction: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('paused automatic login shows manual-login guidance', (
    tester,
  ) async {
    await pumpLoginView(tester, automaticLoginPaused: true);

    expect(find.text('需要手动登录'), findsOneWidget);
    expect(find.textContaining('自动登录已暂停'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('登录后查看课表'), findsNothing);
  });

  testWidgets('not paused keeps the original login guidance', (tester) async {
    await pumpLoginView(tester, automaticLoginPaused: false);

    expect(find.text('登录后查看课表'), findsOneWidget);
    expect(find.textContaining('课表刷新依赖教务系统会话'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('需要手动登录'), findsNothing);
  });
}
