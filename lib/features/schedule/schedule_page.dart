import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

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
      if (mounted) setState(() => _courses = courses);
    } on ScheduleAuthExpiredException catch (_) {
      ZhengfangAuth.instance.markLoggedOut();
      if (mounted) {
        setState(() {
          _loggedIn = false;
          _courses = [];
          _error = null;
        });
      }
    } on ScheduleRequestException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final msg = code == null ? '网络请求失败，请稍后重试' : '网络请求失败（状态码：$code）';
      if (mounted) setState(() => _error = msg);
    } catch (e) {
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
    return Column(
      children: [
        _WeekSelector(
          currentWeek: _displayWeek,
          actualCurrentWeek: _currentWeek,
          onWeekChanged: (w) {
            setState(() => _displayWeek = w);
            if (_weekPageController.hasClients) {
              _weekPageController.jumpToPage(w - 1);
            }
          },
        ),
        Expanded(child: _buildWeekPager()),
      ],
    );
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
            currentWeek: week,
            actualCurrentWeek: _currentWeek,
          ),
        );
      },
    );
  }
}

// ── Week Selector ───────────────────────────────────────────────────────────

class _WeekSelector extends StatelessWidget {
  const _WeekSelector({
    required this.currentWeek,
    required this.actualCurrentWeek,
    required this.onWeekChanged,
  });

  final int currentWeek;
  final int actualCurrentWeek;
  final ValueChanged<int> onWeekChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 48,
      color: cs.surfaceContainerLowest,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: 20,
        itemBuilder: (context, index) {
          final week = index + 1;
          final isSelected = week == currentWeek;
          final isActual = week == actualCurrentWeek;

          return GestureDetector(
            onTap: () => onWeekChanged(week),
            child: Container(
              width: 48,
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$week',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected ? Colors.white : cs.onSurface,
                    ),
                  ),
                  if (isActual && !isSelected)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Schedule Grid ───────────────────────────────────────────────────────────

class _ScheduleGrid extends StatelessWidget {
  const _ScheduleGrid({
    super.key,
    required this.courses,
    required this.currentWeek,
    required this.actualCurrentWeek,
  });

  final List<CourseEntry> courses;
  final int currentWeek;
  final int actualCurrentWeek;

  static const _slotColumnWidth = 48.0;
  static const _slotHeight = 68.0;

  static const _courseColors = [
    Color(0xFF8B1A2D), // Wine Red (primary)
    Color(0xFF1565C0), // Blue
    Color(0xFF2E7D32), // Green
    Color(0xFFD4AF37), // Gold
    Color(0xFF7B1FA2), // Purple
    Color(0xFF00838F), // Teal
    Color(0xFFE65100), // Orange
    Color(0xFFAD1457), // Pink
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
                        courses: courses
                            .where((c) => c.weekday == day)
                            .toList(),
                        colorFor: _colorForCourse,
                        dayColumnWidth: dayColumnWidth,
                        currentWeek: currentWeek,
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
    final today = DateTime.now().weekday; // 1=Mon
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
    required this.courses,
    required this.colorFor,
    required this.dayColumnWidth,
    required this.currentWeek,
  });

  final List<CourseEntry> courses;
  final Color Function(String, bool) colorFor;
  final double dayColumnWidth;
  final int currentWeek;

  @override
  Widget build(BuildContext context) {
    final placements = _buildCoursePlacements();

    return SizedBox(
      width: dayColumnWidth,
      height: _ScheduleGrid._slotHeight * 13,
      child: Stack(
        children: [
          for (final placement in placements)
            Positioned(
              left:
                  placement.column * (dayColumnWidth / placement.totalColumns),
              top:
                  (placement.course.startLesson - 1) *
                  _ScheduleGrid._slotHeight,
              width: dayColumnWidth / placement.totalColumns,
              height: _ScheduleGrid._slotHeight * placement.span,
              child: _CourseCell(
                course: placement.course,
                span: placement.span,
                color: colorFor(
                  placement.course.courseName,
                  placement.course.isInWeek(currentWeek),
                ),
                dayColumnWidth: dayColumnWidth / placement.totalColumns,
                isCurrentWeek: placement.course.isInWeek(currentWeek),
              ),
            ),
        ],
      ),
    );
  }

  List<_PlacedCourse> _buildCoursePlacements() {
    if (courses.isEmpty) return const [];

    final sortedCourses = [...courses]
      ..sort((a, b) {
        final byStart = a.startLesson.compareTo(b.startLesson);
        if (byStart != 0) return byStart;

        final byEnd = a.endLesson.compareTo(b.endLesson);
        if (byEnd != 0) return byEnd;

        return a.courseName.compareTo(b.courseName);
      });

    final placements = <_PlacedCourse>[];
    final clusters = <List<CourseEntry>>[];
    var currentCluster = <CourseEntry>[];
    var clusterEnd = 0;

    for (final course in sortedCourses) {
      if (currentCluster.isEmpty || course.startLesson > clusterEnd) {
        if (currentCluster.isNotEmpty) clusters.add(currentCluster);
        currentCluster = [course];
        clusterEnd = course.endLesson;
        continue;
      }

      currentCluster.add(course);
      if (course.endLesson > clusterEnd) clusterEnd = course.endLesson;
    }

    if (currentCluster.isNotEmpty) clusters.add(currentCluster);

    for (final cluster in clusters) {
      final columnEndLessons = <int>[];
      final assignments = <({CourseEntry course, int column})>[];

      for (final course in cluster) {
        var targetColumn = -1;

        for (var i = 0; i < columnEndLessons.length; i++) {
          if (columnEndLessons[i] < course.startLesson) {
            targetColumn = i;
            break;
          }
        }

        if (targetColumn == -1) {
          targetColumn = columnEndLessons.length;
          columnEndLessons.add(course.endLesson);
        } else {
          columnEndLessons[targetColumn] = course.endLesson;
        }

        assignments.add((course: course, column: targetColumn));
      }

      final totalColumns = columnEndLessons.length;
      for (final assignment in assignments) {
        final span =
            (assignment.course.endLesson - assignment.course.startLesson + 1)
                .clamp(1, 13 - assignment.course.startLesson + 1);

        placements.add(
          _PlacedCourse(
            course: assignment.course,
            column: assignment.column,
            totalColumns: totalColumns,
            span: span,
          ),
        );
      }
    }

    return placements;
  }
}

class _PlacedCourse {
  const _PlacedCourse({
    required this.course,
    required this.column,
    required this.totalColumns,
    required this.span,
  });

  final CourseEntry course;
  final int column;
  final int totalColumns;
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
                text: '教师：${course.teacherName}',
              ),
              const SizedBox(height: 10),
              _DetailRow(
                icon: Icons.meeting_room_outlined,
                text: '教室：${course.classroom}',
              ),
              const SizedBox(height: 10),
              _DetailRow(
                icon: Icons.place_outlined,
                text: '校区：${course.campus}',
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
        : Colors.transparent;
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
