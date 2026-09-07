import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/schedule/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';

void main() {
  test('copyWith can clear timestamps and preserve data', () {
    final snapshot = ScheduleCacheSnapshot(
      studentId: '20250001',
      termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
      courses: const [
        CourseEntry(
          courseName: '大学物理',
          teacherName: '教师',
          weekday: 1,
          startLesson: 1,
          endLesson: 2,
          weekRange: '1-18周',
          classroom: 'A101',
          campus: '梁林校区',
          typeSymbol: '',
        ),
      ],
      scheduleUpdatedAt: DateTime(2026, 4, 1),
      changeRulesUpdatedAt: DateTime(2026, 4, 2),
      changeRulesCurrentScoped: true,
    );

    final updated = snapshot.copyWith(clearScheduleUpdatedAt: true);

    expect(updated.scheduleUpdatedAt, isNull);
    expect(updated.changeRulesUpdatedAt, DateTime(2026, 4, 2));
    expect(updated.hasData, isTrue);
    expect(updated.lastUpdatedAt, DateTime(2026, 4, 2));
  });

  test('round-trips the current-scoped change-rule marker', () {
    final snapshot = ScheduleCacheSnapshot(
      studentId: '20250001',
      termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
      changeRulesUpdatedAt: DateTime(2026, 4, 2),
      changeRulesCurrentScoped: true,
    );

    expect(
      ScheduleCacheSnapshot.fromJson(snapshot.toJson())
          .changeRulesCurrentScoped,
      isTrue,
    );
    expect(
      ScheduleCacheSnapshot.fromJson(snapshot.toJson()).changeRulesDateAware,
      isTrue,
    );
  });

  test('old snapshots without publication dates refresh once', () {
    final old = ScheduleCacheSnapshot.fromJson({
      'studentId': '20250001',
      'termContext': {'academicYear': 2025, 'term': 12},
      'changeRules': [
        {'type': 'cancel', 'rawMessage': '旧通知'},
      ],
      'changeRulesUpdatedAt': DateTime(2026, 9, 7).millisecondsSinceEpoch,
    });

    expect(old.changeRulesDateAware, isFalse);
    expect(old.needsChangeRulesRefresh(DateTime(2026, 9, 7)), isTrue);
  });

  test('refresh heuristics require schedule data and respect max age', () {
    final empty = ScheduleCacheSnapshot.empty(
      studentId: '20250001',
      termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
    );
    expect(empty.needsScheduleRefresh(DateTime(2026, 4, 10)), isTrue);
    expect(empty.needsChangeRulesRefresh(DateTime(2026, 4, 10)), isTrue);
  });
}
