import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/config/feature_entry_catalog.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/update/update_checker.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/update_dialog.dart';
import '../campus_card/campus_card_service.dart';
import '../dorm_electricity/dorm_electricity_service.dart';
import '../schedule/schedule_cache_snapshot.dart';
import '../schedule/schedule_model.dart';
import '../schedule/schedule_service.dart';
import 'home_controller.dart';
import 'widgets/home_card_container.dart';
import 'widgets/home_campus_card_balance_card.dart';
import 'widgets/home_dorm_electricity_card.dart';
import 'widgets/home_dorm_services_card.dart';
import 'widgets/home_header_card.dart';
import 'widgets/home_header_schedule_status.dart';
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
  CourseEntry? _nextCourse;
  String _nextCourseLabel = '';
  bool _courseLoggedIn = false;
  bool _hasScheduleCache = false;
  DateTime? _scheduleUpdatedAt;
  bool _hasAvailableUpdate = false;
  bool _hasHydratedBootstrapState = false;
  bool _initialLoginPromptChecked = false;
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
      unawaited(_maybeShowInitialUnifiedAuthPrompt());
    });
  }

  Future<void> _maybeShowInitialUnifiedAuthPrompt() async {
    if (_initialLoginPromptChecked || UnifiedAuthService.instance.isLoggedIn) {
      _initialLoginPromptChecked = true;
      return;
    }

    _initialLoginPromptChecked = true;
    if (!mounted) return;

    await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '首次使用请在校园网环境下登录统一认证，后续可直接进入一卡通与服务大厅',
    );
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
    DateTime? scheduleUpdatedAt,
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
        final effectiveCourses = ScheduleService.instance.buildEffectiveWeekCourses(
          courses: snapshot.courses,
          week: week,
          changeRules: snapshot.changeRules,
        );
        final dayCourses = effectiveCourses
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
      scheduleUpdatedAt: snapshot?.lastUpdatedAt,
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
    _hasScheduleCache = scheduleState.hasScheduleCache;
    _scheduleUpdatedAt = scheduleState.scheduleUpdatedAt;
    _courseLoggedIn = scheduleState.courseLoggedIn;
    _nextCourse = scheduleState.nextCourse;
    _nextCourseLabel = scheduleState.nextCourseLabel;
  }

  Future<void> _refreshDeferredContent() async {
    await _refreshCampusCardBalance();
    await Future.wait<void>([_refreshNextCourse(), _refreshDormElectricity()]);
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
        _scheduleUpdatedAt = scheduleState.scheduleUpdatedAt;
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

  Future<void> _openSchedule(BuildContext context) async {
    await context.pushNamed('schedule');
    if (!mounted) return;
    _refreshNextCourse();
  }

  String _formatScheduleUpdatedAt(DateTime? value) {
    if (value == null) return '未缓存';
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgImagePath = HomeController.instance.backgroundImagePath.value;
    return Scaffold(
      backgroundColor: isDark ? null : const Color(0xFFF5F5F5),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBackgroundLayer(context, isDark, bgImagePath),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: HomeHeaderScheduleStatus(
                      hasScheduleCache: _hasScheduleCache,
                      updatedAtText: _formatScheduleUpdatedAt(_scheduleUpdatedAt),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _buildHeader(context),
                const SizedBox(height: 16),
                Expanded(
                  child: _buildDashboardSection(context, isDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundLayer(
    BuildContext context,
    bool isDark,
    String? bgImagePath,
  ) {
    if (bgImagePath == null) return const SizedBox.expand();
    return ValueListenableBuilder<bool>(
      valueListenable: HomeController.instance.colorFilterEnabled,
      builder: (context, filterEnabled, _) {
        return ValueListenableBuilder<double>(
          valueListenable: HomeController.instance.backgroundOpacity,
          builder: (context, opacity, _) {
            return ValueListenableBuilder<Alignment>(
              valueListenable: HomeController.instance.backgroundAlignment,
              builder: (context, alignment, _) {
                if (!filterEnabled) {
                  return Opacity(
                    opacity: opacity,
                    child: _buildAlignedImage(context, bgImagePath, alignment),
                  );
                }
                return ValueListenableBuilder<double>(
                  valueListenable: HomeController.instance.filterStrength,
                  builder: (context, strength, _) {
                    return ValueListenableBuilder<HomeFilterMode>(
                      valueListenable: HomeController.instance.filterMode,
                      builder: (context, mode, _) {
                        return FutureBuilder<List<double>>(
                          future: HomeController.instance.buildFilterMatrix(strength),
                          builder: (context, snapshot) {
                            final matrix = snapshot.data;
                            if (matrix == null) {
                              return Opacity(
                                opacity: opacity,
                                child: _buildAlignedImage(context, bgImagePath, alignment),
                              );
                            }
                            return Opacity(
                              opacity: opacity,
                              child: ColorFiltered(
                                colorFilter: ColorFilter.matrix(matrix),
                                child: _buildAlignedImage(context, bgImagePath, alignment),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildAlignedImage(BuildContext context, String path, Alignment alignment) {
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      alignment: alignment,
      errorBuilder: (_, _, _) => const SizedBox.expand(),
    );
  }

  Widget _buildDashboardSection(BuildContext context, bool isDark) {
    final learningEntries = FeatureEntryCatalog.instance
        .entriesByPlacement(FeatureEntryPlacement.homeLearning);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
                for (final entry in learningEntries) ...[
                  const SizedBox(height: 10),
                  _buildLearningServiceEntryCard(context, entry),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Right column: dorm electricity → more services (content-driven)
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
              color: const Color(0xFFFF6B6B),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLearningServiceEntryCard(
    BuildContext context,
    FeatureEntryDefinition entry,
  ) {
    final cs = Theme.of(context).colorScheme;
    return HomeCardContainer(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: InkWell(
        onTap: () => context.pushNamed(entry.routeName),
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: entry.accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(entry.icon, color: entry.accentColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entry.title,
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 12, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }


}
