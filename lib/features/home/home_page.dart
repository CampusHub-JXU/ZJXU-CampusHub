import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../shared/widgets/ship_card.dart';
import '../campus_card/campus_card_service.dart';
import '../dorm_electricity/dorm_electricity_service.dart';
import '../notice/notice_service.dart';
import '../notice/notice_model.dart';
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
  double? _campusCardBalanceValue;
  String _dormElectricity = '--';
  List<Notice> _notices = [];
  int _currentNoticeIndex = 0;
  CourseEntry? _nextCourse;
  String _nextCourseLabel = '';
  bool _courseLoggedIn = false;
  bool _headerSolid = false;

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
    await Future.wait([
      _refreshCampusCardBalance(),
      _refreshDormElectricity(),
      _refreshNotices(),
      _refreshNextCourse(),
    ]);
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

  Future<void> _refreshNotices() async {
    final notices = await NoticeService.instance.fetchNotices();
    if (!mounted) return;
    setState(() => _notices = notices);
  }

  Future<void> _refreshDormElectricity() async {
    final cached = DormElectricityService.instance.cachedElectricity;
    if (cached != null && mounted) {
      setState(() {
        _dormElectricity = DormElectricityService.instance.formatElectricity(
          cached,
        );
      });
      return;
    }
    final value = await DormElectricityService.instance.fetchElectricity();
    if (!mounted) return;
    setState(() {
      _dormElectricity = DormElectricityService.instance.formatElectricity(
        value,
      );
    });
  }

  Future<void> _openDormElectricity(BuildContext context) async {
    final hasConfig = await DormElectricityService.instance.hasRoomConfig();
    if (!context.mounted) return;
    if (hasConfig) {
      await context.pushNamed('dorm-electricity');
    } else {
      await context.pushNamed('dorm-electricity-settings');
    }
    if (!mounted) return;
    _refreshDormElectricity();
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
      if (mounted)
        setState(() {
          _courseLoggedIn = false;
          _nextCourse = null;
          _nextCourseLabel = '';
        });
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
      if (mounted)
        setState(() {
          _courseLoggedIn = false;
          _nextCourse = null;
          _nextCourseLabel = '';
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _courseLoggedIn = true;
          _nextCourse = null;
          _nextCourseLabel = '';
        });
    }
  }

  Future<void> _refreshCampusCardBalance() async {
    final cached = CampusCardService.instance.cachedBalance;
    if (cached != null && mounted) {
      setState(() {
        _campusCardBalanceValue = cached;
        _campusCardBalance = CampusCardService.instance.formatBalance(cached);
      });
      return;
    }
    final networkBalance = await CampusCardService.instance.fetchBalance();
    if (!mounted) return;
    setState(() {
      _campusCardBalanceValue = networkBalance;
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

  Future<void> _openGrades(BuildContext context) async {
    await context.pushNamed('grades');
    if (!mounted) return;
    _refreshNextCourse();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          final shouldSolid = notification.metrics.pixels > 60;
          if (shouldSolid != _headerSolid) {
            setState(() => _headerSolid = shouldSolid);
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            _buildSliverAppBar(context),
            SliverToBoxAdapter(child: _buildNextClassCard(context)),
            SliverToBoxAdapter(child: _buildTodayOverview(context)),
            SliverToBoxAdapter(child: _buildServiceGrid(context)),
            SliverToBoxAdapter(child: _buildTodoReminders(context)),
            SliverToBoxAdapter(child: _buildCampusNews(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _buildSliverAppBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverAppBar(
      expandedHeight: 120,
      floating: false,
      pinned: true,
      elevation: _headerSolid ? 2 : 0,
      backgroundColor: _headerSolid
          ? (isDark ? AppColors.darkSurface : AppColors.surfaceL3)
          : Colors.transparent,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.only(left: 20, bottom: 14),
        title: Row(
          children: [
            Text(
              '第 $_currentWeek 周',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _headerSolid
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.white,
              ),
            ),
          ],
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [AppColors.primaryDark, const Color(0xFF3D1520)]
                  : [AppColors.primary, AppColors.primaryDark],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    '方正为人、勤慎治学',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.search, color: _headerSolid ? null : Colors.white),
          onPressed: () {},
        ),
        IconButton(
          icon: Icon(
            Icons.notifications_outlined,
            color: _headerSolid ? null : Colors.white,
          ),
          onPressed: () => context.pushNamed('notice-list'),
        ),
        IconButton(
          icon: Icon(
            Icons.settings_outlined,
            color: _headerSolid ? null : Colors.white,
          ),
          onPressed: () => context.pushNamed('settings'),
        ),
      ],
    );
  }

  Widget _buildNextClassCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: _NextClassCard(
        course: _nextCourse,
        label: _nextCourseLabel,
        loggedIn: _courseLoggedIn,
        slotTimeRange: _slotTimeRange,
        onTap: () => _openSchedule(context),
      ),
    );
  }

  Widget _buildTodayOverview(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = [
      _OverviewItem(
        icon: Icons.class_outlined,
        label: '今日课程',
        value: '3节',
        color: AppColors.primary,
      ),
      _OverviewItem(
        icon: Icons.check_circle_outline,
        label: '待办事项',
        value: '2项',
        color: AppColors.warning,
      ),
      _OverviewItem(
        icon: Icons.account_balance_wallet_outlined,
        label: '卡余额',
        value: '¥$_campusCardBalance',
        color: AppColors.success,
      ),
      _OverviewItem(
        icon: Icons.wifi,
        label: '校园网',
        value: '已连接',
        color: AppColors.info,
      ),
    ];

    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          return Container(
            width: 140,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(item.icon, size: 20, color: item.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.value,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildServiceGrid(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final services = [
      _ServiceItem(
        icon: Icons.calendar_today,
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
      _ServiceItem(
        icon: Icons.credit_card,
        label: '校园卡',
        color: AppColors.primary,
        route: 'campus-card',
      ),
      _ServiceItem(
        icon: Icons.build_outlined,
        label: '报修',
        color: AppColors.error,
        route: null,
      ),
      _ServiceItem(
        icon: Icons.directions_bus_outlined,
        label: '校车',
        color: AppColors.gold,
        route: null,
      ),
      _ServiceItem(
        icon: Icons.apps,
        label: '更多',
        color: cs.onSurfaceVariant,
        route: 'service-hall',
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ShipCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '服务',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 14),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 16,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
              ),
              itemCount: services.length,
              itemBuilder: (context, index) {
                final s = services[index];
                return _ServiceGridItem(
                  item: s,
                  onTap: s.route != null
                      ? () => context.pushNamed(s.route!)
                      : null,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodoReminders(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ShipCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 20, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  '待办提醒',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '查看全部',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _TodoItem(title: '高等数学作业', deadline: '今天 23:59', isUrgent: true),
            const SizedBox(height: 8),
            _TodoItem(title: '大学英语作文', deadline: '明天 17:00', isUrgent: false),
          ],
        ),
      ),
    );
  }

  Widget _buildCampusNews(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              '校园动态',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
            ),
          ),
          SizedBox(
            height: 160,
            child: _notices.isEmpty
                ? Center(
                    child: Text(
                      '加载中...',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _notices.length.clamp(0, 5),
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final notice = _notices[index];
                      return _NewsCard(
                        title: notice.title,
                        category: notice.category,
                        onTap: () => context.pushNamed('notice-list'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Next Class Card ─────────────────────────────────────────────────────────

class _NextClassCard extends StatelessWidget {
  const _NextClassCard({
    required this.course,
    required this.label,
    required this.loggedIn,
    required this.slotTimeRange,
    required this.onTap,
  });

  final CourseEntry? course;
  final String label;
  final bool loggedIn;
  final String Function(int, int) slotTimeRange;
  final VoidCallback onTap;

  String _locationText(CourseEntry course) {
    final campus = course.campus.trim();
    final classroom = course.classroom.trim();
    if (campus.isEmpty && classroom.isEmpty) return '地点待定';
    if (campus.isEmpty) return classroom;
    if (classroom.isEmpty) return campus;
    return '$campus $classroom';
  }

  @override
  Widget build(BuildContext context) {
    if (!loggedIn) {
      return ShipCard(
        onTap: onTap,
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '下节课',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '登录后查看课程',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: Colors.white.withValues(alpha: 0.5),
              size: 18,
            ),
          ],
        ),
      );
    }

    if (course == null) {
      return ShipCard(
        onTap: onTap,
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '下节课',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '近期无课',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.check_circle_outline,
              color: AppColors.success,
              size: 24,
            ),
          ],
        ),
      );
    }

    final time = slotTimeRange(course!.startLesson, course!.endLesson);
    final whenText = label.isEmpty ? time : '$label $time';
    final location = _locationText(course!);

    return ShipCard(
      onTap: onTap,
      gradient: const LinearGradient(
        colors: [AppColors.primary, AppColors.primaryDark],
      ),
      padding: const EdgeInsets.all(20),
      child: Stack(
        children: [
          // Ship watermark
          Positioned(
            right: -8,
            bottom: -12,
            child: Icon(
              Icons.sailing_outlined,
              size: 80,
              color: Colors.white.withValues(alpha: 0.06),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Subject tag
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  course!.courseName,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // Time
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
                    '第 ${course!.startLesson}-${course!.endLesson} 节',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Location
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
              const SizedBox(height: 16),
              // Action buttons
              Row(
                children: [
                  _CardActionButton(
                    icon: Icons.how_to_reg_outlined,
                    label: '签到',
                    onTap: () {},
                  ),
                  const SizedBox(width: 10),
                  _CardActionButton(
                    icon: Icons.directions_outlined,
                    label: '导航去这里',
                    onTap: () {},
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardActionButton extends StatelessWidget {
  const _CardActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Overview Item ───────────────────────────────────────────────────────────

class _OverviewItem {
  const _OverviewItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color color;
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

class _ServiceGridItem extends StatelessWidget {
  const _ServiceGridItem({required this.item, this.onTap});
  final _ServiceItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: item.color, size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            item.label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

// ── Todo Item ───────────────────────────────────────────────────────────────

class _TodoItem extends StatelessWidget {
  const _TodoItem({
    required this.title,
    required this.deadline,
    required this.isUrgent,
  });
  final String title;
  final String deadline;
  final bool isUrgent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUrgent
            ? AppColors.error.withValues(alpha: 0.06)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isUrgent
                ? Icons.warning_amber_rounded
                : Icons.radio_button_unchecked,
            size: 20,
            color: isUrgent ? AppColors.error : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
                Text(
                  deadline,
                  style: TextStyle(
                    fontSize: 12,
                    color: isUrgent ? AppColors.error : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── News Card ───────────────────────────────────────────────────────────────

class _NewsCard extends StatelessWidget {
  const _NewsCard({required this.title, required this.category, this.onTap});
  final String title;
  final String category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categoryColor = category == '教学' ? AppColors.error : AppColors.info;

    return ShipCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      color: cs.surfaceContainerLowest,
      child: SizedBox(
        width: 200,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: categoryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                category,
                style: TextStyle(
                  fontSize: 11,
                  color: categoryColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
