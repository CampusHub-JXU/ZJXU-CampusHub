import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../campus_card/campus_card_service.dart';
import '../dorm_electricity/dorm_electricity_service.dart';
import '../notice/notice_service.dart';
import '../notice/notice_model.dart';
import '../schedule/schedule_model.dart';
import '../schedule/schedule_service.dart';
import '../../core/auth/zhengfang_auth.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _campusCardBalance = '--';
  String _dormElectricity = '--';
  List<Notice> _notices = [];
  int _currentNoticeIndex = 0;
  CourseEntry? _nextCourse;
  String _nextCourseLabel = ''; // '今天' or '明天'
  bool _courseLoggedIn = false;

  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const _courseColors = [
    Color(0xFF64B5F6),
    Color(0xFF81C784),
    Color(0xFFE57373),
    Color(0xFFFFB74D),
    Color(0xFFBA68C8),
    Color(0xFF4DB6AC),
    Color(0xFFFF8A65),
    Color(0xFF7986CB),
  ];

  Color _colorForCourse(String name) =>
      _courseColors[name.hashCode.abs() % _courseColors.length];

  int get _currentWeek {
    final now = DateTime.now();
    final semStart = DateTime(now.year, 2, 24);
    final diff = now.difference(semStart).inDays;
    return ((diff ~/ 7) + 1).clamp(1, 20);
  }

  @override
  void initState() {
    super.initState();
    _refreshCampusCardBalance();
    _refreshDormElectricity();
    _refreshNotices();
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

  void _openDormElectricitySettings(BuildContext context) {
    context.pushNamed('dorm-electricity-settings');
  }

  static const _slotStartTimes = [
    '08:00', '08:45', '09:45', '10:30', '11:15', // 1-5
    '13:30', '14:15', '15:15', '16:00', '16:45', // 6-10
    '18:30', '19:15', '20:00', // 11-13
  ];

  static const _slotEndTimes = [
    '08:40', '09:25', '10:25', '11:10', '11:55', // 1-5
    '14:10', '14:55', '15:55', '16:40', '17:25', // 6-10
    '19:10', '19:55', '20:40', // 11-13
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
      if (rule.week != week || rule.weekday != course.weekday) {
        continue;
      }
      final isOverlap =
          course.startLesson <= rule.endLesson &&
          course.endLesson >= rule.startLesson;
      if (!isOverlap) {
        continue;
      }

      final ruleCourseName = rule.courseName;
      if (ruleCourseName == null || ruleCourseName.isEmpty) {
        return true;
      }
      if (_matchesCourseName(course.courseName, ruleCourseName)) {
        return true;
      }
    }
    return false;
  }

  static String _slotTimeRange(int start, int end) {
    final s = (start >= 1 && start <= 13) ? _slotStartTimes[start - 1] : '??';
    final e = (end >= 1 && end <= 13) ? _slotEndTimes[end - 1] : '??';
    return '$s-$e';
  }

  int _weekForDate(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final semStart = DateTime(day.year, 2, 24);
    final diff = day.difference(semStart).inDays;
    return ((diff ~/ 7) + 1).clamp(1, 20);
  }

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

  Future<void> _refreshCampusCardBalance() async {
    final cached = CampusCardService.instance.cachedBalance;
    if (cached != null && mounted) {
      setState(() {
        _campusCardBalance = CampusCardService.instance.formatBalance(cached);
      });

      return;
    }

    final networkBalance = await CampusCardService.instance.fetchBalance();
    final balance = networkBalance;

    if (!mounted) return;

    setState(() {
      _campusCardBalance = CampusCardService.instance.formatBalance(balance);
    });
  }

  Future<void> _openCampusCardStatus(BuildContext context) async {
    await context.pushNamed('campus-card');
    if (!mounted) return;
    _refreshCampusCardBalance();
  }

  void _openCampusCardPayment(BuildContext context) {
    context.pushNamed('campus-card-payment');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildHeader(context),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildNoticeCard(context),
                  _buildFunctionGrid(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(
                    Icons.settings_outlined,
                    color: Colors.white,
                  ),
                  onPressed: () => context.pushNamed('settings'),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '第 $_currentWeek 周',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '方正为人、勤慎治学。',
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 8),
              const Text(
                '——嘉兴大学校训',
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoticeCard(BuildContext context) {
    // 如果没有通知数据，显示默认占位
    if (_notices.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '教学',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '加载中...',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }

    final notice = _notices[_currentNoticeIndex % _notices.length];
    final categoryColor = notice.category == '教学' ? Colors.red : Colors.blue;

    return GestureDetector(
      onTap: () {
        context.pushNamed('notice-list');
      },
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          setState(() {
            _currentNoticeIndex = (_currentNoticeIndex + 1) % _notices.length;
          });
        }
      },
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: categoryColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                notice.category,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                notice.title,
                style: const TextStyle(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildFunctionGrid(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _FunctionCard(
                  icon: Icons.calendar_today,
                  iconColor: Colors.blue,
                  title: '课表查询',
                  subtitle: '查看本周课程安排',
                  onTap: () => _openSchedule(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FunctionCard(
                  icon: Icons.grade,
                  iconColor: Colors.orange,
                  title: '成绩查询',
                  subtitle: '查看成绩与绩点',
                  onTap: () => _openGrades(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CampusCardWidget(
                  balanceText: _campusCardBalance,
                  onTap: () => _openCampusCardStatus(context),
                  onPaymentTap: () => _openCampusCardPayment(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FunctionCard(
                  icon: Icons.school,
                  iconColor: Colors.grey,
                  title: '服务大厅',
                  subtitle: '学生事务办理',
                  onTap: () => context.pushNamed('service-hall'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DormElectricityWidget(
                  electricityText: _dormElectricity,
                  onTap: () => _openDormElectricity(context),
                  onSettingsTap: () => _openDormElectricitySettings(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _UpcomingCourseWidget(
                  course: _nextCourse,
                  label: _nextCourseLabel,
                  loggedIn: _courseLoggedIn,
                  courseColor: _nextCourse == null
                      ? null
                      : _colorForCourse(_nextCourse!.courseName),
                  slotTimeRange: _slotTimeRange,
                  onTap: () => _openSchedule(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CampusCardWidget extends StatelessWidget {
  final String balanceText;
  final VoidCallback onTap;
  final VoidCallback onPaymentTap;

  const _CampusCardWidget({
    required this.balanceText,
    required this.onTap,
    required this.onPaymentTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 140,
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.payment, size: 32, color: Colors.pink),
                  const Spacer(),
                  const Text(
                    '校园卡',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        balanceText,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '元',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: InkWell(
                  onTap: onPaymentTap,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.qr_code_2,
                          size: 14,
                          color: Colors.blue[700],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '消费码',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.blue[700],
                          ),
                        ),
                      ],
                    ),
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

class _FunctionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _FunctionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 140,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: iconColor),
              const Spacer(),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DormElectricityWidget extends StatelessWidget {
  final String electricityText;
  final VoidCallback onTap;
  final VoidCallback onSettingsTap;

  const _DormElectricityWidget({
    required this.electricityText,
    required this.onTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 140,
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.bolt, size: 32, color: Colors.amber),
                  const Spacer(),
                  const Text(
                    '寝室电费',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        electricityText,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        electricityText == '--' ? '未配置' : '度',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: InkWell(
                  onTap: onSettingsTap,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.home_outlined,
                          size: 14,
                          color: Colors.blue[700],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '选房',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.blue[700],
                          ),
                        ),
                      ],
                    ),
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

class _UpcomingCourseWidget extends StatelessWidget {
  final CourseEntry? course;
  final String label; // '今天' or '明天'
  final bool loggedIn;
  final Color? courseColor;
  final String Function(int, int) slotTimeRange;
  final VoidCallback onTap;

  const _UpcomingCourseWidget({
    required this.course,
    required this.label,
    required this.loggedIn,
    required this.courseColor,
    required this.slotTimeRange,
    required this.onTap,
  });

  String _locationText(CourseEntry course) {
    final campus = course.campus.trim();
    final classroom = course.classroom.trim();
    if (campus.isEmpty && classroom.isEmpty) {
      return '地点待定';
    }
    if (campus.isEmpty) {
      return classroom;
    }
    if (classroom.isEmpty) {
      return campus;
    }
    return '$campus $classroom';
  }

  @override
  Widget build(BuildContext context) {
    final textMutedColor = Colors.grey[600];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 140,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '下节课',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              if (!loggedIn)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '登录后查看',
                      style: TextStyle(fontSize: 12, color: textMutedColor),
                    ),
                  ),
                )
              else if (course == null)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '近期无课',
                      style: TextStyle(fontSize: 12, color: textMutedColor),
                    ),
                  ),
                )
              else ...[
                Expanded(
                  child: _NextCourseHighlight(
                    course: course!,
                    label: label,
                    color: courseColor ?? Theme.of(context).colorScheme.primary,
                    slotTimeRange: slotTimeRange,
                    locationText: _locationText(course!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NextCourseHighlight extends StatelessWidget {
  const _NextCourseHighlight({
    required this.course,
    required this.label,
    required this.color,
    required this.slotTimeRange,
    required this.locationText,
  });

  final CourseEntry course;
  final String label;
  final Color color;
  final String Function(int, int) slotTimeRange;
  final String locationText;

  @override
  Widget build(BuildContext context) {
    final time = slotTimeRange(course.startLesson, course.endLesson);
    final whenAndTime = label.isEmpty ? time : '$label $time';
    final typeSuffix = course.typeSymbol.trim().isEmpty
        ? ''
        : ' ${course.typeSymbol}';

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 4,
            margin: const EdgeInsets.fromLTRB(6, 6, 0, 6),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${course.courseName}$typeSuffix',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    whenAndTime,
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.9),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    locationText,
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.9),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
