import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_score_palette.dart';

GradeEntry _entry({String grade = '', String percentage = ''}) => GradeEntry(
  courseName: '课程',
  grade: grade,
  percentageScore: percentage,
  gpaPoints: 0,
  credits: 1,
  academicYear: '2025-2026',
  semester: '第一学期',
  examType: '',
  assessmentMethod: '',
  courseRequirement: '',
);

void main() {
  group('gradeBandForScore', () {
    test('maps percentage bands on the documented boundaries', () {
      expect(gradeBandForScore(100), GradeBand.excellent);
      expect(gradeBandForScore(90), GradeBand.excellent);
      expect(gradeBandForScore(89.9), GradeBand.good);
      expect(gradeBandForScore(80), GradeBand.good);
      expect(gradeBandForScore(79.9), GradeBand.medium);
      expect(gradeBandForScore(70), GradeBand.medium);
      expect(gradeBandForScore(69.9), GradeBand.pass);
      expect(gradeBandForScore(60), GradeBand.pass);
      expect(gradeBandForScore(59.9), GradeBand.fail);
      expect(gradeBandForScore(0), GradeBand.fail);
    });
  });

  group('gradeBandForEntry', () {
    test('prefers the numeric percentage score', () {
      expect(
        gradeBandForEntry(_entry(grade: '优秀', percentage: '65')),
        GradeBand.pass,
      );
      expect(gradeBandForEntry(_entry(grade: '88')), GradeBand.good);
    });

    test('maps letter grades by text', () {
      expect(gradeBandForEntry(_entry(grade: '优秀')), GradeBand.excellent);
      expect(gradeBandForEntry(_entry(grade: '良好')), GradeBand.good);
      expect(gradeBandForEntry(_entry(grade: '中等')), GradeBand.medium);
      expect(gradeBandForEntry(_entry(grade: '及格')), GradeBand.pass);
      expect(gradeBandForEntry(_entry(grade: '合格')), GradeBand.pass);
      expect(gradeBandForEntry(_entry(grade: '不及格')), GradeBand.fail);
      expect(gradeBandForEntry(_entry(grade: '不合格')), GradeBand.fail);
    });

    test('returns null for unknown or empty grades', () {
      expect(gradeBandForEntry(_entry()), isNull);
      expect(gradeBandForEntry(_entry(grade: '缓考')), isNull);
    });
  });

  group('band colors', () {
    final lightRed = ColorScheme.fromSeed(seedColor: const Color(0xFF8B1A2D));
    final darkRed = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8B1A2D),
      brightness: Brightness.dark,
    );
    final lightBlue = ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0));

    test('distribution colors derive from the scheme', () {
      for (final cs in [lightRed, darkRed, lightBlue]) {
        expect(gradeBandColor(cs, GradeBand.excellent), cs.primary);
        expect(
          gradeBandColor(cs, GradeBand.good),
          cs.primary.withValues(alpha: 0.6),
        );
        expect(
          gradeBandColor(cs, GradeBand.medium),
          cs.primary.withValues(alpha: 0.35),
        );
        expect(gradeBandColor(cs, GradeBand.pass), cs.outline);
        expect(gradeBandColor(cs, GradeBand.fail), cs.error);
      }
      expect(
        gradeBandColor(lightRed, GradeBand.excellent),
        isNot(gradeBandColor(lightBlue, GradeBand.excellent)),
      );
    });

    test('all five distribution bands are distinct', () {
      for (final cs in [lightRed, darkRed, lightBlue]) {
        final colors = GradeBand.values
            .map((band) => gradeBandColor(cs, band))
            .toSet();
        expect(colors.length, GradeBand.values.length);
      }
    });

    test('score text colors only the extremes', () {
      final cs = lightRed;
      expect(gradeScoreColor(cs, GradeBand.excellent), cs.primary);
      expect(gradeScoreColor(cs, GradeBand.fail), cs.error);
      for (final band in [GradeBand.good, GradeBand.medium, GradeBand.pass]) {
        expect(gradeScoreColor(cs, band), cs.onSurface);
      }
      expect(gradeScoreColor(cs, null), cs.onSurface);
    });

    test('band labels', () {
      expect(GradeBand.values.map((b) => b.label).toList(), [
        '优',
        '良',
        '中',
        '及格',
        '不及格',
      ]);
    });
  });
}
