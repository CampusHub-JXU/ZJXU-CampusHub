import 'package:flutter/material.dart';

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
        DateTime.now().year,
        _term,
      );
      if (mounted) setState(() => _courses = courses);
    } catch (e) {
      if (mounted) setState(() => _error = '获取课表失败：$e');
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

  static const _courseColors = [
    Color(0xFFBBDEFB), Color(0xFFC8E6C9), Color(0xFFFFE0B2),
    Color(0xFFE1BEE7), Color(0xFFB2EBF2), Color(0xFFF8BBD0),
    Color(0xFFDCEDC8), Color(0xFFFFCCBC),
  ];

  Color _colorForCourse(String name) =>
      _courseColors[name.hashCode.abs() % _courseColors.length];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _WeekHeader(currentWeek: currentWeek),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SlotColumn(),
                    for (int day = 1; day <= 7; day++)
                      _DayColumn(
                        day: day,
                        courses: courses.where((c) => c.weekday == day).toList(),
                        colorFor: _colorForCourse,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({required this.currentWeek});
  final int currentWeek;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.primaryContainer,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '第$currentWeek周',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
            ),
          ),
          for (int i = 0; i < 7; i++)
            SizedBox(
              width: 52,
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
  const _SlotColumn();

  static const _slotTimes = [
    '08:00', '08:55', '09:55', '10:50',
    '14:00', '14:55', '15:55', '16:50',
    '19:00', '19:55', '20:50', '21:45', '22:40',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < 13; i++)
          Container(
            width: 44,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${i + 1}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
                Text(_slotTimes[i],
                    style:
                        const TextStyle(fontSize: 9, color: Colors.grey)),
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
  });
  final int day;
  final List<CourseEntry> courses;
  final Color Function(String) colorFor;

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
        final span = (course.endLesson - course.startLesson + 1).clamp(1, 13 - slot + 1);
        cells.add(_CourseCell(
          course: course,
          span: span,
          color: colorFor(course.courseName),
        ));
        slot += span;
      } else {
        cells.add(_EmptyCell());
        slot++;
      }
    }

    return Column(children: cells);
  }
}

class _CourseCell extends StatelessWidget {
  const _CourseCell(
      {required this.course, required this.span, required this.color});
  final CourseEntry course;
  final int span;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 64.0 * span,
      padding: const EdgeInsets.all(2),
      child: Card(
        color: color,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                course.courseName,
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold),
                maxLines: span > 1 ? 3 : 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (span > 1) ...[
                const SizedBox(height: 2),
                Text(
                  course.classroom,
                  style: const TextStyle(fontSize: 9, color: Colors.black54),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCell extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 64,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
    );
  }
}
