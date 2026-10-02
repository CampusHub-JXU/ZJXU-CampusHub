import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_model.dart';
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_page.dart';

import '../../helpers/test_setup.dart';

const _report = AcademicProgressReport(
  summary: AcademicProgressSummary(
    gpa: '3.120',
    planTotal: 80,
    planPassed: 20,
    planFailed: 2,
    planNotTaken: 48,
    studying: 10,
  ),
  roots: [
    RequirementNode(
      id: 'root',
      name: '主修',
      children: [
        RequirementNode(
          id: 'must',
          name: '必修课合计',
          requiredCredits: 120,
          earnedCredits: 40,
          children: [
            RequirementNode(
              id: 'leaf1',
              name: '其他必修课',
              requiredCredits: 56,
              earnedCredits: 32,
              courseAttribute: '1',
              isLeaf: true,
              serverPassedCount: 1,
              courses: [
                AcademicProgressCourse(
                  courseCode: '1',
                  courseName: '高等数学C1',
                  status: CourseStudyStatus.failed,
                  credits: 4,
                  score: '55',
                ),
                AcademicProgressCourse(
                  courseCode: '2',
                  courseName: '体育3',
                  status: CourseStudyStatus.notTaken,
                  credits: 1,
                ),
                AcademicProgressCourse(
                  courseCode: '3',
                  courseName: '体育1',
                  status: CourseStudyStatus.passed,
                  credits: 1,
                  score: '70',
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    RequirementNode(
      id: RequirementNode.innovationId,
      name: '创新创业情况',
      isLeaf: true,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AcademicProgressPage(
          fetchReport: ({bool forceRefresh = false}) async => _report,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('展示 GPA、类别学分与创新创业空态', (tester) async {
    await pumpPage(tester);

    expect(find.text('3.120'), findsOneWidget);
    expect(find.text('必修课合计 · 40/120 学分'), findsOneWidget);
    expect(find.text('其他必修课'), findsOneWidget);
    expect(find.text('共 3 门 · 通过 1 门'), findsOneWidget);
    expect(find.text('尚无数据信息'), findsOneWidget);
    // 课程默认收起。
    expect(find.text('高等数学C1'), findsNothing);
  });

  testWidgets('点击类别展开课程', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('其他必修课'));
    await tester.pump();

    expect(find.text('高等数学C1'), findsOneWidget);
    expect(find.text('55'), findsOneWidget);
  });

  testWidgets('按状态筛选平铺课程', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('未修 1'));
    await tester.pump();

    expect(find.text('体育3'), findsOneWidget);
    expect(find.text('高等数学C1'), findsNothing);
    expect(find.text('未修 · 1 门 · 1 学分'), findsOneWidget);
  });
}
