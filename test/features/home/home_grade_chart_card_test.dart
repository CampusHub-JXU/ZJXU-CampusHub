import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_grade_chart_card.dart';

void main() {
  testWidgets('renders grade snapshot metrics', (tester) async {
    var tapped = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: HomeGradeChartCard(
                grades: const [
                  GradeEntry(
                    courseName: '高等数学',
                    grade: '95',
                    percentageScore: '95',
                    gpaPoints: 4,
                    credits: 3,
                    academicYear: '2025-2026',
                    semester: '1',
                    examType: '正常考试',
                    assessmentMethod: '考试',
                    courseRequirement: '必修',
                  ),
                  GradeEntry(
                    courseName: '线性代数',
                    grade: '78',
                    percentageScore: '78',
                    gpaPoints: 3,
                    credits: 2,
                    academicYear: '2025-2026',
                    semester: '1',
                    examType: '正常考试',
                    assessmentMethod: '考试',
                    courseRequirement: '必修',
                  ),
                ],
                onTap: () => tapped++,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('成绩查询'), findsOneWidget);
    expect(find.text('学业概览'), findsNothing);
    expect(find.text('3.60'), findsNothing);
    expect(find.text('GPA'), findsNothing);
    expect(find.textContaining('5学分'), findsOneWidget);
    expect(find.textContaining('2门课'), findsOneWidget);

    await tester.tap(find.byType(HomeGradeChartCard));
    expect(tapped, 1);
  });

  testWidgets('renders empty grade state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: HomeGradeChartCard(grades: const [], onTap: () {}),
          ),
        ),
      ),
    );

    expect(find.text('成绩查询'), findsOneWidget);
    expect(find.text('暂无成绩数据'), findsOneWidget);
  });
}
