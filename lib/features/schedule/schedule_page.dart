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
  int _displayWeek = 1;
  int _weekSlideDirection = 1;

  int get _currentWeek {
    final now = DateTime.now();
    final semStart = DateTime(now.year, 2, 24);
    final diff = now.difference(semStart).inDays;
    return ((diff ~/ 7) + 1).clamp(1, 20);
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
    _displayWeek = _currentWeek;
    _loggedIn = ZhengfangAuth.instance.isLoggedIn;
    if (_loggedIn) _fetchSchedule();
  }

  void _changeWeekBySwipe(int delta) {
    final nextWeek = (_displayWeek + delta).clamp(1, 20);
    if (nextWeek == _displayWeek) return;
    setState(() {
      _weekSlideDirection = delta >= 0 ? 1 : -1;
      _displayWeek = nextWeek;
    });
  }

  void _onHorizontalSwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    if (velocity < 0) {
      _changeWeekBySwipe(1);
      return;
    }
    _changeWeekBySwipe(-1);
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
                    setState(() {
                      _term = v;
                      _displayWeek = _currentWeek;
                    });
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
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: _onHorizontalSwipeEnd,
      child: _buildAnimatedScheduleGrid(),
    );
  }

  Widget _buildAnimatedScheduleGrid() {
    final currentKey = ValueKey<int>(_displayWeek);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            ...[currentChild].whereType<Widget>(),
          ],
        );
      },
      transitionBuilder: (child, animation) {
        final isIncoming = child.key == currentKey;
        final beginX = isIncoming
            ? (_weekSlideDirection > 0 ? 1.0 : -1.0)
            : 0.0;
        final endX = isIncoming ? 0.0 : (_weekSlideDirection > 0 ? -1.0 : 1.0);
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );

        return ClipRect(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(beginX, 0),
              end: Offset(endX, 0),
            ).animate(curve),
            child: FadeTransition(
              opacity: Tween<double>(
                begin: isIncoming ? 0.9 : 1.0,
                end: isIncoming ? 1.0 : 0.9,
              ).animate(curve),
              child: child,
            ),
          ),
        );
      },
      child: _ScheduleGrid(
        key: currentKey,
        courses: _courses,
        currentWeek: _displayWeek,
      ),
    );
  }
}

// ── Schedule Grid ─────────────────────────────────────────────────────────────

class _ScheduleGrid extends StatelessWidget {
  const _ScheduleGrid({
    super.key,
    required this.courses,
    required this.currentWeek,
  });
  final List<CourseEntry> courses;
  final int currentWeek;

  static const _slotColumnWidth = 54.0;

  // 柔和的配色方案，与截图类似
  static const _courseColors = [
    Color(0xFF5B9BD5), // 柔和蓝
    Color(0xFF70AD47), // 柔和绿
    Color(0xFFE74C3C), // 柔和红
    Color(0xFFF39C12), // 柔和橙
    Color(0xFF9B59B6), // 柔和紫
    Color(0xFF1ABC9C), // 柔和青
    Color(0xFFE67E22), // 柔和珊瑚
    Color(0xFF3498DB), // 柔和靛蓝
  ];

  // 柔和的非本周课程颜色（浅灰色系）
  static const _inactiveCourseColors = [
    Color(0xFFB0C4DE), // 浅灰蓝
    Color(0xFFB8D4B8), // 浅灰绿
    Color(0xFFD4B8B8), // 浅灰红
    Color(0xFFE8D4B8), // 浅灰橙
    Color(0xFFD4B8D4), // 浅灰紫
    Color(0xFFB8D4D4), // 浅灰青
    Color(0xFFE8C4B8), // 浅灰珊瑚
    Color(0xFFB8C8E8), // 浅灰靛蓝
  ];

  Color _colorForCourse(String name, bool isCurrentWeek) {
    final index = name.hashCode.abs() % _courseColors.length;
    return isCurrentWeek ? _courseColors[index] : _inactiveCourseColors[index];
  }

  Color _textColorForCourse(String name, bool isCurrentWeek) {
    return isCurrentWeek ? Colors.white : Colors.grey.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dayColumnWidth = (screenWidth - _slotColumnWidth) / 7;

    // 计算每天每节有多少门课程（用于显示徽章）
    final daySlotCounts = <int, Map<int, int>>{};
    for (int day = 1; day <= 7; day++) {
      daySlotCounts[day] = {};
      final dayCourses = courses.where((c) => c.weekday == day).toList();
      for (int slot = 1; slot <= 13; slot++) {
        final count = dayCourses
            .where((c) => c.startLesson <= slot && c.endLesson >= slot)
            .length;
        if (count > 1) {
          daySlotCounts[day]![slot] = count;
        }
      }
    }

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
                    textColorFor: _textColorForCourse,
                    dayColumnWidth: dayColumnWidth,
                    currentWeek: currentWeek,
                    slotCounts: daySlotCounts[day] ?? {},
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

  // 每节课的起止时间（默认）
  static const _slotTimes = [
    ['08:00', '08:40'], // 第1节
    ['08:45', '09:25'], // 第2节
    ['09:45', '10:25'], // 第3节
    ['10:30', '11:10'], // 第4节
    ['11:15', '11:55'], // 第5节
    ['13:30', '14:10'], // 第6节
    ['14:15', '14:55'], // 第7节
    ['15:15', '15:55'], // 第8节
    ['16:00', '16:40'], // 第9节
    ['16:45', '17:25'], // 第10节
    ['18:30', '19:10'], // 第11节
    ['19:15', '19:55'], // 第12节
    ['20:00', '20:40'], // 第13节
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < 13; i++)
          Container(
            width: slotColumnWidth,
            height: 90,
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
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _slotTimes[i][0],
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
                Text(
                  _slotTimes[i][1],
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
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
    required this.textColorFor,
    required this.dayColumnWidth,
    required this.currentWeek,
    required this.slotCounts,
  });

  final int day;
  final List<CourseEntry> courses;
  final Color Function(String, bool) colorFor;
  final Color Function(String, bool) textColorFor;
  final double dayColumnWidth;
  final int currentWeek;
  final Map<int, int> slotCounts;

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
        // 获取这节课开始时的课程数量（用于徽章）
        final courseCount = slotCounts[slot];
        cells.add(
          _CourseCell(
            course: course,
            span: span,
            color: colorFor(course.courseName, course.isInWeek(currentWeek)),
            textColor: textColorFor(
              course.courseName,
              course.isInWeek(currentWeek),
            ),
            dayColumnWidth: dayColumnWidth,
            isCurrentWeek: course.isInWeek(currentWeek),
            courseCount: courseCount,
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
    required this.textColor,
    required this.dayColumnWidth,
    required this.isCurrentWeek,
    this.courseCount,
  });

  final CourseEntry course;
  final int span;
  final Color color;
  final Color textColor;
  final double dayColumnWidth;
  final bool isCurrentWeek;
  final int? courseCount;

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

  // 菱形符号
  Widget _buildDiamond(Color diamondColor) {
    return Transform.rotate(
      angle: 0.785398, // 45度
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: diamondColor,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 本周课程：白色背景+淡课程色遮罩
    // 非本周课程：白色背景+灰色
    final stripColor = isCurrentWeek ? color : Colors.grey.shade300;
    final overlayColor = isCurrentWeek
        ? color.withValues(alpha: 0.12)
        : Colors.transparent;
    final borderColor = isCurrentWeek
        ? color.withValues(alpha: 0.3)
        : Colors.grey.shade200;
    // 文本颜色：当前周用对应颜色，非本周用灰色
    final contentColor = isCurrentWeek ? color : Colors.grey.shade500;

    return Container(
      width: dayColumnWidth,
      height: 90.0 * span,
      padding: const EdgeInsets.all(2),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        elevation: isCurrentWeek ? 1 : 0,
        child: InkWell(
          onTap: () => _showCourseDetail(context),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: overlayColor,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左侧颜色条
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: stripColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(8),
                      bottomLeft: Radius.circular(8),
                    ),
                  ),
                ),
                // 内容区域
                Expanded(
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              course.courseName,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: contentColor,
                                height: 1.2,
                              ),
                              maxLines: span > 1 ? 4 : 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // 校区
                            if (course.campus.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                course.campus,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: contentColor.withValues(alpha: 0.8),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            // 教室
                            if (course.classroom.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  _buildDiamond(contentColor),
                                  const SizedBox(width: 3),
                                  Expanded(
                                    child: Text(
                                      course.classroom,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: contentColor.withValues(
                                          alpha: 0.8,
                                        ),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            // 非本周标记
                            if (!isCurrentWeek) ...[
                              const SizedBox(height: 2),
                              Text(
                                '[非本周]',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // 课程数量徽章（右上角）
                      if (courseCount != null && courseCount! > 1)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: stripColor, width: 1.5),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$courseCount',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: stripColor,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
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
      height: 90,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
      ),
    );
  }
}
