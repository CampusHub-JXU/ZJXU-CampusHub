import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_term_resolver.dart';

GradeEntry _g(String course, String year, String semester) => GradeEntry(
  courseName: course,
  grade: '85',
  percentageScore: '85',
  gpaPoints: 3.8,
  credits: 2.0,
  academicYear: year,
  semester: semester,
  examType: '',
  assessmentMethod: '',
  courseRequirement: '',
);

void main() {
  group('GradesTermResolver.keyOf', () {
    test('joins academic year and chinese semester with a pipe', () {
      expect(
        GradesTermResolver.keyOf(_g('A', '2025-2026', '第二学期')),
        '2025-2026|第二学期',
      );
    });
  });

  group('GradesTermResolver.labelOf', () {
    test('renders "year semester" without extra suffix', () {
      expect(GradesTermResolver.labelOf('2025-2026', '第二学期'), '2025-2026 第二学期');
    });
  });

  group('GradesTermResolver.currentTermKey', () {
    test('maps June 2026 to 2025-2026 第二学期', () {
      expect(
        GradesTermResolver.currentTermKey(DateTime(2026, 6, 28)),
        '2025-2026|第二学期',
      );
    });

    test('maps October 2025 to 2025-2026 第一学期', () {
      expect(
        GradesTermResolver.currentTermKey(DateTime(2025, 10, 1)),
        '2025-2026|第一学期',
      );
    });

    test('maps March 2025 to 2024-2025 第二学期', () {
      expect(
        GradesTermResolver.currentTermKey(DateTime(2025, 3, 1)),
        '2024-2025|第二学期',
      );
    });
  });

  group('GradesTermResolver.availableTerms', () {
    test('dedupes and sorts newest first, 第二学期 before 第一学期', () {
      final terms = GradesTermResolver.availableTerms([
        _g('a', '2024-2025', '第一学期'),
        _g('b', '2025-2026', '第二学期'),
        _g('c', '2024-2025', '第二学期'),
        _g('d', '2025-2026', '第二学期'),
        _g('e', '2025-2026', '第一学期'),
      ]);
      expect(terms, hasLength(4));
      expect(terms[0], (academicYear: '2025-2026', semester: '第二学期'));
      expect(terms[1], (academicYear: '2025-2026', semester: '第一学期'));
      expect(terms[2], (academicYear: '2024-2025', semester: '第二学期'));
      expect(terms[3], (academicYear: '2024-2025', semester: '第一学期'));
    });

    test('returns empty when no grades', () {
      expect(GradesTermResolver.availableTerms([]), isEmpty);
    });
  });

  group('GradesTermResolver.pickDefault', () {
    test('keeps previous key when still available', () {
      final grades = [
        _g('a', '2025-2026', '第二学期'),
        _g('b', '2024-2025', '第二学期'),
      ];
      expect(
        GradesTermResolver.pickDefault(grades, previousKey: '2024-2025|第二学期'),
        '2024-2025|第二学期',
      );
    });

    test('defaults to latest available term when previous key missing', () {
      // 最新学期为 2025-2026 第二学期，应默认选中它（而非当前学期）。
      final grades = [
        _g('a', '2025-2026', '第二学期'),
        _g('b', '2024-2025', '第二学期'),
      ];
      expect(
        GradesTermResolver.pickDefault(grades, previousKey: '2099-2099|第一学期'),
        '2025-2026|第二学期',
      );
    });

    test('defaults to latest available term when no previous key', () {
      final grades = [
        _g('a', '2024-2025', '第二学期'),
        _g('b', '2024-2025', '第一学期'),
      ];
      expect(GradesTermResolver.pickDefault(grades), '2024-2025|第二学期');
    });

    test('returns null when no grades', () {
      expect(GradesTermResolver.pickDefault([]), isNull);
    });
  });

  group('GradesTermResolver.filterByTermKey', () {
    test('returns all grades for allTermKey', () {
      final grades = [
        _g('a', '2025-2026', '第二学期'),
        _g('b', '2024-2025', '第一学期'),
      ];
      expect(
        GradesTermResolver.filterByTermKey(
          grades,
          GradesTermResolver.allTermKey,
        ),
        grades,
      );
    });

    test('returns all grades for null key', () {
      final grades = [_g('a', '2025-2026', '第二学期')];
      expect(GradesTermResolver.filterByTermKey(grades, null), grades);
    });

    test('filters to a single term', () {
      final a = _g('a', '2025-2026', '第二学期');
      final b = _g('b', '2024-2025', '第一学期');
      expect(GradesTermResolver.filterByTermKey([a, b], '2025-2026|第二学期'), [a]);
    });
  });
}
