import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../campus_card/campus_card_service.dart';
import '../schedule/schedule_model.dart';
import '../schedule/schedule_service.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/semester/semester_calendar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _campusCardBalance = '--';
  CourseEntry? _nextCourse;
  String _nextCourseLabel = '';
  bool _courseLoggedIn = false;

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  int get _currentWeek => SemesterCalendar.instance.weekForDate(DateTime.now());

  @override
  void initState() {
    super.initState();
    SemesterCalendar.instance.semesterStartDate.addListener(
      _onSemesterStartChanged,
    );
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    await Future.wait([_refreshCampusCardBalance(), _refreshNextCourse()]);
  }

  @override
  void dispose() {
    SemesterCalendar.instance.semesterStartDate.removeListener(
      _onSemesterStartChanged,
    );
    super.dispose();
  }

  void _onSemesterStartChanged() {
    if (!mounted) return;
    setState(() {});
    _refreshNextCourse();
  }

  static const _slotStartTimes = [
    '08:00',
    '08:45',
    '09:45',
    '10:30',
    '11:15',
    '13:30',
    '14:15',
    '15:15',
    '16:00',
    '16:45',
    '18:30',
    '19:15',
    '20:00',
  ];

  static const _slotEndTimes = [
    '08:40',
    '09:25',
    '10:25',
    '11:10',
    '11:55',
    '14:10',
    '14:55',
    '15:55',
    '16:40',
    '17:25',
    '19:10',
    '19:55',
    '20:40',
  ];

  String _normalizeCourseName(String value) {
    return value.toLowerCase().replaceAll(
      RegExp('[\\s\\-—_（）()【】\\[\\]<>《》,，.。:：;；"\\\'、/+]+'),
      '',
    );
  }

  bool _matchesCourseName(String left, String right) {
    final a = _normalizeCourseName(left);
    final b = _normalizeCourseName(right);
    if (a.isEmpty || b.isEmpty) return false;
    return a.contains(b) || b.contains(a);
  }

  bool _isCancelledCourse(
    CourseEntry course,
    int week,
    List<CourseCancellationRule> cancellationRules,
  ) {
    for (final rule in cancellationRules) {
      if (rule.week != week || rule.weekday != course.weekday) continue;
      final isOverlap =
          course.startLesson <= rule.endLesson &&
          course.endLesson >= rule.startLesson;
      if (!isOverlap) continue;
      final ruleCourseName = rule.courseName;
      if (ruleCourseName == null || ruleCourseName.isEmpty) return true;
      if (_matchesCourseName(course.courseName, ruleCourseName)) return true;
    }
    return false;
  }

  static String _slotTimeRange(int start, int end) {
    final s = (start >= 1 && start <= 13) ? _slotStartTimes[start - 1] : '??';
    final e = (end >= 1 && end <= 13) ? _slotEndTimes[end - 1] : '??';
    return '$s-$e';
  }

  int _weekForDate(DateTime date) =>
      SemesterCalendar.instance.weekForDate(date);

  int _nextStartLesson(DateTime now) {
    for (int i = 0; i < _slotStartTimes.length; i++) {
      final parts = _slotStartTimes[i].split(':');
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);
      if (now.hour < hour || (now.hour == hour && now.minute < minute)) {
        return i + 1;
      }
    }
    return 14;
  }

  String _labelForDate(DateTime date, DateTime today) {
    final day = DateTime(date.year, date.month, date.day);
    final base = DateTime(today.year, today.month, today.day);
    final delta = day.difference(base).inDays;
    if (delta == 0) return '今天';
    if (delta == 1) return '明天';
    return '${date.month}/${date.day} ${_weekdayLabels[date.weekday - 1]}';
  }

  Future<void> _refreshNextCourse() async {
    final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
    if (studentId.isEmpty) {
      if (mounted) {
        setState(() {
          _courseLoggedIn = false;
          _nextCourse = null;
          _nextCourseLabel = '';
        });
      }
      return;
    }
    try {
      final now = DateTime.now();
      final academicYear = now.month < 8 ? now.year - 1 : now.year;
      final term = now.month >= 2 && now.month < 8 ? 12 : 3;
      final courses = await ScheduleService.instance.fetchSchedule(
        studentId,
        academicYear,
        term,
      );
      List<CourseCancellationRule> cancellationRules = const [];
      try {
        cancellationRules = await ScheduleService.instance
            .fetchCancellationRules(studentId);
      } catch (_) {}
      if (!mounted) return;
      final today = DateTime(now.year, now.month, now.day);
      final nextLessonToday = _nextStartLesson(now);
      for (int offset = 0; offset < 14; offset++) {
        final date = today.add(Duration(days: offset));
        final week = _weekForDate(date);
        final dayCourses =
            courses
                .where((c) => c.weekday == date.weekday && c.isInWeek(week))
                .where((c) => !_isCancelledCourse(c, week, cancellationRules))
                .where((c) => offset > 0 || c.startLesson >= nextLessonToday)
                .toList()
              ..sort((a, b) => a.startLesson.compareTo(b.startLesson));
        if (dayCourses.isNotEmpty) {
          setState(() {
            _courseLoggedIn = true;
            _nextCourse = dayCourses.first;
            _nextCourseLabel = _labelForDate(date, today);
          });
          return;
        }
      }
      setState(() {
        _courseLoggedIn = true;
        _nextCourse = null;
        _nextCourseLabel = '';
      });
    } on ScheduleAuthExpiredException {
      ZhengfangAuth.instance.markLoggedOut();
      if (mounted) {
        setState(() {
          _courseLoggedIn = false;
          _nextCourse = null;
          _nextCourseLabel = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _courseLoggedIn = true;
          _nextCourse = null;
          _nextCourseLabel = '';
        });
      }
    }
  }

  Future<void> _refreshCampusCardBalance() async {
    final cached = CampusCardService.instance.cachedBalance;
    if (cached != null && mounted) {
      setState(() {
        _campusCardBalance = CampusCardService.instance.formatBalance(cached);
      });
      return;
    }
    final networkBalance = await CampusCardService.instance.fetchBalance();
    if (!mounted) return;
    setState(() {
      _campusCardBalance = CampusCardService.instance.formatBalance(
        networkBalance,
      );
    });
  }

  Future<void> _openSchedule(BuildContext context) async {
    await context.pushNamed('schedule');
    if (!mounted) return;
    _refreshNextCourse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? null : const Color(0xFFF5F5F5),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const SizedBox(height: 16),
              // Two-column staggered waterfall layout
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column - taller cards first
                    Expanded(
                      child: Column(
                        children: [
                          _buildCampusCardBalance(context),
                          const SizedBox(height: 10),
                          _buildQuickServices(context),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Right column - shorter cards first (stagger effect)
                    Expanded(
                      child: Column(
                        children: [
                          _buildNoticeCard(context),
                          const SizedBox(height: 10),
                          _buildGradesCard(context),
                          const SizedBox(height: 10),
                          _buildMoreServicesCard(context),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: GestureDetector(
        onTap: () => _openSchedule(context),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: label + week + action icons
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '下节课',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '第 $_currentWeek 周',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.notifications_outlined,
                      color: Colors.white,
                      size: 22,
                    ),
                    onPressed: () => context.pushNamed('notice-list'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white,
                      size: 22,
                    ),
                    onPressed: () => context.pushNamed('settings'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Course content based on state
              _buildCourseContent(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCourseContent(BuildContext context) {
    if (!_courseLoggedIn) {
      return Row(
        children: [
          Expanded(
            child: Text(
              '登录后查看课程',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Icon(
            Icons.arrow_forward_ios,
            color: Colors.white.withValues(alpha: 0.5),
            size: 18,
          ),
        ],
      );
    }

    if (_nextCourse == null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              '近期无课',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const Icon(
            Icons.check_circle_outline,
            color: AppColors.success,
            size: 24,
          ),
        ],
      );
    }

    final course = _nextCourse!;
    final time = _slotTimeRange(course.startLesson, course.endLesson);
    final whenText = _nextCourseLabel.isEmpty
        ? time
        : '$_nextCourseLabel $time';
    final campus = course.campus.trim();
    final classroom = course.classroom.trim();
    final location = (campus.isEmpty && classroom.isEmpty)
        ? '地点待定'
        : (campus.isEmpty
              ? classroom
              : (classroom.isEmpty ? campus : '$campus $classroom'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            course.courseName,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(
              Icons.schedule,
              size: 16,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Text(
              whenText,
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '第 ${course.startLesson}-${course.endLesson} 节',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 16,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                location,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCampusCardBalance(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return GestureDetector(
      onTap: () => context.pushNamed('campus-card'),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        height: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_outlined,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '¥$_campusCardBalance',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '校园卡余额',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickServices(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    final services = [
      _ServiceItem(
        icon: Icons.calendar_today_outlined,
        label: '课表',
        color: AppColors.primary,
        route: 'schedule',
      ),
      _ServiceItem(
        icon: Icons.grade_outlined,
        label: '成绩',
        color: AppColors.warning,
        route: 'grades',
      ),
      _ServiceItem(
        icon: Icons.local_library_outlined,
        label: '图书馆',
        color: AppColors.info,
        route: null,
      ),
      _ServiceItem(
        icon: Icons.meeting_room_outlined,
        label: '空教室',
        color: AppColors.success,
        route: null,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '快捷服务',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildServiceButton(context, services[0])),
              const SizedBox(width: 8),
              Expanded(child: _buildServiceButton(context, services[1])),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildServiceButton(context, services[2])),
              const SizedBox(width: 8),
              Expanded(child: _buildServiceButton(context, services[3])),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildServiceButton(BuildContext context, _ServiceItem item) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: item.route != null ? () => context.pushNamed(item.route!) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: item.color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, color: item.color, size: 22),
            const SizedBox(height: 6),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoticeCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return GestureDetector(
      onTap: () => context.pushNamed('notice-list'),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        height: 80,
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.campaign_outlined,
                color: AppColors.gold,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '校园公告',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildGradesCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return GestureDetector(
      onTap: () => context.pushNamed('grades'),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.school_outlined,
                color: AppColors.warning,
                size: 22,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '成绩查询',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '查看各科成绩与绩点',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreServicesCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return GestureDetector(
      onTap: () => context.pushNamed('service-hall'),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.apps, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '更多服务',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ── Service Grid ────────────────────────────────────────────────────────────

class _ServiceItem {
  const _ServiceItem({
    required this.icon,
    required this.label,
    required this.color,
    this.route,
  });
  final IconData icon;
  final String label;
  final Color color;
  final String? route;
}
