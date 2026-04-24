import 'package:flutter/material.dart';

import '../schedule_constants.dart';
import '../schedule_model.dart';
import '../schedule_week_view_model.dart';
import 'schedule_course_cell.dart';
import 'schedule_day_headers.dart';
import 'schedule_slot_column.dart';

class ScheduleGrid extends StatelessWidget {
  const ScheduleGrid({
    super.key,
    required this.weekViewModel,
    required this.actualCurrentWeek,
  });

  final ScheduleWeekViewModel weekViewModel;
  final int actualCurrentWeek;
  int get currentWeek => weekViewModel.week;

  static const _courseColors = [
    Color(0xFF8B1A2D),
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFFD4AF37),
    Color(0xFF7B1FA2),
    Color(0xFF00838F),
    Color(0xFFE65100),
    Color(0xFFAD1457),
  ];

  static const _inactiveColors = [
    Color(0xFFD4A5B0),
    Color(0xFFA5C4E0),
    Color(0xFFA5D4A5),
    Color(0xFFE0D4A5),
    Color(0xFFC4A5D4),
    Color(0xFFA5D4D4),
    Color(0xFFE0BFA5),
    Color(0xFFD4A5C4),
  ];

  /// Merge adjacent/overlapping same-name courses on the same day into one
  /// entry spanning the full range, then deduplicate.
  static List<CourseEntry> mergeAdjacentCourses(List<CourseEntry> courses) {
    if (courses.length <= 1) return courses;

    // Group by courseName (already filtered to same weekday by caller)
    final groups = <String, List<CourseEntry>>{};
    for (final c in courses) {
      (groups[c.courseName] ??= []).add(c);
    }

    final merged = <CourseEntry>[];
    for (final group in groups.values) {
      if (group.length == 1) {
        merged.add(group.first);
        continue;
      }

      group.sort((a, b) => a.startLesson.compareTo(b.startLesson));

      var current = group.first;
      for (var i = 1; i < group.length; i++) {
        final next = group[i];
        if (next.startLesson <= current.endLesson + 1) {
          // Merge: extend to cover next
          final newEnd = current.endLesson > next.endLesson
              ? current.endLesson
              : next.endLesson;
          current = CourseEntry(
            courseName: current.courseName,
            teacherName: current.teacherName,
            weekday: current.weekday,
            startLesson: current.startLesson,
            endLesson: newEnd,
            weekRange: current.weekRange,
            classroom: current.classroom.isNotEmpty
                ? current.classroom
                : next.classroom,
            campus: current.campus,
            typeSymbol: current.typeSymbol,
          );
        } else {
          merged.add(current);
          current = next;
        }
      }
      merged.add(current);
    }

    return merged;
  }

  /// Deduplicate other-week courses, exclude those already in current week,
  /// and merge adjacent same-name entries.
  static List<CourseEntry> deduplicateBySlot(
    List<CourseEntry> otherCourses,
    List<CourseEntry> currentWeekCourses,
  ) {
    final currentKeys = <String>{};
    for (final c in currentWeekCourses) {
      currentKeys.add('${c.courseName}|${c.startLesson}|${c.endLesson}');
    }

    final seen = <String>{};
    final deduped = otherCourses.where((course) {
      final key =
          '${course.courseName}|${course.startLesson}|${course.endLesson}';
      if (currentKeys.contains(key)) return false;
      return seen.add(key);
    }).toList();

    return mergeAdjacentCourses(deduped);
  }

  Color _colorForCourse(String name, bool isCurrentWeek) {
    final index = name.hashCode.abs() % _courseColors.length;
    return isCurrentWeek ? _courseColors[index] : _inactiveColors[index];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dayColumnWidth =
            (constraints.maxWidth - scheduleGridSlotColumnWidth) / 7;

        return Column(
          children: [
            ScheduleDayHeaders(
              slotColumnWidth: scheduleGridSlotColumnWidth,
              dayColumnWidth: dayColumnWidth,
              currentWeek: currentWeek,
              isCurrentWeek: currentWeek == actualCurrentWeek,
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ScheduleSlotColumn(
                      slotColumnWidth: scheduleGridSlotColumnWidth,
                    ),
                    for (int day = 1; day <= 7; day++)
                      RepaintBoundary(
                        child: _DayColumn(
                          currentWeekCourses: weekViewModel
                              .coursesForDay(day)
                              .currentWeekCourses,
                          otherWeekCourses: weekViewModel
                              .coursesForDay(day)
                              .otherWeekCourses,
                          colorFor: _colorForCourse,
                          dayColumnWidth: dayColumnWidth,
                          displayWeek: currentWeek,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.currentWeekCourses,
    required this.otherWeekCourses,
    required this.colorFor,
    required this.dayColumnWidth,
    required this.displayWeek,
  });

  final List<CourseEntry> currentWeekCourses;
  final List<CourseEntry> otherWeekCourses;
  final Color Function(String, bool) colorFor;
  final double dayColumnWidth;
  final int displayWeek;

  @override
  Widget build(BuildContext context) {
    final displayCourses = [
      ...currentWeekCourses.map(
        (course) => _DisplayCourseEntry(course: course, isCurrentWeek: true),
      ),
      ...otherWeekCourses.map(
        (course) => _DisplayCourseEntry(course: course, isCurrentWeek: false),
      ),
    ];

    final placements = _buildCoursePlacements(displayCourses);

    return SizedBox(
      width: dayColumnWidth,
      height: scheduleGridSlotHeight * scheduleSlotCount,
      child: Stack(
        children: [
          for (final placement in placements)
            Positioned(
              left: placement.left,
              top:
                  (placement.entry.course.startLesson - 1) *
                  scheduleGridSlotHeight,
              width: placement.width,
              height: scheduleGridSlotHeight * placement.span,
              child: RepaintBoundary(
                child: ScheduleCourseCell(
                  course: placement.entry.course,
                  span: placement.span,
                  color: colorFor(
                    placement.entry.course.courseName,
                    placement.entry.isCurrentWeek,
                  ),
                  dayColumnWidth: placement.width,
                  isCurrentWeek: placement.entry.isCurrentWeek,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<_PlacedCourse> _buildCoursePlacements(
    List<_DisplayCourseEntry> displayCourses,
  ) {
    if (displayCourses.isEmpty) return const [];

    final sortedCourses = [...displayCourses]
      ..sort((a, b) {
        final byStart = a.course.startLesson.compareTo(b.course.startLesson);
        if (byStart != 0) return byStart;

        if (a.isCurrentWeek != b.isCurrentWeek) {
          return a.isCurrentWeek ? -1 : 1;
        }

        final byEnd = a.course.endLesson.compareTo(b.course.endLesson);
        if (byEnd != 0) return byEnd;

        return a.course.courseName.compareTo(b.course.courseName);
      });

    final placements = <_PlacedCourse>[];
    final clusters = <List<_DisplayCourseEntry>>[];
    var currentCluster = <_DisplayCourseEntry>[];
    var clusterEnd = 0;

    for (final course in sortedCourses) {
      if (currentCluster.isEmpty || course.course.startLesson > clusterEnd) {
        if (currentCluster.isNotEmpty) clusters.add(currentCluster);
        currentCluster = [course];
        clusterEnd = course.course.endLesson;
        continue;
      }

      currentCluster.add(course);
      if (course.course.endLesson > clusterEnd) {
        clusterEnd = course.course.endLesson;
      }
    }

    if (currentCluster.isNotEmpty) clusters.add(currentCluster);

    for (final cluster in clusters) {
      placements.addAll(_buildClusterPlacements(cluster));
    }

    return placements;
  }

  List<_PlacedCourse> _buildClusterPlacements(
    List<_DisplayCourseEntry> cluster,
  ) {
    final currentEntries = cluster
        .where((entry) => entry.isCurrentWeek)
        .toList();
    final otherEntries = cluster
        .where((entry) => !entry.isCurrentWeek)
        .toList();

    if (currentEntries.isNotEmpty) {
      // Current-week courses take full width; hide non-current-week to avoid conflict
      return _buildStandardPlacements(currentEntries, dayColumnWidth);
    }

    // No current-week courses in this slot — show closest non-current-week at full width
    // Only if within 3 weeks of displayed week to avoid clutter
    if (otherEntries.isEmpty) return const [];

    var closest = otherEntries.first;
    var closestDistance = closest.course.weekDistanceTo(displayWeek);
    for (final entry in otherEntries.skip(1)) {
      final distance = entry.course.weekDistanceTo(displayWeek);
      if (distance < closestDistance) {
        closest = entry;
        closestDistance = distance;
      }
    }
    if (closestDistance > 3) return const [];

    return _buildStandardPlacements([closest], dayColumnWidth);
  }

  List<_PlacedCourse> _buildStandardPlacements(
    List<_DisplayCourseEntry> entries,
    double availableWidth,
  ) {
    if (entries.isEmpty) return const [];

    final assignments = _assignColumns(entries);
    final totalColumns = assignments.fold<int>(
      0,
      (maxColumns, assignment) => assignment.column + 1 > maxColumns
          ? assignment.column + 1
          : maxColumns,
    );
    final columnWidth = availableWidth / totalColumns;

    return assignments.map((assignment) {
      final span =
          (assignment.entry.course.endLesson -
                  assignment.entry.course.startLesson +
                  1)
              .clamp(
                1,
                scheduleSlotCount - assignment.entry.course.startLesson + 1,
              );

      return _PlacedCourse(
        entry: assignment.entry,
        left: assignment.column * columnWidth,
        width: columnWidth,
        span: span,
      );
    }).toList();
  }

  List<_ColumnAssignment> _assignColumns(List<_DisplayCourseEntry> entries) {
    final assignments = <_ColumnAssignment>[];
    final columnEndLessons = <int>[];

    for (final entry in entries) {
      var targetColumn = -1;

      for (var i = 0; i < columnEndLessons.length; i++) {
        if (columnEndLessons[i] < entry.course.startLesson) {
          targetColumn = i;
          break;
        }
      }

      if (targetColumn == -1) {
        targetColumn = columnEndLessons.length;
        columnEndLessons.add(entry.course.endLesson);
      } else {
        columnEndLessons[targetColumn] = entry.course.endLesson;
      }

      assignments.add(_ColumnAssignment(entry: entry, column: targetColumn));
    }

    return assignments;
  }
}

class _DisplayCourseEntry {
  const _DisplayCourseEntry({
    required this.course,
    required this.isCurrentWeek,
  });

  final CourseEntry course;
  final bool isCurrentWeek;
}

class _ColumnAssignment {
  const _ColumnAssignment({required this.entry, required this.column});

  final _DisplayCourseEntry entry;
  final int column;
}

class _PlacedCourse {
  const _PlacedCourse({
    required this.entry,
    required this.left,
    required this.width,
    required this.span,
  });

  final _DisplayCourseEntry entry;
  final double left;
  final double width;
  final int span;
}
