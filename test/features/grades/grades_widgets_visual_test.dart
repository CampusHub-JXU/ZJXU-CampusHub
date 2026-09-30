import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_score_palette.dart';
import 'package:jxu_campus_hub/features/grades/widgets/grades_course_row.dart';
import 'package:jxu_campus_hub/features/grades/widgets/grades_distribution_bar.dart';

import '../../helpers/pump_app.dart';

GradeEntry _entry({
  required String course,
  required String score,
  String? grade,
  double credits = 2,
  double gpa = 3.5,
}) => GradeEntry(
  courseName: course,
  grade: grade ?? score,
  percentageScore: score,
  gpaPoints: gpa,
  credits: credits,
  academicYear: '2025-2026',
  semester: '第二学期',
  examType: '',
  assessmentMethod: '考试',
  courseRequirement: '',
);

void main() {
  testWidgets('course row shows meta line and colors only the extremes', (
    tester,
  ) async {
    ColorScheme? captured;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          captured = Theme.of(context).colorScheme;
          return Column(
            children: [
              GradesCourseRow(
                grade: _entry(course: '高等数学A', score: '95', credits: 4),
              ),
              GradesCourseRow(grade: _entry(course: '大学物理', score: '82')),
              GradesCourseRow(grade: _entry(course: '体育', score: '52')),
            ],
          );
        },
      ),
    );

    final cs = captured!;
    expect(find.text('4 学分 · 考试 · 绩点 3.5'), findsOneWidget);
    expect(tester.widget<Text>(find.text('95')).style?.color, cs.primary);
    expect(tester.widget<Text>(find.text('82')).style?.color, cs.onSurface);
    expect(tester.widget<Text>(find.text('52')).style?.color, cs.error);
  });

  testWidgets('course row colors letter grades by band', (tester) async {
    ColorScheme? captured;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          captured = Theme.of(context).colorScheme;
          return Column(
            children: [
              GradesCourseRow(
                grade: _entry(course: '形势与政策', score: '', grade: '优秀'),
              ),
              GradesCourseRow(
                grade: _entry(course: '军事理论', score: '', grade: '不及格'),
              ),
            ],
          );
        },
      ),
    );

    final cs = captured!;
    expect(tester.widget<Text>(find.text('优秀')).style?.color, cs.primary);
    expect(tester.widget<Text>(find.text('不及格')).style?.color, cs.error);
  });

  testWidgets('distribution bar omits empty bands and uses theme colors', (
    tester,
  ) async {
    ColorScheme? captured;
    await pumpApp(
      tester,
      Builder(
        builder: (context) {
          captured = Theme.of(context).colorScheme;
          return const GradesDistributionBar(
            bandCounts: {
              GradeBand.excellent: 3,
              GradeBand.good: 4,
              GradeBand.medium: 0,
              GradeBand.pass: 1,
              GradeBand.fail: 1,
            },
          );
        },
      ),
    );

    final cs = captured!;
    expect(find.text('优 3'), findsOneWidget);
    expect(find.text('良 4'), findsOneWidget);
    expect(find.text('及格 1'), findsOneWidget);
    expect(find.text('不及格 1'), findsOneWidget);
    // 数量为 0 的「中」在条与图例中都省略。
    expect(find.textContaining('中 '), findsNothing);
    expect(find.byKey(const ValueKey('grades_band_medium')), findsNothing);

    Color segment(GradeBand band) => tester
        .widget<ColoredBox>(find.byKey(ValueKey('grades_band_${band.name}')))
        .color;
    expect(segment(GradeBand.excellent), cs.primary);
    expect(segment(GradeBand.good), cs.primary.withValues(alpha: 0.6));
    expect(segment(GradeBand.pass), cs.outline);
    expect(segment(GradeBand.fail), cs.error);

    // 堆叠条 8 高，宽度按数量比例分配。
    final bar = tester.getSize(
      find.byKey(const ValueKey('grades_band_good')),
    );
    expect(bar.height, 8);
    final excellentWidth = tester
        .getSize(find.byKey(const ValueKey('grades_band_excellent')))
        .width;
    expect(bar.width, greaterThan(excellentWidth));
  });

  testWidgets('grade visuals render in dark mode at 360px and 1.3x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ColorScheme? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8B1A2D),
            brightness: Brightness.dark,
          ),
        ),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(1.3),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) {
                captured = Theme.of(context).colorScheme;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    GradesCourseRow(
                      grade: _entry(
                        course: '一门名字非常非常长的专业核心课程实验与实践',
                        score: '95',
                        credits: 4.5,
                      ),
                      termLabel: '2025–26 春',
                    ),
                    const SizedBox(height: 8),
                    const GradesDistributionBar(
                      bandCounts: {
                        GradeBand.excellent: 1,
                        GradeBand.good: 1,
                        GradeBand.medium: 1,
                        GradeBand.pass: 1,
                        GradeBand.fail: 1,
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.text('95')).style?.color, captured!.primary);
  });
}
