import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../app/app_theme_controller.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/config/feature_entry_catalog.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/update/update_checker.dart';
import '../../shared/widgets/network_error_toast.dart';
import '../../shared/widgets/update_dialog.dart';
import '../campus_card/campus_card_service.dart';
import '../dorm_electricity/dorm_electricity_service.dart';
import '../exam/exam_model.dart';
import '../exam/exam_service.dart';
import '../grades/grades_service.dart';
import '../schedule/schedule_cache_snapshot.dart';
import '../schedule/schedule_service.dart';
import 'home_controller.dart';
import 'home_presentation_resolver.dart';
import 'models/home_presentation.dart';
import 'models/home_snapshot.dart';
import 'widgets/home_background_layer.dart';
import 'widgets/home_event_banner.dart';
import 'widgets/home_primary_status_hero.dart';
import 'widgets/home_quick_actions.dart';
import 'widgets/home_status_strip.dart';
import 'widgets/home_today_section.dart';
import 'widgets/home_week_section.dart';

/// 首页：天气 App 式的单一纵向连续滚动流。
///
/// 信息顺序：Primary Status Hero →（可选）事件横幅 → Status Strip
/// （校园卡 + 电费）→ 今天 → 本周 → 常用入口 → 全部服务。
/// 数据获取与刷新行为与旧版一致，展示层由
/// [resolveHomePresentation]（纯函数）从 [HomeSnapshot] 派生。
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
  ScheduleCacheSnapshot? _scheduleSnapshot;
  bool _courseLoggedIn = false;
  bool _hasScheduleCache = false;
  bool _hasAvailableUpdate = false;
  bool _hasHydratedBootstrapState = false;

  /// 浮动底栏（约 74 高）+ 12 间距 + 24 呼吸空间；SafeArea(bottom: false)
  /// 之下还需叠加真实底部安全区。
  static const double _bottomNavClearance = 110;

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

  void _applyRestoredState() {
    final now = DateTime.now();
    final cachedBalance = CampusCardService.instance.cachedBalance;
    final dormService = DormElectricityService.instance;
    final scheduleSnapshot = ScheduleService.instance.preferredSnapshot(
      termContext: ScheduleService.instance.getCurrentTermContext(now),
    );

    _scheduleSnapshot = scheduleSnapshot;
    _hasScheduleCache = scheduleSnapshot?.hasData ?? false;
    _courseLoggedIn = ZhengfangAuth.instance.isLoggedIn || _hasScheduleCache;
    _campusCardBalance = CampusCardService.instance.formatBalance(
      cachedBalance,
    );
    _dormElectricity = dormService.formatElectricity(
      dormService.cachedElectricity,
    );
    _nextExam = ExamService.instance.nextExam;
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

      setState(() {
        _scheduleSnapshot = result.snapshot;
        _hasScheduleCache = result.snapshot?.hasData ?? false;
        _courseLoggedIn =
            ZhengfangAuth.instance.isLoggedIn || _hasScheduleCache;
      });
    } catch (_) {
      if (!mounted) return;
      // 网络失败时保留已有缓存快照，仅同步登录态。
      setState(() {
        _courseLoggedIn =
            ZhengfangAuth.instance.isLoggedIn || _hasScheduleCache;
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
    try {
      final networkBalance = await CampusCardService.instance.fetchBalance();
      if (!mounted) return;
      setState(() {
        _campusCardBalance = CampusCardService.instance.formatBalance(
          networkBalance,
        );
      });
    } catch (e) {
      if (!mounted) return;
      NetworkErrorToast.show(context, e);
    }
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
    try {
      final value = await service.fetchElectricity();
      if (!mounted) return;
      setState(() {
        _dormElectricity = service.formatElectricity(value);
      });
    } catch (e) {
      if (!mounted) return;
      NetworkErrorToast.show(context, e);
    }
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
    } catch (e) {
      if (!mounted) return;
      NetworkErrorToast.show(context, e);
    }
  }

  Future<void> _refreshGrades() async {
    if (!_isBootstrapReady) return;
    if (!ZhengfangAuth.instance.isLoggedIn) return;
    try {
      final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
      await GradesService.instance.fetchGrades(studentId);
    } catch (e) {
      if (!mounted) return;
      NetworkErrorToast.show(context, e);
    }
  }

  /// 统一的路由跳转：返回首页后按目的地触发对应的延迟刷新。
  Future<void> _pushFeatureRoute(BuildContext context, String routeName) async {
    if (routeName == 'service-hub') {
      context.goNamed('service-hub');
      return;
    }
    await context.pushNamed(routeName);
    if (!mounted) return;
    switch (routeName) {
      case 'schedule':
        await _refreshNextCourse();
      case 'grades':
        await _refreshGrades();
      case 'exam':
        await _refreshExam();
      case 'campus-card' || 'campus-card-payment':
        await _refreshCampusCardBalance();
      case 'dorm-electricity':
        await _refreshDormElectricity();
    }
  }

  void _handleUpdateTap() {
    final release = UpdateChecker.instance.availableRelease.value;
    if (release == null) return;
    showUpdateDialog(context, release);
  }

  HomePresentation _resolvePresentation() {
    final now = DateTime.now();
    final learningEntries = FeatureEntryCatalog.instance
        .entriesByPlacement(FeatureEntryPlacement.homeLearning)
        .map(
          (entry) => HomeQuickActionPresentation(
            label: entry.title,
            icon: entry.icon,
            routeName: entry.routeName,
            accentColor: entry.accentColor,
          ),
        )
        .toList(growable: false);
    final snapshot = HomeSnapshot(
      now: now,
      courseLoggedIn: _courseLoggedIn,
      hasScheduleCache: _hasScheduleCache,
      courses: _scheduleSnapshot?.courses ?? const [],
      changeRules: _scheduleSnapshot?.changeRules ?? const [],
      isBeforeSemesterStart: SemesterCalendar.instance.isBeforeSemesterStart(
        now,
      ),
      isAfterSemesterEnd: SemesterCalendar.instance.isAfterSemesterEnd(now),
      currentWeek: SemesterCalendar.instance.weekForDate(now),
      semesterStartDate: SemesterCalendar.instance.semesterStartDate.value,
      nextExam: _nextExam,
      campusCardBalance: _campusCardBalance,
      dormElectricity: _dormElectricity,
      learningEntries: learningEntries,
    );
    return resolveHomePresentation(snapshot);
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
              bottom: false,
              child: ValueListenableBuilder<HomeTextColorMode>(
                valueListenable: AppThemeController.instance.homeTextColorMode,
                builder: (context, _, _) => _buildScrollBody(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrollBody(BuildContext context) {
    final presentation = _resolvePresentation();
    final bottomClearance =
        MediaQuery.paddingOf(context).bottom + _bottomNavClearance;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.xl,
            AppSpacing.pageMargin,
            bottomClearance,
          ),
          sliver: SliverList.list(
            children: [
              HomePrimaryStatusHero(
                hero: presentation.hero,
                weekLabel: presentation.week.weekLabel,
                canShowUpdateAction: _canShowUpdateAction,
                onOpenSchedule: () async {
                  await _pushFeatureRoute(context, 'schedule');
                },
                onNotificationTap: () =>
                    context.pushNamed('notification-center'),
                onUpdateTap: _handleUpdateTap,
              ),
              if (presentation.alert != null) ...[
                const SizedBox(height: AppSpacing.md),
                HomeEventBanner(
                  alert: presentation.alert!,
                  onTap: () async {
                    await _pushFeatureRoute(
                      context,
                      presentation.alert!.routeName,
                    );
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              HomeStatusStrip(
                status: presentation.status,
                onCampusCardTap: () =>
                    _pushFeatureRoute(context, 'campus-card'),
                onPaymentTap: () =>
                    _pushFeatureRoute(context, 'campus-card-payment'),
                onElectricityTap: () =>
                    _pushFeatureRoute(context, 'dorm-electricity'),
              ),
              const SizedBox(height: AppSpacing.xl),
              HomeTodaySection(today: presentation.today),
              const SizedBox(height: AppSpacing.xl),
              HomeWeekSection(
                week: presentation.week,
                onOpenSchedule: () async {
                  await _pushFeatureRoute(context, 'schedule');
                },
              ),
              const SizedBox(height: AppSpacing.xl),
              HomeQuickActions(
                actions: presentation.quickActions,
                onActionTap: (action) async {
                  await _pushFeatureRoute(context, action.routeName);
                },
                onAllServicesTap: () => context.goNamed('service-hub'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
