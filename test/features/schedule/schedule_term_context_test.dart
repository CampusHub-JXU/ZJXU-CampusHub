import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

void main() {
  test('current uses academic year rollover and term mapping', () {
    expect(ScheduleTermContext.current(DateTime(2026, 3, 1)).key, '2025-12');
    expect(ScheduleTermContext.current(DateTime(2026, 9, 1)).key, '2026-3');
  });

  test('json round-trip keeps fields and label', () {
    final context = ScheduleTermContext.fromJson({
      'academicYear': 2025,
      'term': 12,
    });

    expect(context.termLabel, '第二学期');
    expect(context.toJson(), {'academicYear': 2025, 'term': 12});
  });

  test('previous walks back across the academic year boundary', () {
    expect(
      const ScheduleTermContext(academicYear: 2025, term: 3).previous(),
      const ScheduleTermContext(academicYear: 2024, term: 12),
    );
    expect(
      const ScheduleTermContext(academicYear: 2025, term: 12).previous(),
      const ScheduleTermContext(academicYear: 2025, term: 3),
    );
  });

  test('equality and hashCode match on year and term', () {
    expect(
      const ScheduleTermContext(academicYear: 2025, term: 3),
      const ScheduleTermContext(academicYear: 2025, term: 3),
    );
    expect(
      const ScheduleTermContext(academicYear: 2025, term: 3).hashCode,
      const ScheduleTermContext(academicYear: 2025, term: 3).hashCode,
    );
    expect(
      const ScheduleTermContext(academicYear: 2025, term: 3),
      isNot(const ScheduleTermContext(academicYear: 2025, term: 12)),
    );
  });
}
