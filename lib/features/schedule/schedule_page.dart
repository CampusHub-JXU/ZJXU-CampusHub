import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../../core/auth/zhengfang_auth.dart';
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
  int _term = 12; // 3=first, 12=second

  int get _currentWeek {
    final now = DateTime.now();
    final semStart = DateTime(now.year, 2, 24);
    final diff = now.difference(semStart).inDays;
    return (diff ~/ 7).clamp(1, 20);
  }

  /// Academic year start: for spring semester (Feb-Jul), use previous year.
  int get _academicYear {
    final now = DateTime.now();
    // Spring semester (Feb-Jul) belongs to previous year's academic year
    return now.month < 8 ? now.year - 1 : now.year;
  }

  @override
  void initState() {
    super.initState();
    _loggedIn = ZhengfangAuth.instance.isLoggedIn;
    if (_loggedIn) _fetchSchedule();
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
        title: const Text('课表查询'),
        actions: _loggedIn
            ? [
                PopupMenuButton<int>(
                  icon: const Icon(Icons.calendar_today),
                  tooltip: '切换学期',
                  onSelected: (v) {
                    setState(() => _term = v);
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

  Widget _buildLoginBody() {
    return LoginWidget(onLoginSuccess: _onLoginSuccess);
  }

  Widget _buildScheduleBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _fetchSchedule, child: const Text('重试')),
          ],
        ),
      );
    }
    return _ScheduleGrid(courses: _courses, currentWeek: _currentWeek);
  }
}

// ── Schedule Grid ─────────────────────────────────────────────────────────────

class _ScheduleGrid extends StatelessWidget {
  const _ScheduleGrid({required this.courses, required this.currentWeek});
  final List<CourseEntry> courses;
  final int currentWeek;

  static const _slotColumnWidth = 44.0;

  static const _courseColors = [
    Color(0xFF64B5F6), // 柔和蓝
    Color(0xFF81C784), // 柔和绿
    Color(0xFFE57373), // 柔和红
    Color(0xFFFFB74D), // 柔和橙
    Color(0xFFBA68C8), // 柔和紫
    Color(0xFF4DB6AC), // 柔和青
    Color(0xFFFF8A65), // 柔和珊瑚
    Color(0xFF7986CB), // 柔和靛蓝
  ];

  Color _colorForCourse(String name) =>
      _courseColors[name.hashCode.abs() % _courseColors.length];

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dayColumnWidth = (screenWidth - _slotColumnWidth) / 7;

    return Column(
      children: [
        _WeekHeader(
          currentWeek: currentWeek,
          slotColumnWidth: _slotColumnWidth,
          dayColumnWidth: dayColumnWidth,
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SlotColumn(slotColumnWidth: _slotColumnWidth),
                for (int day = 1; day <= 7; day++)
                  _DayColumn(
                    day: day,
                    courses: courses.where((c) => c.weekday == day).toList(),
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
  }
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({
    required this.currentWeek,
    required this.slotColumnWidth,
    required this.dayColumnWidth,
  });

  final int currentWeek;
  final double slotColumnWidth;
  final double dayColumnWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.primaryContainer,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: slotColumnWidth,
            child: Text(
              '第$currentWeek周',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
            ),
          ),
          for (int i = 0; i < 7; i++)
            SizedBox(
              width: dayColumnWidth,
              child: Text(
                '周${'一二三四五六日'[i]}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onPrimaryContainer,
                  fontWeight: i >= 5 ? FontWeight.bold : FontWeight.normal,
                ),
              ),
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
    '08:00',
    '08:55',
    '09:55',
    '10:50',
    '14:00',
    '14:55',
    '15:55',
    '16:50',
    '19:00',
    '19:55',
    '20:50',
    '21:45',
    '22:40',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < 13; i++)
          Container(
            width: slotColumnWidth,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${i + 1}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _slotTimes[i],
                  style: const TextStyle(fontSize: 9, color: Colors.grey),
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
    required this.day,
    required this.courses,
    required this.colorFor,
    required this.dayColumnWidth,
    required this.currentWeek,
  });

  final int day;
  final List<CourseEntry> courses;
  final Color Function(String) colorFor;
  final double dayColumnWidth;
  final int currentWeek;

  @override
  Widget build(BuildContext context) {
    final Map<int, CourseEntry> slotMap = {};
    for (final c in courses) {
      for (int s = c.startLesson; s <= c.endLesson && s <= 13; s++) {
        slotMap[s] = c;
      }
    }

    final cells = <Widget>[];
    int slot = 1;
    while (slot <= 13) {
      final course = slotMap[slot];
      if (course != null && course.startLesson == slot) {
        final span = (course.endLesson - course.startLesson + 1).clamp(
          1,
          13 - slot + 1,
        );
        cells.add(
          _CourseCell(
            course: course,
            span: span,
            color: colorFor(course.courseName),
            dayColumnWidth: dayColumnWidth,
            isCurrentWeek: course.isInWeek(currentWeek),
          ),
        );
        slot += span;
      } else {
        cells.add(_EmptyCell(dayColumnWidth: dayColumnWidth));
        slot++;
      }
    }

    return Column(children: cells);
  }
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                course.courseName,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              _buildDetailRow(
                context,
                Icons.person_outline,
                '教师：${course.teacherName}',
              ),
              const SizedBox(height: 10),
              _buildDetailRow(
                context,
                Icons.meeting_room_outlined,
                '教室：${course.classroom}',
              ),
              const SizedBox(height: 10),
              _buildDetailRow(
                context,
                Icons.place_outlined,
                '校区：${course.campus}',
              ),
              const SizedBox(height: 10),
              _buildDetailRow(
                context,
                Icons.schedule,
                '节次：第 ${course.startLesson} - ${course.endLesson} 节',
              ),
              const SizedBox(height: 10),
              _buildDetailRow(
                context,
                Icons.calendar_view_week,
                '周次：${course.weekRange}',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(BuildContext context, IconData icon, String text) {
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

  @override
  Widget build(BuildContext context) {
    return Container(
      width: dayColumnWidth,
      height: 64.0 * span,
      padding: const EdgeInsets.all(3),
      child: Material(
        color: isCurrentWeek ? color : color.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        elevation: isCurrentWeek ? 1 : 0,
        child: InkWell(
          onTap: () => _showCourseDetail(context),
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        course.courseName,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isCurrentWeek
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.6),
                          height: 1.2,
                        ),
                        maxLines: span > 1 ? 3 : 2,
                        overflow: TextOverflow.visible,
                      ),
                    ),
                    if (span > 1) ...[
                      const SizedBox(height: 2),
                      Text(
                        course.classroom,
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.white.withValues(
                            alpha: isCurrentWeek ? 0.85 : 0.45,
                          ),
                          height: 1.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (!isCurrentWeek)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: const CustomPaint(
                      painter: _DiagonalLinePainter(lineCount: 5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCell extends StatelessWidget {
  const _EmptyCell({required this.dayColumnWidth});

  final double dayColumnWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: dayColumnWidth,
      height: 64,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
    );
  }
}

class _DiagonalLinePainter extends CustomPainter {
  const _DiagonalLinePainter({this.lineCount = 5});

  final int lineCount;

  @override
  void paint(Canvas canvas, Size size) {
    if (lineCount <= 0) return;

    final glowPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.72)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;

    final startShift = -size.width * 0.5;
    final endShift = size.width * 0.5;
    final step = lineCount == 1
        ? 0.0
        : (endShift - startShift) / (lineCount - 1);

    for (int i = 0; i < lineCount; i++) {
      final dx = startShift + step * i;
      final start = Offset(dx, size.height);
      final end = Offset(size.width + dx, 0);
      canvas.drawLine(start, end, glowPaint);
      canvas.drawLine(start, end, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalLinePainter oldDelegate) {
    return oldDelegate.lineCount != lineCount;
  }
}
