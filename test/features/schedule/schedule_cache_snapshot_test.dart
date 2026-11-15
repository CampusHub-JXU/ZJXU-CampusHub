import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_date_override.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

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

  ScheduleDateOverride dateOverrideFor({String id = 'o1'}) {
    return ScheduleDateOverride(
      id: id,
      termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
      sourceDate: '2026-04-06',
      sourceWeek: 5,
      sourceWeekday: 1,
      sourceStartLesson: 3,
      sourceEndLesson: 4,
      sourceCourseName: '大学物理',
      sourceTeacherName: '王老师',
      sourceClassroom: 'A101',
      targetDate: '2026-04-08',
      targetWeek: 5,
      targetWeekday: 3,
      targetStartLesson: 7,
      targetEndLesson: 8,
      targetClassroom: 'C303',
      targetTeacherName: '王老师',
      updatedAt: DateTime(2026, 4, 1, 12, 0),
    );
  }

  test('round-trips dateOverrides and marks snapshots as having data', () {
    final snapshot = ScheduleCacheSnapshot(
      studentId: '20250001',
      termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
      dateOverrides: [dateOverrideFor()],
    );

    expect(snapshot.hasData, isTrue);
    final restored = ScheduleCacheSnapshot.fromJson(snapshot.toJson());
    expect(restored.dateOverrides, hasLength(1));
    expect(restored.dateOverrides.single.id, 'o1');
    expect(restored.dateOverrides.single.sourceCourseName, '大学物理');
    expect(restored.dateOverrides.single.targetWeekday, 3);
  });

  test('old snapshots without dateOverrides fall back to empty', () {
    final restored = ScheduleCacheSnapshot.fromJson({
      'studentId': '20250001',
      'termContext': {'academicYear': 2025, 'term': 12},
      'courses': const [],
      'scheduleUpdatedAt': DateTime(2026, 4, 1).millisecondsSinceEpoch,
    });

    expect(restored.dateOverrides, isEmpty);
    expect(restored.hasData, isTrue);
  });

  test('copyWith preserves dateOverrides when not specified', () {
    final snapshot = ScheduleCacheSnapshot(
      studentId: '20250001',
      termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
      dateOverrides: [dateOverrideFor()],
      scheduleUpdatedAt: DateTime(2026, 4, 1),
    );

    final refreshed = snapshot.copyWith(
      courses: const [],
      scheduleUpdatedAt: DateTime(2026, 4, 9),
    );

    // 网络刷新落盘绝不能把用户本地编辑冲掉。
    expect(refreshed.dateOverrides, hasLength(1));
    expect(refreshed.dateOverrides.single.id, 'o1');
    expect(refreshed.scheduleUpdatedAt, DateTime(2026, 4, 9));
  });
}
