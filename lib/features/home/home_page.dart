import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../app/theme.dart';
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
import 'widgets/home_campus_card_balance_card.dart';
import 'widgets/home_dorm_electricity_card.dart';
import 'widgets/home_dorm_services_card.dart';
import 'widgets/home_grades_card.dart';
import 'widgets/home_header_card.dart';
import 'widgets/home_header_schedule_status.dart';
import 'widgets/home_more_services_card.dart';
import 'widgets/home_next_course_content.dart';
import 'widgets/home_notice_card.dart';

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
  final List<FeatureEntryDefinition> _learningServiceEntries =
      FeatureEntryCatalog.instance.entriesByPlacement(
        FeatureEntryPlacement.homeLearning,
      );

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
            child: SingleChildScrollView(
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
                  _buildDashboardSection(context, isDark),
                  const SizedBox(height: 32),
                ],
              ),
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
        if (!filterEnabled) {
          return Image.file(
            File(bgImagePath),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          );
        }
        return FutureBuilder<List<Color>>(
          future: HomeController.instance.getActiveFilterColors(),
          builder: (context, snapshot) {
            final colors = snapshot.data ??
                const [AppColors.primary, Colors.black, Colors.white];
            return Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(bgImagePath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colors[0].withValues(alpha: isDark ? 0.35 : 0.25),
                        colors[1].withValues(alpha: isDark ? 0.30 : 0.15),
                        colors[2].withValues(alpha: isDark ? 0.02 : 0.06),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDashboardSection(BuildContext context, bool isDark) {
    final dashboard = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
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
              HomeDormElectricityCard(
                dormElectricity: _dormElectricity,
                onTap: () async {
                  await context.pushNamed('dorm-electricity');
                  if (!mounted) return;
                  await _refreshDormElectricity();
                },
              ),
              const SizedBox(height: 10),
              _buildLearningServicesCard(context),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              HomeNoticeCard(
                onTap: () => context.pushNamed('notice-list'),
              ),
              const SizedBox(height: 10),
              HomeGradesCard(
                onTap: () => context.pushNamed('grades'),
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
    );

    return ValueListenableBuilder<bool>(
      valueListenable: HomeController.instance.frostedGlassEnabled,
      builder: (context, glassEnabled, child) {
        if (glassEnabled) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.20)
                        : Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: child,
        );
      },
      child: dashboard,
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
      onNoticeTap: () => context.pushNamed('notice-list'),
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

  Widget _buildLearningServicesCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainerLowest : Colors.white;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? cs.outline.withValues(alpha: 0.3)
              : cs.outline.withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
          if (_learningServiceEntries.isEmpty)
            Text(
              '暂无学习服务',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            )
          else
            Column(
              children: [
                for (
                  var index = 0;
                  index < _learningServiceEntries.length;
                  index++
                ) ...[
                  _buildLearningServiceTile(
                    context,
                    _learningServiceEntries[index],
                  ),
                  if (index != _learningServiceEntries.length - 1)
                    const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildLearningServiceTile(
    BuildContext context,
    FeatureEntryDefinition entry,
  ) {
    if (entry.id == 'changxing-jiada') {
      return _buildChangxingJiadaTile(context, entry);
    }
    return _buildLearningServiceItem(context, entry);
  }

  Widget _buildLearningServiceItem(
    BuildContext context,
    FeatureEntryDefinition entry,
  ) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => context.pushNamed(entry.routeName),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: entry.accentColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: entry.accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(entry.icon, color: entry.accentColor, size: 18),
            ),
            const SizedBox(width: 10),
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

  Widget _buildChangxingJiadaTile(
    BuildContext context,
    FeatureEntryDefinition entry,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tileColor = entry.accentColor;
    final tileBgColor = isDark
        ? tileColor.withValues(alpha: 0.08)
        : const Color(0xFFF3FAF5);
    return InkWell(
      onTap: () async {
        await context.pushNamed(entry.routeName);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: tileBgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tileColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(entry.icon, color: tileColor, size: 18),
            ),
            const SizedBox(width: 10),
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
