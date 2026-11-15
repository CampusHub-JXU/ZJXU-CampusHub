import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_date_override.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_page.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/widgets/schedule_course_edit_sheet.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const studentId = '2025000001';
  const courseName = '高等数学编辑测试';

  setUp(() async {
    await resetTestEnvironment();
    // 今天即开学日：本周 = 第 1 教学周。
    final today = DateTime.now();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      today.year,
      today.month,
      today.day,
    );
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: studentId);
  });

  ScheduleCacheSnapshot snapshotWith({
    required List<CourseEntry> courses,
    List<ScheduleDateOverride> dateOverrides = const [],
  }) {
    return ScheduleCacheSnapshot(
      studentId: studentId,
      termContext: ScheduleTermContext.current(),
      courses: courses,
      dateOverrides: dateOverrides,
      scheduleUpdatedAt: DateTime.now(),
    );
  }

  CourseEntry courseAt({
    int weekday = 3,
    int start = 1,
    int end = 2,
    String? name,
    String weekRange = '1-18周',
  }) {
    return CourseEntry(
      courseName: name ?? courseName,
      teacherName: '张老师',
      weekday: weekday,
      startLesson: start,
      endLesson: end,
      weekRange: weekRange,
      classroom: 'B101',
      campus: '梁林校区',
      typeSymbol: '',
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    final media = MediaQueryData.fromView(tester.view);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: media.copyWith(disableAnimations: disableAnimations),
          child: const SchedulePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 持久化经 `SharedPreferences` 插件通道：fake-async 区的 pump 只推进
  /// 假时钟微任务，真实事件循环上的通道响应要经 `runAsync` 才能落回。
  /// 每次触发写盘的动作后调用，保证保存/回退完整走完。
  Future<void> flushAsync(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  List<ScheduleDateOverride> persistedOverrides() {
    return ScheduleService.instance
            .preferredSnapshot(
              studentId: studentId,
              termContext: ScheduleTermContext.current(),
            )
            ?.dateOverrides ??
        const [];
  }

  Future<void> enterEditMode(WidgetTester tester) async {
    await tester.longPress(find.text(courseName));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('长按本周课程进入编辑模式：提示条出现，横滑翻周被锁', (tester) async {
    ScheduleService.instance.debugSetSnapshot(
      snapshotWith(courses: [courseAt()]),
    );
    await pumpPage(tester);

    expect(find.text(courseName), findsWidgets);
    await enterEditMode(tester);

    expect(find.text('按住拖动课程块调整时间，轻触编辑地点与老师'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());

    // 「完成」退出后恢复可滑动。
    await tester.tap(find.text('完成'));
    await tester.pump();
    expect(find.text('按住拖动课程块调整时间，轻触编辑地点与老师'), findsNothing);
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<ClampingScrollPhysics>(),
    );
  });

  testWidgets('非本周灰块不参与编辑：长按不进入编辑模式', (tester) async {
    ScheduleService.instance.debugSetSnapshot(
      snapshotWith(
        courses: [
          // 只在第 2 周开课：第 1 周视图里是非本周灰块（距展示周 ≤3 周才会显示）。
          courseAt(weekRange: '2周'),
        ],
      ),
    );
    await pumpPage(tester);

    expect(find.text(courseName), findsWidgets);
    await tester.longPress(find.text(courseName));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('按住拖动课程块调整时间，轻触编辑地点与老师'), findsNothing);
  });

  testWidgets('移除动画开启时不启动抖动，改用主色描边高亮', (tester) async {
    ScheduleService.instance.debugSetSnapshot(
      snapshotWith(courses: [courseAt()]),
    );
    await pumpPage(tester, disableAnimations: true);

    await enterEditMode(tester);

    expect(find.byKey(const ValueKey('schedule-wiggle')), findsNothing);
    expect(
      find.byKey(const ValueKey('schedule-edit-highlight')),
      findsOneWidget,
    );
  });

  testWidgets('编辑模式点击课程打开编辑弹层，修改地点与老师并持久化', (tester) async {
    ScheduleService.instance.debugSetSnapshot(
      snapshotWith(courses: [courseAt()]),
    );
    await pumpPage(tester);
    await enterEditMode(tester);

    await tester.tap(find.text(courseName));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ScheduleCourseEditSheet), findsOneWidget);
    expect(find.text('保存调整'), findsOneWidget);
    // 尚未调整过：没有快捷回退入口。
    expect(find.text('恢复原课'), findsNothing);

    // 字段标题外置后按弹层内顺序定位：第 1 个输入框是「上课地点」，
    // 第 2 个是「任课教师」。
    final fields = find.descendant(
      of: find.byType(ScheduleCourseEditSheet),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '新教楼C303');
    await tester.enterText(fields.at(1), '李老师');
    // 按钮位于弹层滚动区末尾，先滚入视野再点。
    await tester.ensureVisible(find.text('保存调整'));
    await tester.pump();
    await tester.tap(find.text('保存调整'));
    await flushAsync(tester);
    // 弹层退出动画完成后再断言关闭。
    await tester.pump(const Duration(milliseconds: 400));

    // 保存成功后弹层关闭；仍开着说明保存被拒绝（身份失效）。
    expect(find.byType(ScheduleCourseEditSheet), findsNothing);
    final overrides = persistedOverrides();
    expect(overrides, hasLength(1));
    final override = overrides.single;
    // 时间未改：目标落点保持原课程位置，源字段指向权威原课。
    expect(override.sourceWeekday, 3);
    expect(override.sourceStartLesson, 1);
    expect(override.sourceEndLesson, 2);
    expect(override.sourceCourseName, courseName);
    expect(override.targetWeekday, 3);
    expect(override.targetClassroom, '新教楼C303');
    expect(override.targetTeacherName, '李老师');

    // 已调课程指示点（虚线描边 + 右上角圆点）出现在课程块上。
    expect(
      find.byKey(const ValueKey('schedule-override-indicator')),
      findsOneWidget,
    );
  });

  testWidgets('已手动调整的课程：详情弹层可一键快捷回退', (tester) async {
    ScheduleService.instance.debugSetSnapshot(
      snapshotWith(
        courses: [courseAt()],
        dateOverrides: [
          ScheduleDateOverride(
            id: 'o1',
            sourceDate: '2026-01-07',
            sourceWeek: 1,
            sourceWeekday: 3,
            sourceStartLesson: 1,
            sourceEndLesson: 2,
            sourceCourseName: courseName,
            sourceTeacherName: '张老师',
            sourceClassroom: 'B101',
            targetDate: '2026-01-09',
            targetWeek: 1,
            targetWeekday: 5,
            targetStartLesson: 3,
            targetEndLesson: 4,
            targetClassroom: 'C303',
            targetTeacherName: '张老师',
            updatedAt: DateTime.now(),
          ),
        ],
      ),
    );
    await pumpPage(tester);

    // 合成课程落在目标槽位，徽标可辨。
    expect(find.text(courseName), findsWidgets);
    expect(
      find.byKey(const ValueKey('schedule-override-indicator')),
      findsOneWidget,
    );

    await tester.tap(find.text(courseName));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('已手动调整'), findsOneWidget);

    await tester.ensureVisible(find.text('快捷回退'));
    await tester.pump();
    await tester.tap(find.text('快捷回退'));
    await flushAsync(tester);

    expect(persistedOverrides(), isEmpty);
    expect(
      find.byKey(const ValueKey('schedule-override-indicator')),
      findsNothing,
    );
  });

  testWidgets('触控拖动课程到其它星期与节次：落点持久化为新时间', (tester) async {
    ScheduleService.instance.debugSetSnapshot(
      snapshotWith(courses: [courseAt()]),
    );
    await pumpPage(tester);
    await enterEditMode(tester);

    // 课程在周三（第 3 列）第 1-2 节；向右拖 2 列 → 周五，向下 1 格 → 第 2-3 节。
    final center = tester.getCenter(find.text(courseName));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));

    final gridWidth = tester.getSize(find.byType(PageView)).width;
    final columnWidth = (gridWidth - 30) / 7;
    await gesture.moveBy(Offset(columnWidth * 2, 68));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await gesture.up();
    await flushAsync(tester);

    final overrides = persistedOverrides();
    expect(overrides, hasLength(1));
    final override = overrides.single;
    expect(override.targetWeekday, 5);
    expect(override.targetStartLesson, 2);
    expect(override.targetEndLesson, 3, reason: '节数跨度保持 2 节');
    // 源字段永远指向权威原课。
    expect(override.sourceWeekday, 3);
    expect(override.sourceStartLesson, 1);
    expect(override.sourceEndLesson, 2);
  });
}
