import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/widgets/schedule_course_cell.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_dialog_route.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('课程详情弹层：拖拽把手在玻璃表面内，标题位于把手下方并留白', (tester) async {
    const course = CourseEntry(
      courseName: '形势与政策3',
      teacherName: '张老师',
      weekday: 1,
      startLesson: 1,
      endLesson: 2,
      weekRange: '1-8周',
      classroom: '博学楼101',
      campus: '南湖校区',
      typeSymbol: '◆',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: ScheduleCourseCell(
              course: course,
              span: 2,
              color: Colors.blue,
              dayColumnWidth: 80,
              isCurrentWeek: true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ScheduleCourseCell));
    await tester.pumpAndSettle();

    final surface = find.byType(GlassOverlaySurface);
    expect(surface, findsOneWidget);
    final handle = find.descendant(
      of: surface,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints?.minWidth == 32 &&
            w.constraints?.minHeight == 4,
      ),
    );
    expect(handle, findsOneWidget);
    final title = find.descendant(of: surface, matching: find.text('形势与政策3'));
    expect(title, findsOneWidget);

    final surfaceRect = tester.getRect(surface);
    final handleRect = tester.getRect(handle);
    final titleRect = tester.getRect(title);

    // 把手完整位于表面之内，且离顶边有正常留白。
    expect(handleRect.top, greaterThanOrEqualTo(surfaceRect.top + 8));
    expect(handleRect.bottom, lessThan(surfaceRect.bottom));
    expect(handleRect.left, greaterThanOrEqualTo(surfaceRect.left));
    expect(handleRect.right, lessThanOrEqualTo(surfaceRect.right));
    // 标题在把手下方，间距舒适（不贴把手）。
    expect(titleRect.top - handleRect.bottom, greaterThanOrEqualTo(16));
  });
}
