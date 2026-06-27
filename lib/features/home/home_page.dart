import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../app/app_theme_controller.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/config/feature_entry_catalog.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/update/update_checker.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/update_dialog.dart';
import '../campus_card/campus_card_service.dart';
import '../dorm_electricity/dorm_electricity_service.dart';
import '../exam/exam_model.dart';
import '../exam/exam_service.dart';
import '../grades/grades_model.dart';
import '../grades/grades_service.dart';
import '../schedule/schedule_cache_snapshot.dart';
import '../schedule/schedule_model.dart';
import '../schedule/schedule_service.dart';
import 'home_controller.dart';
import 'widgets/home_background_layer.dart';
import 'widgets/home_card_container.dart';
import 'widgets/home_campus_card_balance_card.dart';
import 'widgets/home_dorm_electricity_card.dart';
import 'widgets/home_dorm_services_card.dart';
import 'widgets/home_exam_countdown_card.dart';
import 'widgets/home_grade_chart_card.dart';
import 'widgets/home_header_card.dart';
import 'widgets/home_more_services_card.dart';
import 'widgets/home_next_course_content.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bootstrapController = AppBootstrapController.instance;

  String _campusCardBalance = '--';
  String _dormElectricity = '--';
  ExamEntry? _nextExam;
  List<GradeEntry> _grades = [];
  CourseEntry? _nextCourse;
  String _nextCourseLabel = '';
  bool _courseLoggedIn = false;
  bool _hasScheduleCache = false;
  bool _hasAvailableUpdate = false;
  bool _hasHydratedBootstrapState = false;
  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  int get _currentWeek => SemesterCalendar.instance.weekForDate(DateTime.now());
  bool get _isBootstrapReady =>
      _bootstrapController.phase.value.index >=
      AppBootstrapPhase.localStateReady.index;
  bool get _canShowUpdateAction =>
      UpdateChecker.instance.isUpdateEnabled && _hasAvailableUpdate;

  @override
  void initState() {
    super.initState();
    _hasAvailableUpdate = UpdateChecker.instance.availableRelease.value != null;
    SemesterCalendar.instance.semesterStartDate.addListener(
      _onSemesterStartChanged,
    );
    ZhengfangAuth.instance.addListener(_onAcademicAuthChanged);
    _bootstrapController.phase.addListener(_onBootstrapPhaseChanged);
    UpdateChecker.instance.availableRelease.addListener(
      _onAvailableReleaseChanged,
    );
    _onBootstrapPhaseChanged();
  }

  @override
  void dispose() {
    SemesterCalendar.instance.semesterStartDate.removeListener(
      _onSemesterStartChanged,
    );
    ZhengfangAuth.instance.removeListener(_onAcademicAuthChanged);
    _bootstrapController.phase.removeListener(_onBootstrapPhaseChanged);
    UpdateChecker.instance.availableRelease.removeListener(
      _onAvailableReleaseChanged,
    );
    super.dispose();
  }

  void _onAvailableReleaseChanged() {
    if (!mounted) return;
    setState(() {
      _hasAvailableUpdate =
          UpdateChecker.instance.availableRelease.value != null;
    });
  }

  void _onAcademicAuthChanged() {
    if (!mounted || !_isBootstrapReady) return;
    _refreshNextCourse();
  }

  void _onSemesterStartChanged() {
    if (!mounted) return;
    setState(() {});
    if (_isBootstrapReady) {
      _refreshNextCourse();
    }
  }

  void _onBootstrapPhaseChanged() {
    if (!_isBootstrapReady || _hasHydratedBootstrapState) return;
    _hasHydratedBootstrapState = true;
    _applyRestoredState();
    if (mounted) {
      setState(() {});
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshDeferredContent());
    });
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

  ({
    bool hasScheduleCache,
    bool courseLoggedIn,
    CourseEntry? nextCourse,
    String nextCourseLabel,
  })
  _buildNextCourseState({
    required ScheduleCacheSnapshot? snapshot,
    required DateTime now,
  }) {
    final hasScheduleCache = snapshot?.hasData ?? false;
    final today = DateTime(now.year, now.month, now.day);
    final nextLessonToday = _nextStartLesson(now);
    CourseEntry? nextCourse;
    var nextCourseLabel = '';

    if (snapshot != null && snapshot.hasData) {
      for (int offset = 0; offset < 14; offset++) {
        final date = today.add(Duration(days: offset));
        final week = _weekForDate(date);
        final effectiveCourses = ScheduleService.instance
            .buildEffectiveWeekCourses(
              courses: snapshot.courses,
              week: week,
              changeRules: snapshot.changeRules,
            );
        final dayCourses =
            effectiveCourses
                .where((c) => c.weekday == date.weekday)
                .where((c) => offset > 0 || c.startLesson >= nextLessonToday)
                .toList()
              ..sort((a, b) => a.startLesson.compareTo(b.startLesson));
        if (dayCourses.isNotEmpty) {
          nextCourse = dayCourses.first;
          nextCourseLabel = _labelForDate(date, today);
          break;
        }
      }
    }

    return (
      hasScheduleCache: hasScheduleCache,
      courseLoggedIn: ZhengfangAuth.instance.isLoggedIn || hasScheduleCache,
      nextCourse: nextCourse,
      nextCourseLabel: nextCourseLabel,
    );
  }

  void _applyRestoredState() {
    final now = DateTime.now();
    final cachedBalance = CampusCardService.instance.cachedBalance;
    final dormService = DormElectricityService.instance;
    final scheduleSnapshot = ScheduleService.instance.preferredSnapshot(
      termContext: ScheduleService.instance.getCurrentTermContext(now),
    );
    final scheduleState = _buildNextCourseState(
      snapshot: scheduleSnapshot,
      now: now,
    );

    _campusCardBalance = CampusCardService.instance.formatBalance(
      cachedBalance,
    );
    _dormElectricity = dormService.formatElectricity(
      dormService.cachedElectricity,
    );
    _nextExam = ExamService.instance.nextExam;
    _hasScheduleCache = scheduleState.hasScheduleCache;
    _courseLoggedIn = scheduleState.courseLoggedIn;
    _nextCourse = scheduleState.nextCourse;
    _nextCourseLabel = scheduleState.nextCourseLabel;

    final cachedGrades = GradesService.instance.cachedGrades;
    if (cachedGrades != null) _grades = cachedGrades;
  }

  Future<void> _refreshDeferredContent() async {
    await _refreshCampusCardBalance();
    await Future.wait<void>([
      _refreshNextCourse(),
      _refreshDormElectricity(),
      _refreshExam(),
      _refreshGrades(),
    ]);
  }

  Future<void> _refreshNextCourse() async {
    if (!_isBootstrapReady) return;
    try {
      final now = DateTime.now();
      final result = await ScheduleService.instance.loadScheduleSnapshot(
        termContext: ScheduleService.instance.getCurrentTermContext(now),
      );
      if (!mounted) return;

      final scheduleState = _buildNextCourseState(
        snapshot: result.snapshot,
        now: now,
      );

      setState(() {
        _hasScheduleCache = scheduleState.hasScheduleCache;
        _courseLoggedIn = scheduleState.courseLoggedIn;
        _nextCourse = scheduleState.nextCourse;
        _nextCourseLabel = scheduleState.nextCourseLabel;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _courseLoggedIn =
            ZhengfangAuth.instance.isLoggedIn || _hasScheduleCache;
        _nextCourse = null;
        _nextCourseLabel = '';
      });
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
    if (!_isBootstrapReady) return;
    final service = DormElectricityService.instance;
    if (!await service.hasRoomConfig()) {
      if (!mounted) return;
      setState(() {
        _dormElectricity = '--';
      });
      return;
    }
    final value = await service.fetchElectricity();
    if (!mounted) return;
    setState(() {
      _dormElectricity = service.formatElectricity(value);
    });
  }

  Future<void> _refreshExam() async {
    if (!_isBootstrapReady) return;
    final cached = ExamService.instance.nextExam;
    if (cached != null && mounted) {
      setState(() {
        _nextExam = cached;
      });
    }
    if (!ZhengfangAuth.instance.isLoggedIn) return;
    try {
      await ExamService.instance.fetchExams();
      if (!mounted) return;
      setState(() {
        _nextExam = ExamService.instance.nextExam;
      });
    } catch (_) {
      // Silent fail — exam card will show no data
    }
  }

  Future<void> _refreshGrades() async {
    if (!_isBootstrapReady) return;
    if (!ZhengfangAuth.instance.isLoggedIn) return;
    try {
      final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
      final grades = await GradesService.instance.fetchGrades(studentId);
      if (!mounted) return;
      setState(() => _grades = grades);
    } catch (_) {
      // Silent fail — grade chart card will show cached or empty
    }
  }

  Future<void> _openSchedule(BuildContext context) async {
    await context.pushNamed('schedule');
    if (!mounted) return;
    _refreshNextCourse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgImagePath = HomeController.instance.backgroundImagePath.value;
    final topInset = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          ),
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (bgImagePath != null) HomeBackgroundLayer(path: bgImagePath),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.94),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 28),
                  _buildHeader(context),
                  const SizedBox(height: 16),
                  Expanded(child: _buildDashboardSection(context, isDark)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardSection(BuildContext context, bool isDark) {
    final learningEntries = FeatureEntryCatalog.instance.entriesByPlacement(
      FeatureEntryPlacement.homeLearning,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column: campus card → dorm services → entries
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HomeCampusCardBalanceCard(
                  balanceText: _campusCardBalance,
                  onTap: () async {
                    await context.pushNamed('campus-card');
                    if (!mounted) return;
                    _refreshCampusCardBalance();
                  },
                  onPaymentTap: () async {
                    await context.pushNamed('campus-card-payment');
                    if (!mounted) return;
                    _refreshCampusCardBalance();
                  },
                ),
                const SizedBox(height: 10),
                HomeDormServicesCard(
                  onTap: () => context.pushNamed(
                    'news-detail',
                    extra: {
                      'title': '寝室服务',
                      'url':
                          'http://jdhq.wap.zjxu.edu.cn/Base/Center/center/account_id/6',
                    },
                  ),
                ),
                if (learningEntries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _buildEmptyLearningSlot(context),
                  )
                else
                  for (final entry in learningEntries) ...[
                    const SizedBox(height: 10),
                    _buildLearningServiceEntryCard(context, entry),
                  ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Right column: dorm electricity → exam → more services
          Expanded(
            child: Column(
              children: [
                HomeDormElectricityCard(
                  dormElectricity: _dormElectricity,
                  onTap: () async {
                    await context.pushNamed('dorm-electricity');
                    if (!mounted) return;
                    await _refreshDormElectricity();
                  },
                ),
                const SizedBox(height: 10),
                HomeExamCountdownCard(
                  exam: _nextExam,
                  onTap: () async {
                    await context.pushNamed('exam');
                    if (!mounted) return;
                    _refreshExam();
                  },
                ),
                const SizedBox(height: 10),
                HomeGradeChartCard(
                  grades: _grades,
                  onTap: () async {
                    await context.pushNamed('grades');
                    if (!mounted) return;
                    _refreshGrades();
                  },
                ),
                const SizedBox(height: 10),
                HomeMoreServicesCard(
                  onTap: () async {
                    context.goNamed('service-hub');
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final course = _nextCourse;
    final timeRangeText = course == null
        ? ''
        : ScheduleSlotTimes.timeRange(course.startLesson, course.endLesson);
    final campus = course?.campus.trim() ?? '';
    final classroom = course?.classroom.trim() ?? '';
    final locationText = (campus.isEmpty && classroom.isEmpty)
        ? '地点待定'
        : (campus.isEmpty
              ? classroom
              : (classroom.isEmpty ? campus : '$campus $classroom'));

    return HomeHeaderCard(
      currentWeek: _currentWeek,
      canShowUpdateAction: _canShowUpdateAction,
      onTap: () => _openSchedule(context),
      onNoticeTap: () => context.pushNamed('notification-center'),
      updateAction: _canShowUpdateAction ? _buildUpdateAction(context) : null,
      courseContent: HomeNextCourseContent(
        courseLoggedIn: _courseLoggedIn,
        nextCourse: _nextCourse,
        nextCourseLabel: _nextCourseLabel,
        timeRangeText: timeRangeText,
        locationText: locationText,
      ),
    );
  }

  Widget _buildUpdateAction(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(
            Icons.system_update_outlined,
            color: Colors.white,
            size: 22,
          ),
          onPressed: () {
            final release = UpdateChecker.instance.availableRelease.value;
            if (release == null) return;
            showUpdateDialog(context, release);
          },
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '发现新版本',
        ),
        Positioned(
          right: -1,
          top: -1,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: cs.error,
              shape: BoxShape.circle,
              border: Border.all(color: cs.onError, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyLearningSlot(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return HomeCardContainer(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        children: [
          AppIconBadge(
            icon: Icons.menu_book_outlined,
            accentColor: cs.primary,
            size: AppIconBadgeSize.small,
            backgroundAlpha: 0.1,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '更多学习入口在功能页',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Icon(Icons.arrow_forward_ios, size: 12, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }

  Widget _buildLearningServiceEntryCard(
    BuildContext context,
    FeatureEntryDefinition entry,
  ) {
    final cs = Theme.of(context).colorScheme;
    final entryColor = AppThemeController.instance.resolveIconColor(
      context,
      entry.accentColor,
    );
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    return ValueListenableBuilder<HomeTextColorMode>(
      valueListenable: AppThemeController.instance.homeTextColorMode,
      builder: (context, _, _) {
        return HomeCardContainer(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          onTap: () => context.pushNamed(entry.routeName),
          child: Row(
            children: [
              AppIconBadge(
                icon: entry.icon,
                accentColor: entryColor,
                size: AppIconBadgeSize.small,
                backgroundAlpha: 0.1,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.title,
                  style: TextStyle(
                    fontSize: 14,
                    color: primaryTextColor,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 12,
                color: secondaryTextColor,
              ),
            ],
          ),
        );
      },
    );
  }
}
