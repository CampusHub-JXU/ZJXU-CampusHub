import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/effective_week_courses.dart';
import 'package:jxu_campus_hub/core/academic/schedule_change_rule.dart';
import 'package:jxu_campus_hub/core/academic/schedule_date_override.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

void main() {
  const termContext = ScheduleTermContext(academicYear: 2025, term: 12);

  const physics = CourseEntry(
    courseName: '大学物理',
    teacherName: '王老师',
    weekday: 1,
    startLesson: 3,
    endLesson: 4,
    weekRange: '1-18周',
    classroom: 'A101',
    campus: '梁林校区',
    typeSymbol: '◆',
  );

  const english = CourseEntry(
    courseName: '英语听说',
    teacherName: '李老师',
    weekday: 1,
    startLesson: 5,
    endLesson: 6,
    weekRange: '1-18周',
    classroom: 'B202',
    campus: '梁林校区',
    typeSymbol: '',
  );

  ScheduleDateOverride overrideFor({
    String id = 'o1',
    ScheduleTermContext? term = termContext,
    int sourceWeek = 5,
    int targetWeek = 5,
    int targetWeekday = 3,
    int targetStartLesson = 7,
    int targetEndLesson = 8,
    String targetClassroom = 'C303',
    String targetTeacherName = '王老师',
    DateTime? updatedAt,
  }) {
    return ScheduleDateOverride(
      id: id,
      termContext: term,
      sourceDate: '2026-04-06',
      sourceWeek: sourceWeek,
      sourceWeekday: 1,
      sourceStartLesson: 3,
      sourceEndLesson: 4,
      sourceCourseName: '大学物理',
      sourceTeacherName: '王老师',
      sourceClassroom: 'A101',
      targetDate: '2026-04-08',
      targetWeek: targetWeek,
      targetWeekday: targetWeekday,
      targetStartLesson: targetStartLesson,
      targetEndLesson: targetEndLesson,
      targetClassroom: targetClassroom,
      targetTeacherName: targetTeacherName,
      updatedAt: updatedAt ?? DateTime(2026, 4, 1, 12, 0),
    );
  }

  group('ScheduleDateOverride model', () {
    test('round-trips every field through json', () {
      final override = overrideFor(id: 'abc');
      final restored = ScheduleDateOverride.fromJson(override.toJson());

      expect(restored.id, 'abc');
      expect(restored.termContext, termContext);
      expect(restored.sourceDate, '2026-04-06');
      expect(restored.sourceWeek, 5);
      expect(restored.sourceWeekday, 1);
      expect(restored.sourceStartLesson, 3);
      expect(restored.sourceEndLesson, 4);
      expect(restored.sourceCourseName, '大学物理');
      expect(restored.sourceTeacherName, '王老师');
      expect(restored.sourceClassroom, 'A101');
      expect(restored.targetDate, '2026-04-08');
      expect(restored.targetWeek, 5);
      expect(restored.targetWeekday, 3);
      expect(restored.targetStartLesson, 7);
      expect(restored.targetEndLesson, 8);
      expect(restored.targetClassroom, 'C303');
      expect(restored.targetTeacherName, '王老师');
      expect(restored.updatedAt, DateTime(2026, 4, 1, 12, 0));
    });

    test('fromJson tolerates missing fields with safe fallbacks', () {
      final restored = ScheduleDateOverride.fromJson(const {'id': 'x'});
      expect(restored.id, 'x');
      expect(restored.termContext, isNull);
      expect(restored.sourceWeek, 0);
      expect(restored.targetWeek, 0);
      expect(restored.updatedAt.millisecondsSinceEpoch, 0);
      // 坏行绝不命中任何真实课程。
      expect(restored.matchesSource(5, physics), isFalse);
      expect(restored.matchesTarget(5, physics), isFalse);
    });

    test(
      'matchesSource hits the original slot and name only in source week',
      () {
        final override = overrideFor(sourceWeek: 5);

        expect(override.matchesSource(5, physics), isTrue);
        // 课名相同但节次段不同 → 不是同一次课。
        expect(
          override.matchesSource(
            5,
            const CourseEntry(
              courseName: '大学物理',
              teacherName: '王老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '◆',
            ),
          ),
          isFalse,
        );
        // 同一时间段但课名不同 → 不命中。
        expect(override.matchesSource(5, english), isFalse);
        // 周次不匹配（weekRange 覆盖但 sourceWeek 不同）→ 不命中。
        expect(override.matchesSource(6, physics), isFalse);
        // 权威 weekRange 不覆盖该周（如课程在源周后被截断）→ 不命中。
        expect(
          override.matchesSource(
            5,
            const CourseEntry(
              courseName: '大学物理',
              teacherName: '王老师',
              weekday: 1,
              startLesson: 3,
              endLesson: 4,
              weekRange: '6-9周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '◆',
            ),
          ),
          isFalse,
        );
      },
    );

    test('matchesTarget identifies the synthesized course slot', () {
      final override = overrideFor(targetWeek: 5);
      const synthesized = CourseEntry(
        courseName: '大学物理',
        teacherName: '王老师',
        weekday: 3,
        startLesson: 7,
        endLesson: 8,
        weekRange: '5周',
        classroom: 'C303',
        campus: '梁林校区',
        typeSymbol: '◆',
        hasScheduleChange: true,
      );

      expect(override.matchesTarget(5, synthesized), isTrue);
      expect(override.matchesTarget(6, synthesized), isFalse);
      expect(override.matchesTarget(5, physics), isFalse);
    });

    test('sourceSignature ignores target fields, updatedAt and id', () {
      final a = overrideFor(id: 'a', targetClassroom: 'X1');
      final b = overrideFor(
        id: 'b',
        targetClassroom: 'X2',
        updatedAt: DateTime(2026, 4, 2),
      );
      expect(a.sourceSignature, b.sourceSignature);
      expect(
        a.sourceSignature,
        isNot(overrideFor(sourceWeek: 6).sourceSignature),
      );
    });
  });

  group('buildEffectiveWeekCourses with dateOverrides', () {
    test(
      'replaces the source course with a synthesized target in same week',
      () {
        final effective = buildEffectiveWeekCourses(
          courses: const [physics, english],
          week: 5,
          dateOverrides: [overrideFor()],
          termContext: termContext,
        );

        expect(effective, hasLength(2));
        final moved = effective.singleWhere((c) => c.courseName == '大学物理');
        expect(moved.weekday, 3);
        expect(moved.startLesson, 7);
        expect(moved.endLesson, 8);
        expect(moved.classroom, 'C303');
        expect(moved.teacherName, '王老师');
        expect(moved.weekRange, '5周');
        expect(moved.campus, '梁林校区');
        expect(moved.typeSymbol, '◆');
        expect(moved.hasScheduleChange, isTrue);
        // 原周一 3-4 节的那条已被移除。
        expect(
          effective.any((c) => c.weekday == 1 && c.startLesson == 3),
          isFalse,
        );
        // 无关课程不受影响。
        expect(effective.any((c) => c.courseName == '英语听说'), isTrue);
      },
    );

    test('moves a course across weeks: gone at source, added at target', () {
      // 覆盖语义：只移除「源周那一次课」；原课程 weekRange 覆盖的其它周
      // 照常出现（移动的是某次课，不是整门课）。目标周因此是
      // 原始 occurrence + 合成 occurrence 并存。
      final override = overrideFor(sourceWeek: 5, targetWeek: 6);

      final week5 = buildEffectiveWeekCourses(
        courses: const [physics],
        week: 5,
        dateOverrides: [override],
        termContext: termContext,
      );
      expect(week5, isEmpty);

      final week6 = buildEffectiveWeekCourses(
        courses: const [physics],
        week: 6,
        dateOverrides: [override],
        termContext: termContext,
      );
      expect(week6, hasLength(2));
      final moved = week6.singleWhere((c) => c.weekday == 3);
      expect(moved.weekRange, '6周');
      expect(moved.hasScheduleChange, isTrue);
      expect(
        week6.singleWhere((c) => c.weekday == 1).hasScheduleChange,
        isFalse,
      );
    });

    test('re-editing the same source course replaces, never stacks', () {
      final first = overrideFor(id: 'a', targetClassroom: 'X1');
      final second = overrideFor(
        id: 'b',
        targetWeekday: 4,
        targetStartLesson: 9,
        targetEndLesson: 10,
        targetClassroom: 'X2',
      );
      // 模拟「重复编辑覆盖更新」的存储语义：同 sourceSignature 只留最新。
      final stored = [
        for (final o in [first])
          if (o.sourceSignature != second.sourceSignature) o,
        second,
      ];
      expect(stored, hasLength(1));
      expect(stored.single.id, 'b');

      final effective = buildEffectiveWeekCourses(
        courses: const [physics],
        week: 5,
        dateOverrides: stored,
        termContext: termContext,
      );
      expect(effective, hasLength(1));
      expect(effective.single.weekday, 4);
      expect(effective.single.classroom, 'X2');
    });

    test('reverting an override restores the authoritative course', () {
      final override = overrideFor();
      final stored = [override];
      // revert = 从列表删除该 id 的 override。
      stored.removeWhere((o) => o.id == override.id);

      final effective = buildEffectiveWeekCourses(
        courses: const [physics],
        week: 5,
        dateOverrides: stored,
        termContext: termContext,
      );
      expect(effective, hasLength(1));
      expect(effective.single.weekday, 1);
      expect(effective.single.startLesson, 3);
      expect(effective.single.classroom, 'A101');
      expect(effective.single.hasScheduleChange, isFalse);
    });

    test('overrides from another term are filtered out', () {
      final foreign = overrideFor(
        term: const ScheduleTermContext(academicYear: 2025, term: 3),
      );
      final effective = buildEffectiveWeekCourses(
        courses: const [physics],
        week: 5,
        dateOverrides: [foreign],
        termContext: termContext,
      );
      expect(effective, hasLength(1));
      expect(effective.single.weekday, 1);
    });

    test('null-term overrides apply to any requested term', () {
      final untagged = overrideFor(term: null);
      final effective = buildEffectiveWeekCourses(
        courses: const [physics],
        week: 5,
        dateOverrides: [untagged],
        termContext: termContext,
      );
      expect(effective.single.weekday, 3);
    });

    test(
      'override still applies when a change rule also targets the course',
      () {
        // 服务端调课规则移动了另一条课；用户编辑只作用于自己的源课程，
        // 两者叠加不冲突。
        const rule = CourseChangeRule(
          type: CourseChangeType.cancel,
          originalLesson: CourseLessonSlot(
            week: 5,
            weekday: 1,
            startLesson: 5,
            endLesson: 6,
          ),
          courseName: '英语听说',
          termContext: termContext,
        );
        final effective = buildEffectiveWeekCourses(
          courses: const [physics, english],
          week: 5,
          changeRules: const [rule],
          dateOverrides: [overrideFor()],
          termContext: termContext,
        );
        expect(effective, hasLength(1));
        expect(effective.single.weekday, 3);
      },
    );
  });
}
