import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../campus_card/campus_card_service.dart';
import '../schedule/schedule_model.dart';
import '../schedule/schedule_service.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/semester/semester_calendar.dart';
import '../dorm_electricity/dorm_electricity_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _campusCardBalance = '--';
  String _dormElectricity = '--';
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
    await Future.wait([
      _refreshCampusCardBalance(),
      _refreshNextCourse(),
      _refreshDormElectricity(),
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

  int _nextStartLesson(DateTime now) {
    final times = ScheduleSlotTimes.slotTimes;
    for (int i = 0; i < times.length; i++) {
      final parts = times[i][0].split(':');
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);
      if (now.hour < hour || (now.hour == hour && now.minute < minute)) {
        return i + 1;
      }
    }
    return 14;
  }

  int _weekForDate(DateTime date) =>
      SemesterCalendar.instance.weekForDate(date);

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
      List<CourseChangeRule> courseChangeRules = const [];
      try {
        courseChangeRules = await ScheduleService.instance
            .fetchCourseChangeRules(studentId);
      } catch (_) {}
      if (!mounted) return;
      final today = DateTime(now.year, now.month, now.day);
      final nextLessonToday = _nextStartLesson(now);
      for (int offset = 0; offset < 14; offset++) {
        final date = today.add(Duration(days: offset));
        final week = _weekForDate(date);
        final effectiveCourses = ScheduleService.instance
            .buildEffectiveWeekCourses(
              courses: courses,
              week: week,
              changeRules: courseChangeRules,
            );
        final dayCourses =
            effectiveCourses
                .where((c) => c.weekday == date.weekday)
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

  Future<void> _refreshDormElectricity() async {
    final service = DormElectricityService.instance;
    if (!await service.hasRoomConfig()) return;
    final value = await service.fetchElectricity();
    if (!mounted) return;
    setState(() {
      _dormElectricity = service.formatElectricity(value);
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
                    // Left column
                    Expanded(
                      child: Column(
                        children: [
                          _buildCampusCardBalance(context),
                          const SizedBox(height: 10),
                          _buildDormElectricityCard(context),
                          const SizedBox(height: 10),
                          _buildLearningServicesCard(context),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Right column
                    Expanded(
                      child: Column(
                        children: [
                          _buildNoticeCard(context),
                          const SizedBox(height: 10),
                          _buildGradesCard(context),
                          const SizedBox(height: 10),
                          _buildDormServicesCard(context),
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              children: [
                Positioned(
                  right: -30,
                  top: -20,
                  child: Opacity(
                    opacity: 0.12,
                    child: SvgPicture.asset(
                      'assets/header_texture.svg',
                      width: 200,
                      height: 200,
                    ),
                  ),
                ),
                Padding(
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
                                  '第 $_currentWeek 周',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '下节课',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white.withValues(alpha: 0.7),
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
                      // Course content + action on the same bottom line
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: _buildCourseContent(context)),
                          const SizedBox(width: 8),
                          Text(
                            '查看课表 →',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
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

  Widget _buildCourseContent(BuildContext context) {
    if (!_courseLoggedIn) {
      return Text(
        '登录后查看课程',
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      );
    }

    if (_nextCourse == null) {
      return Text(
        '近期无课',
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      );
    }

    final course = _nextCourse!;
    final time = ScheduleSlotTimes.timeRange(
      course.startLesson,
      course.endLesson,
    );
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
        Transform.translate(
          offset: const Offset(-2, -4),
          child: Container(
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
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Icon(
              Icons.schedule,
              size: 14,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            Text(
              whenText,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '第 ${course.startLesson}-${course.endLesson} 节',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 14,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                location,
                style: TextStyle(
                  fontSize: 13,
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
      onTap: () async {
        await context.pushNamed('campus-card');
        if (!mounted) return;
        _refreshCampusCardBalance();
      },
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                const Spacer(),
                GestureDetector(
                  onTap: () => context.pushNamed('campus-card-payment'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.qr_code_2_rounded,
                          size: 15,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '付款码',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_campusCardBalance == '--') ...[
              Text(
                '余额未刷新，请先登录一卡通',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ] else ...[
              Text(
                '¥$_campusCardBalance',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '校园卡余额',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.bottomRight,
              child: Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDormElectricityCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return GestureDetector(
      onTap: () => context.pushNamed('dorm-electricity'),
      child: Container(
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
                color: AppColors.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.bolt_outlined,
                color: AppColors.success,
                size: 22,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '宿舍电费',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '剩余 $_dormElectricity 度',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.bottomRight,
              child: Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 寝室服务卡片
  Widget _buildDormServicesCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return GestureDetector(
      onTap: () => context.pushNamed(
        'news-detail',
        extra: {
          'title': '寝室服务',
          'url': 'http://jdhq.wap.zjxu.edu.cn/Base/Center/center/account_id/6',
        },
      ),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.home_outlined,
                color: AppColors.success,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '寝室服务',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '电费查询、故障报修',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildLearningServicesCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '学习服务',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 14),
          _buildServiceListTile(
            context,
            const _ServiceItem(
              icon: Icons.workspace_premium_outlined,
              label: '第二课堂',
              color: AppColors.gold,
            ),
          ),
          const SizedBox(height: 8),
          _buildServiceListTile(
            context,
            const _ServiceItem(
              icon: Icons.local_library_outlined,
              label: '图书馆',
              color: AppColors.info,
            ),
          ),
          const SizedBox(height: 8),
          _buildChangxingJiadaLearningTile(context),
        ],
      ),
    );
  }

  Widget _buildServiceListTile(BuildContext context, _ServiceItem item) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: item.color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, color: item.color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildChangxingJiadaLearningTile(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const tileBackground = Color(0xFFF3FAF5);
    return InkWell(
      onTap: () => context.pushNamed('changxing-jiada'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: tileBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tileBackground,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF2EA567),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.north_rounded,
                    color: Color(0xFF2EA567),
                    size: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '畅行嘉大',
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: cs.onSurfaceVariant),
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
        padding: const EdgeInsets.all(16),
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
            const SizedBox(height: 18),
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
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.bottomRight,
              child: Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
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
        width: double.infinity,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.apps_rounded, color: cs.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '更多服务',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
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

class _ServiceItem {
  const _ServiceItem({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;
}
