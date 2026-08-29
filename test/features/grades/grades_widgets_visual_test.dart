import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_score_palette.dart';
import 'package:jxu_campus_hub/features/grades/widgets/grades_distribution_card.dart';
import 'package:jxu_campus_hub/features/grades/widgets/grades_grade_card.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';

import '../../helpers/pump_app.dart';

GradeEntry _entry({
  required String course,
  required String score,
  String grade = '95',
}) => GradeEntry(
  courseName: course,
  grade: grade,
  percentageScore: score,
  gpaPoints: 3.5,
  credits: 2,
  academicYear: '2025-2026',
  semester: '第二学期',
  examType: '',
  assessmentMethod: '考试',
  courseRequirement: '',
);

void main() {
  testWidgets('grade card renders on AppCard and colors score from palette', (
    tester,
  ) async {
    ColorScheme? captured;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          captured = Theme.of(context).colorScheme;
          return GradesGradeCard(
            grade: _entry(course: '高等数学A', score: '95'),
          );
        },
      ),
    );

    final cs = captured!;
    expect(find.byType(AppCard), findsOneWidget);
    // 分数数字颜色来自分段 token（优），不再使用硬编码蓝/绿。
    final scoreText = tester.widget<Text>(find.text('95'));
    expect(scoreText.style?.color, gradeBandColorForScore(cs, 95));
    // 学分角标沿用同一分段色的降透明度。
    final creditText = tester.widget<Text>(find.text('2学分'));
    expect(
      creditText.style?.color,
      gradeBandColorForScore(cs, 95).withValues(alpha: 0.75),
    );
  });

  testWidgets('distribution card bars share the score palette tokens', (
    tester,
  ) async {
    ColorScheme? captured;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          captured = Theme.of(context).colorScheme;
          return GradesDistributionCard(
            grades: [
              _entry(course: '高等数学A', score: '95', grade: '95'),
              _entry(course: '体育', score: '40', grade: '40'),
            ],
          );
        },
      ),
    );

    final cs = captured!;
    expect(find.text('优'), findsOneWidget);
    expect(find.text('不及格'), findsOneWidget);
    expect(find.byType(AppCard), findsOneWidget);

    final excellentBar = gradeBandColorForScore(cs, 95).withValues(alpha: 0.6);
    final failBar = gradeBandColorForScore(cs, 40).withValues(alpha: 0.6);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).color == excellentBar,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).color == failBar,
      ),
      findsOneWidget,
    );
  });

  testWidgets('grade visuals render in dark mode without exceptions', (
    tester,
  ) async {
    ColorScheme? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = Theme.of(context).colorScheme;
              return ListView(
                children: [
                  GradesGradeCard(
                    grade: _entry(course: '高等数学A', score: '95'),
                  ),
                  GradesDistributionCard(
                    grades: [
                      _entry(course: '高等数学A', score: '95', grade: '95'),
                      _entry(course: '体育', score: '40', grade: '40'),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final cs = captured!;
    final scoreText = tester.widget<Text>(find.text('95'));
    expect(scoreText.style?.color, gradeBandColorForScore(cs, 95));
    // 暗色下各分段色在深背景上保持可读（亮度不低于 0.4）。
    for (final band in GradeBand.values) {
      expect(
        HSLColor.fromColor(gradeBandColor(cs, band)).lightness,
        greaterThanOrEqualTo(0.4),
      );
    }
  });
}
