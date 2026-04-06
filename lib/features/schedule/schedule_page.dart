import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/semester/semester_calendar.dart';
import '../../shared/widgets/login_widget.dart';
import 'schedule_model.dart';
import 'schedule_service.dart';

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  bool _loggedIn = false;
  bool _loading = false;
  String? _error;
  List<CourseEntry> _courses = [];
  List<CourseChangeRule> _courseChangeRules = const [];
  int _term = 12;
  int _displayWeek = 1;
  late final PageController _weekPageController;

  int get _currentWeek => SemesterCalendar.instance.weekForDate(DateTime.now());

  int get _academicYear {
    final now = DateTime.now();
    return now.month < 8 ? now.year - 1 : now.year;
  }

  @override
  void initState() {
    super.initState();
    _displayWeek = _currentWeek;
    _weekPageController = PageController(initialPage: _displayWeek - 1);
    _loggedIn = ZhengfangAuth.instance.isLoggedIn;
    if (_loggedIn) _fetchSchedule();
  }

  @override
  void dispose() {
    _weekPageController.dispose();
    super.dispose();
  }

  void _onWeekPageChanged(int index) {
    final nextWeek = index + 1;
    if (nextWeek == _displayWeek) return;
    setState(() => _displayWeek = nextWeek);
  }

  Future<void> _fetchSchedule() async {
    final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final courses = await ScheduleService.instance.fetchSchedule(
        studentId,
        _academicYear,
        _term,
      );

      List<CourseChangeRule> courseChangeRules = const [];
      try {
        courseChangeRules = await ScheduleService.instance
            .fetchCourseChangeRules(studentId);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _courses = courses;
          _courseChangeRules = courseChangeRules;
        });
      }
    } on ScheduleAuthExpiredException catch (_) {
      ZhengfangAuth.instance.markLoggedOut();
      if (mounted) {
        setState(() {
          _loggedIn = false;
          _courses = [];
          _courseChangeRules = const [];
          _error = null;
        });
      }
    } on ScheduleRequestException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final msg = code == null ? '网络请求失败，请稍后重试' : '网络请求失败（状态码：$code）';
      if (mounted) setState(() => _error = msg);
    } catch (_) {
      if (mounted) setState(() => _error = '获取课表失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onLoginSuccess() {
    setState(() => _loggedIn = true);
    _fetchSchedule();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课表'),
        actions: _loggedIn
            ? [
                PopupMenuButton<int>(
                  icon: const Icon(Icons.calendar_today),
                  tooltip: '切换学期',
                  onSelected: (v) {
                    setState(() {
                      _term = v;
                      _displayWeek = _currentWeek;
                    });
                    if (_weekPageController.hasClients) {
                      _weekPageController.jumpToPage(_displayWeek - 1);
                    }
                    _fetchSchedule();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 3, child: Text('第一学期')),
                    PopupMenuItem(value: 12, child: Text('第二学期')),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _fetchSchedule,
                ),
              ]
            : null,
      ),
      body: _loggedIn ? _buildScheduleBody() : _buildLoginBody(),
    );
  }

  Widget _buildLoginBody() => LoginWidget(onLoginSuccess: _onLoginSuccess);

  Widget _buildScheduleBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: AppColors.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _fetchSchedule, child: const Text('重试')),
          ],
        ),
      );
    }
    return _buildWeekPager();
  }

  Widget _buildWeekPager() {
    return PageView.builder(
      controller: _weekPageController,
      itemCount: 20,
      onPageChanged: _onWeekPageChanged,
      allowImplicitScrolling: true,
      itemBuilder: (context, index) {
        final week = index + 1;
        return RepaintBoundary(
          child: _ScheduleGrid(
            key: ValueKey('week-grid-$week'),
            courses: _courses,
            courseChangeRules: _courseChangeRules,
            currentWeek: week,
            actualCurrentWeek: _currentWeek,
          ),
        );
      },
    );
  }
}

class _ScheduleGrid extends StatelessWidget {
  const _ScheduleGrid({
    super.key,
    required this.courses,
    required this.courseChangeRules,
    required this.currentWeek,
    required this.actualCurrentWeek,
  });

  final List<CourseEntry> courses;
  final List<CourseChangeRule> courseChangeRules;
  final int currentWeek;
  final int actualCurrentWeek;

  static const _slotColumnWidth = 48.0;
  static const _slotHeight = 68.0;

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

  Color _colorForCourse(String name, bool isCurrentWeek) {
    final index = name.hashCode.abs() % _courseColors.length;
    return isCurrentWeek ? _courseColors[index] : _inactiveColors[index];
  }

  @override
  Widget build(BuildContext context) {
    final effectiveWeekCourses = ScheduleService.instance
        .buildEffectiveWeekCourses(
          courses: courses,
          week: currentWeek,
          changeRules: courseChangeRules,
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final dayColumnWidth = (constraints.maxWidth - _slotColumnWidth) / 7;

        return Column(
          children: [
            _DayHeaders(
              slotColumnWidth: _slotColumnWidth,
              dayColumnWidth: dayColumnWidth,
              currentWeek: currentWeek,
              isCurrentWeek: currentWeek == actualCurrentWeek,
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SlotColumn(slotColumnWidth: _slotColumnWidth),
                    for (int day = 1; day <= 7; day++)
                      _DayColumn(
                        currentWeekCourses: effectiveWeekCourses
                            .where((course) => course.weekday == day)
                            .toList(),
                        otherWeekCourses: courses
                            .where(
                              (course) =>
                                  course.weekday == day &&
                                  !course.isInWeek(currentWeek),
                            )
                            .toList(),
                        colorFor: _colorForCourse,
                        dayColumnWidth: dayColumnWidth,
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

class _DayHeaders extends StatelessWidget {
  const _DayHeaders({
    required this.slotColumnWidth,
    required this.dayColumnWidth,
    required this.currentWeek,
    required this.isCurrentWeek,
  });

  final double slotColumnWidth;
  final double dayColumnWidth;
  final int currentWeek;
  final bool isCurrentWeek;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final today = DateTime.now().weekday;
    final weekStartDate = SemesterCalendar.instance.semesterStartDate.value.add(
      Duration(days: (currentWeek - 1) * 7),
    );

    return Container(
      color: cs.surfaceContainerLowest,
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: slotColumnWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '第$currentWeek周',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isCurrentWeek ? '本周' : '非本周',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          for (int i = 0; i < 7; i++)
            Builder(
              builder: (context) {
                final date = weekStartDate.add(Duration(days: i));
                final isToday = isCurrentWeek && (i + 1) == today;

                return SizedBox(
                  width: dayColumnWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: EdgeInsets.symmetric(
                          horizontal: isToday ? 12 : 0,
                          vertical: isToday ? 6 : 0,
                        ),
                        decoration: BoxDecoration(
                          color: isToday
                              ? AppColors.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${date.day}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isToday
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isToday ? Colors.white : cs.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '周${'一二三四五六日'[i]}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isToday
                              ? FontWeight.w700
                              : FontWeight.normal,
                          color: isToday
                              ? AppColors.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SlotColumn extends StatelessWidget {
  const _SlotColumn({required this.slotColumnWidth});

  final double slotColumnWidth;

  static const _slotTimes = [
    ['08:00', '08:40'],
    ['08:45', '09:25'],
    ['09:45', '10:25'],
    ['10:30', '11:10'],
    ['11:15', '11:55'],
    ['13:30', '14:10'],
    ['14:15', '14:55'],
    ['15:15', '15:55'],
    ['16:00', '16:40'],
    ['16:45', '17:25'],
    ['18:30', '19:10'],
    ['19:15', '19:55'],
    ['20:00', '20:40'],
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (int i = 0; i < 13; i++)
          Container(
            width: slotColumnWidth,
            height: _ScheduleGrid._slotHeight,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _slotTimes[i][0],
                  style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.currentWeekCourses,
    required this.otherWeekCourses,
    required this.colorFor,
    required this.dayColumnWidth,
  });

  final List<CourseEntry> currentWeekCourses;
  final List<CourseEntry> otherWeekCourses;
  final Color Function(String, bool) colorFor;
  final double dayColumnWidth;

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
      height: _ScheduleGrid._slotHeight * 13,
      child: Stack(
        children: [
          for (final placement in placements)
            Positioned(
              left: placement.left,
              top:
                  (placement.entry.course.startLesson - 1) *
                  _ScheduleGrid._slotHeight,
              width: placement.width,
              height: _ScheduleGrid._slotHeight * placement.span,
              child: _CourseCell(
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

    if (currentEntries.isEmpty) {
      return _buildStandardPlacements(otherEntries, dayColumnWidth);
    }

    final placements = <_PlacedCourse>[
      ..._buildStandardPlacements(currentEntries, dayColumnWidth),
    ];

    if (otherEntries.isEmpty) return placements;

    final assignments = _assignColumns(otherEntries);
    final previewWidth = _clampDouble(
      dayColumnWidth * (currentEntries.length > 1 ? 0.24 : 0.28),
      14,
      20,
    );
    final previewStep = previewWidth * 0.56;
    final maxLeft = dayColumnWidth - previewWidth;

    for (final assignment in assignments) {
      final span =
          (assignment.entry.course.endLesson -
                  assignment.entry.course.startLesson +
                  1)
              .clamp(1, 13 - assignment.entry.course.startLesson + 1);

      placements.add(
        _PlacedCourse(
          entry: assignment.entry,
          left: _clampDouble(
            maxLeft - assignment.column * previewStep,
            0,
            maxLeft,
          ),
          width: previewWidth,
          span: span,
        ),
      );
    }

    return placements;
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
              .clamp(1, 13 - assignment.entry.course.startLesson + 1);

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

  double _clampDouble(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
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

class _CourseCell extends StatelessWidget {
  const _CourseCell({
    required this.course,
    required this.span,
    required this.color,
    required this.dayColumnWidth,
    required this.isCurrentWeek,
  });

  final CourseEntry course;
  final int span;
  final Color color;
  final double dayColumnWidth;
  final bool isCurrentWeek;

  void _showCourseDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final textTheme = Theme.of(context).textTheme;
        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                course.courseName,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              _DetailRow(
                icon: Icons.person_outline,
                text:
                    '教师：${course.teacherName.isEmpty ? '待定' : course.teacherName}',
              ),
              const SizedBox(height: 10),
              _DetailRow(
                icon: Icons.meeting_room_outlined,
                text:
                    '教室：${course.classroom.isEmpty ? '待定' : course.classroom}',
              ),
              const SizedBox(height: 10),
              _DetailRow(
                icon: Icons.place_outlined,
                text: '校区：${course.campus.isEmpty ? '待定' : course.campus}',
              ),
              const SizedBox(height: 10),
              _DetailRow(
                icon: Icons.schedule,
                text: '节次：第 ${course.startLesson} - ${course.endLesson} 节',
              ),
              const SizedBox(height: 10),
              _DetailRow(
                icon: Icons.calendar_view_week,
                text: '周次：${course.weekRange}',
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final overlayColor = isCurrentWeek
        ? color.withValues(alpha: 0.1)
        : Colors.grey.withValues(alpha: 0.06);
    final contentColor = isCurrentWeek ? color : Colors.grey.shade500;

    return Container(
      width: dayColumnWidth,
      height: _ScheduleGrid._slotHeight * span,
      padding: const EdgeInsets.all(2),
      child: Material(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => _showCourseDetail(context),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: overlayColor,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 24;
                final compact =
                    constraints.maxWidth < 34 || constraints.maxHeight < 110;
                final dense = constraints.maxHeight < 92;
                final titleFontSize = narrow ? 10.5 : 12.0;
                final titleLines = constraints.maxHeight >= 180
                    ? (narrow ? 7 : 6)
                    : constraints.maxHeight >= 120
                    ? (narrow ? 5 : 4)
                    : 3;
                final showClassroom =
                    course.classroom.isNotEmpty &&
                    !narrow &&
                    constraints.maxHeight >= 88;
                final showWeekTag =
                    !isCurrentWeek && !compact && constraints.maxHeight >= 112;

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: isCurrentWeek ? color : Colors.grey.shade300,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(8),
                          bottomLeft: Radius.circular(8),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          narrow ? 4 : 6,
                          6,
                          narrow ? 2 : 4,
                          6,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  course.courseName,
                                  style: TextStyle(
                                    fontSize: titleFontSize,
                                    fontWeight: FontWeight.w600,
                                    color: contentColor,
                                    height: dense ? 1.1 : 1.18,
                                  ),
                                  maxLines: titleLines,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            if (showClassroom) ...[
                              const SizedBox(height: 3),
                              Text(
                                course.classroom,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: contentColor.withValues(alpha: 0.8),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            if (showWeekTag) ...[
                              const SizedBox(height: 2),
                              Text(
                                '非本周',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey.shade400,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}
