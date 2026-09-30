import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_score_palette.dart';
import 'package:jxu_campus_hub/features/grades/grades_summary.dart';
import 'package:jxu_campus_hub/features/grades/grades_term_resolver.dart';

GradeEntry _entry(
  String course, {
  String grade = '',
  String percentage = '',
  double gpa = 0,
  double credits = 2,
  String year = '2025-2026',
  String semester = '第一学期',
}) => GradeEntry(
  courseName: course,
  grade: grade.isEmpty ? percentage : grade,
  percentageScore: percentage,
  gpaPoints: gpa,
  credits: credits,
  academicYear: year,
  semester: semester,
  examType: '',
  assessmentMethod: '',
  courseRequirement: '',
);

List<String> _names(List<GradeEntry> list) => [
  for (final g in list) g.courseName,
];

void main() {
  group('computeGradesSummary', () {
    test('empty list', () {
      final s = computeGradesSummary(const []);
      expect(s.gpa, 0);
      expect(s.credits, 0);
      expect(s.averageScore, isNull);
      expect(s.courseCount, 0);
      expect(s.bandCounts.values.every((c) => c == 0), isTrue);
      expect(s.bandCounts.keys.toList(), GradeBand.values);
    });

    test('letter grades only: no average, bands counted', () {
      final s = computeGradesSummary([
        _entry('A', grade: '优秀', gpa: 4.5, credits: 1),
        _entry('B', grade: '合格'),
      ]);
      expect(s.averageScore, isNull);
      expect(s.gpa, 4.5);
      expect(s.credits, 1);
      expect(s.courseCount, 2);
      expect(s.bandCounts[GradeBand.excellent], 1);
      expect(s.bandCounts[GradeBand.pass], 1);
    });

    test('mixed: weighted GPA over gpa>0 courses, numeric average', () {
      final s = computeGradesSummary([
        _entry('A', percentage: '90', gpa: 4, credits: 3),
        _entry('B', percentage: '70', gpa: 2, credits: 1),
        _entry('C', percentage: '50', gpa: 0, credits: 2),
        _entry('D', grade: '缓考'),
      ]);
      expect(s.gpa, closeTo(3.5, 1e-9));
      expect(s.credits, 4);
      expect(s.averageScore, closeTo(70, 1e-9));
      expect(s.courseCount, 4);
      expect(s.bandCounts[GradeBand.excellent], 1);
      expect(s.bandCounts[GradeBand.medium], 1);
      expect(s.bandCounts[GradeBand.fail], 1);
      // 无法识别的「缓考」不计入分布。
      expect(s.bandCounts.values.fold<int>(0, (a, b) => a + b), 3);
    });
  });

  group('sortGrades', () {
    final grades = [
      _entry('低', percentage: '61', credits: 4, year: '2024-2025'),
      _entry('优等级', grade: '优秀', credits: 1, semester: '第二学期'),
      _entry('高', percentage: '96', credits: 2),
      _entry('未知', grade: '缓考', credits: 2, year: '2024-2025'),
    ];

    test('score descending, letter grades by band midpoint, unknown last', () {
      expect(_names(sortGrades(grades, GradesSortMode.score)), [
        '高',
        '优等级',
        '低',
        '未知',
      ]);
    });

    test('term: newest year first, spring before autumn, stable', () {
      expect(_names(sortGrades(grades, GradesSortMode.term)), [
        '优等级',
        '高',
        '低',
        '未知',
      ]);
    });

    test('credits descending, stable', () {
      expect(_names(sortGrades(grades, GradesSortMode.credits)), [
        '低',
        '高',
        '未知',
        '优等级',
      ]);
    });

    test('sort mode cycles', () {
      expect(GradesSortMode.score.next, GradesSortMode.term);
      expect(GradesSortMode.term.next, GradesSortMode.credits);
      expect(GradesSortMode.credits.next, GradesSortMode.score);
    });
  });

  test('shortLabelOf', () {
    expect(GradesTermResolver.shortLabelOf('2025-2026', '第一学期'), '2025–26 秋');
    expect(GradesTermResolver.shortLabelOf('2025-2026', '第二学期'), '2025–26 春');
    expect(GradesTermResolver.shortLabelOf('2025-2026', '第三学期'), '2025–26 夏');
    expect(GradesTermResolver.shortLabelOf('未知学年', '其他'), '未知学年 其他');
  });
}
