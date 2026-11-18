import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_schedule_conflict.dart';

/// 2026-03-02 是周一，作为第 1 周的学期起始日。
final _semesterStart = DateTime(2026, 3, 2);

CourseEntry _course({
  String name = '高等数学',
  int weekday = 1,
  int startLesson = 1,
  int endLesson = 2,
  String weekRange = '1-20周',
}) {
  return CourseEntry(
    courseName: name,
    teacherName: '张老师',
    weekday: weekday,
    startLesson: startLesson,
    endLesson: endLesson,
    weekRange: weekRange,
    classroom: 'A101',
    campus: '梁林校区',
    typeSymbol: '◆',
  );
}

List<String> _conflicts({
  required DateTime? start,
  required DateTime? end,
  required Iterable<CourseEntry> courses,
}) {
  return secondClassroomScheduleConflicts(
    activityStart: start,
    activityEnd: end,
    semesterStart: _semesterStart,
    courses: courses,
  );
}

void main() {
  test('activity inside a lesson slot conflicts with that course', () {
    // 周一第 1-2 节 08:00–09:25。
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 8, 30),
        end: DateTime(2026, 3, 2, 9, 0),
        courses: [_course()],
      ),
      ['高等数学'],
    );
  });

  test('activity spanning the whole slot conflicts', () {
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 7, 0),
        end: DateTime(2026, 3, 2, 12, 0),
        courses: [_course()],
      ),
      ['高等数学'],
    );
  });

  test('adjacent but non overlapping intervals do not conflict', () {
    // 课程 08:00–09:25，活动从 09:25 开始。
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 9, 25),
        end: DateTime(2026, 3, 2, 10, 0),
        courses: [_course()],
      ),
      isEmpty,
    );
    // 活动在 08:00 结束。
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 7, 0),
        end: DateTime(2026, 3, 2, 8, 0),
        courses: [_course()],
      ),
      isEmpty,
    );
  });

  test('week range filters out weeks the course is not taught', () {
    final course = _course(weekRange: '1-2周');
    // 第 2 周周一。
    expect(
      _conflicts(
        start: DateTime(2026, 3, 9, 8, 30),
        end: DateTime(2026, 3, 9, 9, 0),
        courses: [course],
      ),
      ['高等数学'],
    );
    // 第 3 周周一，同一时段但课不在这一周。
    expect(
      _conflicts(
        start: DateTime(2026, 3, 16, 8, 30),
        end: DateTime(2026, 3, 16, 9, 0),
        courses: [course],
      ),
      isEmpty,
    );
  });

  test('other weekday at the same clock time does not conflict', () {
    expect(
      _conflicts(
        start: DateTime(2026, 3, 3, 8, 30),
        end: DateTime(2026, 3, 3, 9, 0),
        courses: [_course()],
      ),
      isEmpty,
    );
  });

  test('multiple conflicting courses are all reported once', () {
    final conflicts = _conflicts(
      start: DateTime(2026, 3, 2, 8, 30),
      end: DateTime(2026, 3, 2, 9, 0),
      courses: [
        _course(),
        _course(name: '大学英语', startLesson: 2, endLesson: 3),
        _course(name: '大学英语', startLesson: 2, endLesson: 3),
      ],
    );
    expect(conflicts.toSet(), {'高等数学', '大学英语'});
    expect(conflicts.length, 2);
  });

  test('missing or inverted activity time yields no conflict', () {
    expect(_conflicts(start: null, end: null, courses: [_course()]), isEmpty);
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 8, 30),
        end: null,
        courses: [_course()],
      ),
      isEmpty,
    );
    expect(
      _conflicts(
        start: null,
        end: DateTime(2026, 3, 2, 9, 0),
        courses: [_course()],
      ),
      isEmpty,
    );
    // 结束等于开始、结束早于开始都不算有效区间。
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 8, 30),
        end: DateTime(2026, 3, 2, 8, 30),
        courses: [_course()],
      ),
      isEmpty,
    );
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 9, 0),
        end: DateTime(2026, 3, 2, 8, 30),
        courses: [_course()],
      ),
      isEmpty,
    );
  });

  test('empty course list yields no conflict', () {
    expect(
      _conflicts(
        start: DateTime(2026, 3, 2, 8, 30),
        end: DateTime(2026, 3, 2, 9, 0),
        courses: const [],
      ),
      isEmpty,
    );
  });

  test('invalid course entries are skipped', () {
    final conflicts = _conflicts(
      start: DateTime(2026, 3, 2, 8, 30),
      end: DateTime(2026, 3, 2, 9, 0),
      courses: [
        _course(name: '错误星期', weekday: 0),
        _course(name: '错误星期2', weekday: 8),
        _course(name: '节次倒置', startLesson: 5, endLesson: 3),
      ],
    );
    expect(conflicts, isEmpty);
  });

  test('unknown lesson slot is ignored instead of throwing', () {
    final conflicts = _conflicts(
      start: DateTime(2026, 3, 2, 8, 30),
      end: DateTime(2026, 3, 2, 9, 0),
      courses: [_course(name: '越界节次', startLesson: 1, endLesson: 99)],
    );
    expect(conflicts, isEmpty);
  });
}
