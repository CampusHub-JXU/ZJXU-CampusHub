import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/notice/notice_model.dart';
import '../../core/notice/notice_sync_store.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_theme_controller.dart';
import '../../core/theme/personalization_controller.dart';
import '../../core/theme/widgets/home_background_layer.dart';
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
import 'function_zone/function_zone_section.dart';
import 'home_presentation_resolver.dart';
import 'home_zone_controller.dart';
import 'models/home_presentation.dart';
import 'models/home_snapshot.dart';
import 'widgets/home_ambient_background.dart';
import 'widgets/home_asset_strip.dart';
import 'widgets/home_event_banner.dart';
import 'widgets/home_campus_notice_section.dart';
import 'widgets/home_primary_status_hero.dart';
import 'widgets/home_today_section.dart';

/// 首页：天气 App 式的单一纵向连续滚动页。
///
/// 第一屏只回答「今天什么状态」：环境行 → 无框 Hero（下一节课/当前
/// 状态）→（可选）事件横幅 → 资产行（校园卡 + 电费）→ 紧凑「今天」
/// 列表；弹性大留白把「校园公告」预览（最新一条完整 + 第二条露半行）
/// 压到开屏视口底缘，继续下滑看完公告进入「功能」锚点段落（Bento
/// 网格），底部 dock 通过 [HomeZoneController] 做 ScrollSpy，在
/// 首页/功能 之间自动切换高亮。
/// 数据获取与刷新行为与旧版一致，展示层由
/// [resolveHomePresentation]（纯函数）从 [HomeSnapshot] 派生。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bootstrapController = AppBootstrapController.instance;
  final _scrollController = ScrollController();

  /// 功能区锚点：dock「功能」点击的滚动定位与 ScrollSpy 判定都基于它。
  final _functionSectionKey = GlobalKey();

  /// 滚动视口：ScrollSpy 用它把功能区顶部的全局坐标换算成视口内坐标。
  final _scrollViewportKey = GlobalKey();

  /// 顶部内容（Hero/今天/资产行）整体锚点：首屏留白测量用它取高度。
  final _topContentKey = GlobalKey();

  /// 校园公告区块锚点：首屏留白测量以它定位截断基准。
  final _noticeSectionKey = GlobalKey();

  /// 公告首行锚点：截断位 = 标题行 + 首行高 × 1.5（第二条露半行）。
  final _noticeFirstRowKey = GlobalKey();

  String _campusCardBalance = '--';
  String _dormElectricity = '--';
  ExamEntry? _nextExam;
  ScheduleCacheSnapshot? _scheduleSnapshot;
  bool _courseLoggedIn = false;
  bool _hasScheduleCache = false;
  bool _hasAvailableUpdate = false;
  bool _hasHydratedBootstrapState = false;

  /// 教务处通知载荷：Hero 角标、校园公告区块共用（后台 isolate 写盘后
  /// 由 store.reload 经此 ValueNotifier 回流刷新）。
  NoticeInboxHead _noticeHead = NoticeInboxHead.empty;

  /// 浮动底栏（约 74 高）+ 12 间距 + 24 呼吸空间；SafeArea(bottom: false)
  /// 之下还需叠加真实底部安全区。
  static const double _bottomNavClearance = 110;

  /// 功能区段落顶部越过视口该比例线时，dock 高亮切到「功能」。
  static const double _zoneTriggerViewportFraction = 0.45;

  /// 公告关闭（或收件箱为空）时，顶部内容与功能区之间的固定呼吸间距。
  static const double _hiddenNoticeGap = 120;

  /// 弹性留白下限：首屏内容超高（大字号/长课程列表）导致算出负留白时，
  /// 公告与顶部内容之间仍保留最小呼吸空间。
  static const double _minFirstScreenGap = 24;

  /// 顶部内容与公告区之间的弹性留白：首帧后按「视口高 − 顶部内容高 −
  /// 截断位（标题行 + 1.5 行公告）」实测回填，让公告第二条被开屏视口
  /// 底缘截断在半行处。测量值不依赖滚动位置，滚动过程中不抖动。
  double _firstScreenGap = _hiddenNoticeGap;
  bool _gapMeasureScheduled = false;

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
    NoticeSyncStore.instance.inboxHead.addListener(_onNoticeHeadChanged);
    _noticeHead = NoticeSyncStore.instance.inboxHead.value;
    _scrollController.addListener(_onScrollChanged);
    HomeZoneController.instance
      ..scrollToTop = _scrollToTop
      ..scrollToFunction = _scrollToFunction;
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
    NoticeSyncStore.instance.inboxHead.removeListener(_onNoticeHeadChanged);
    _scrollController.removeListener(_onScrollChanged);
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToFunction = null;
    _scrollController.dispose();
    super.dispose();
  }

  void _onAvailableReleaseChanged() {
    if (!mounted) return;
    setState(() {
      _hasAvailableUpdate =
          UpdateChecker.instance.availableRelease.value != null;
    });
  }

  void _onNoticeHeadChanged() {
    if (!mounted) return;
    setState(() {
      _noticeHead = NoticeSyncStore.instance.inboxHead.value;
    });
  }

  /// 公告行点击：标已读（红点经 inboxHead 回流消失）并打开详情 WebView。
  /// jwc 详情属资源型目标：预热逐跳建立业务 Cookie（warmUpAsResource）。
  void _openCampusNotice(Notice notice) {
    unawaited(NoticeSyncStore.instance.markRead([notice.id]));
    final uri = Uri.tryParse(notice.url);
    final isJwc = uri?.host.toLowerCase() == 'jwc.zjxu.edu.cn';
    context.pushNamed(
      'external-webview',
      extra: {
        'title': notice.title,
        'url': notice.url,
        'emulateDingTalkEnvironment': false,
        if (isJwc) ...{
          'requireUnifiedAuthProtection': true,
          'serviceUrl': notice.url,
          'loginDescription': '通知公告可直连访问，但需先完成统一认证',
          'warmUpAsResource': true,
        },
        'showWebViewBottomBackButton': true,
      },
    );
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

  // ── dock ScrollSpy 与锚点滚动 ─────────────────────────────────────────────

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToFunction() async {
    final sectionContext = _functionSectionKey.currentContext;
    if (sectionContext == null) return;
    await Scrollable.ensureVisible(
      sectionContext,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
    );
  }

  /// ScrollSpy：功能区锚点顶部越过视口 45% 线且页面已发生滚动时，
  /// 才视为进入功能区。
  ///
  /// 锚点顶部坐标相对滚动视口（而非屏幕）计算，保证状态栏/SafeArea
  /// 差异不影响判定；`offset > 0` 护栏确保空状态（首屏内容很矮、锚点
  /// 天然高于该线）时刚打开页面 dock 仍高亮「首页」。分区实际变化时
  /// 才通知（[HomeZoneController] 内部去重），滚动过程中不产生多余重建。
  void _onScrollChanged() {
    final viewportBox =
        _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    final sectionBox =
        _functionSectionKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null ||
        sectionBox == null ||
        !viewportBox.attached ||
        !sectionBox.attached ||
        !_scrollController.hasClients) {
      return;
    }
    final sectionTop = sectionBox
        .localToGlobal(Offset.zero, ancestor: viewportBox)
        .dy;
    final trigger = viewportBox.size.height * _zoneTriggerViewportFraction;
    final inFunctionZone =
        sectionTop <= trigger && _scrollController.offset > 0;
    HomeZoneController.instance.updateZone(inFunctionZone ? 1 : 0);
  }

  HomePresentation _resolvePresentation() {
    final now = DateTime.now();
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
    );
    return resolveHomePresentation(
      snapshot,
      fullDayCourses:
          PersonalizationController.instance.fullDayCoursesEnabled.value,
    );
  }

  /// 环境行日期，如「8月29日 周六」。
  String _formatEnvDate(DateTime now) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${now.month}月${now.day}日 ${weekdays[now.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgImagePath =
        PersonalizationController.instance.backgroundImagePath.value;
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
            if (bgImagePath != null) ...[
              HomeBackgroundLayer(path: bgImagePath),
              // 自定义背景图时在状态栏区域垫一层表面色，保证图标可读；
              // 默认环境背景自带浅色氛围，不需要这一层。
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topInset,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface
                        .withValues(alpha: 0.94),
                  ),
                ),
              ),
            ] else
              HomeAmbientBackground(),
            SafeArea(
              bottom: false,
              child: ValueListenableBuilder<HomeTextColorMode>(
                valueListenable: AppThemeController.instance.homeTextColorMode,
                builder: (context, _, _) =>
                    // 「今日全部课程」开关变化时重建滚动内容，Today 段落
                    // 在剩余/全天形态间即时切换。
                    ValueListenableBuilder<bool>(
                      valueListenable: PersonalizationController
                          .instance
                          .fullDayCoursesEnabled,
                      builder: (context, _, _) => _buildScrollBody(context),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrollBody(BuildContext context) {
    final presentation = _resolvePresentation();
    final now = DateTime.now();
    final bottomClearance =
        MediaQuery.paddingOf(context).bottom + _bottomNavClearance;
    _scheduleFirstScreenGapMeasure();

    return SingleChildScrollView(
      key: _scrollViewportKey,
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: _topContentKey,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.xl,
              AppSpacing.pageMargin,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomePrimaryStatusHero(
                  hero: presentation.hero,
                  envDateText: _formatEnvDate(now),
                  envStatusText: presentation.weekLabel,
                  canShowUpdateAction: _canShowUpdateAction,
                  unreadNoticeCount: _noticeHead.unreadCount,
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
                // 今天列表（含次日预览与「Hero 大字首课 + 单行折叠摘要」
                // 形态）优先于资产行：课程安排是第一屏价值最高的状态信息,
                // 余额/电费次之。
                const SizedBox(height: AppSpacing.md),
                HomeTodaySection(
                  today: presentation.today,
                  onOpenSchedule: () async {
                    await _pushFeatureRoute(context, 'schedule');
                  },
                ),
                const SizedBox(height: AppSpacing.xl),
                HomeAssetStrip(
                  status: presentation.status,
                  onCampusCardTap: () =>
                      _pushFeatureRoute(context, 'campus-card'),
                  onElectricityTap: () =>
                      _pushFeatureRoute(context, 'dorm-electricity'),
                ),
              ],
            ),
          ),
          // 公告 + 功能区尾段：公告开关变化时整段重建（弹性留白按公告
          // 可见与否走不同分支）。公告在功能之前——开屏视口底缘瞥见
          // 最新一条，其余内容（含功能）下滑再看，公告不再整块抢视线。
          ValueListenableBuilder<bool>(
            valueListenable:
                PersonalizationController.instance.homeCampusNoticeEnabled,
            builder: (context, noticeEnabled, _) {
              final noticeVisible = noticeEnabled && !_noticeHead.isEmpty;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 开屏大留白：把「校园公告」的第二条截断在第一屏视口
                  // 底缘的半行处（高度首帧后实测回填，见
                  // [_scheduleFirstScreenGapMeasure]）；未开学等首屏内容
                  // 稀疏时，这里就是天气 App 式的大留白。
                  SizedBox(height: _firstScreenGap),
                  if (noticeVisible)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: AppSpacing.sectionBreak,
                      ),
                      child: HomeCampusNoticeSection(
                        key: _noticeSectionKey,
                        firstRowKey: _noticeFirstRowKey,
                        head: _noticeHead,
                        onTapNotice: _openCampusNotice,
                        onTapAll: () =>
                            context.pushNamed('notification-center'),
                      ),
                    ),
                  // 功能区锚点：key 挂在容器上，ensureVisible 滚动到位后
                  // 标题不贴视口顶；页面真正的底部净空由它承担。
                  Container(
                    key: _functionSectionKey,
                    padding: EdgeInsets.only(bottom: bottomClearance),
                    child: FunctionZoneSection(
                      campusCardBalance: _campusCardBalance,
                      dormElectricity: _dormElectricity,
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.pageMargin,
                        0,
                        AppSpacing.pageMargin,
                        0,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 首屏留白补偿：让开屏视口底缘恰好把公告第二条截断在半行。
  ///
  /// 顶部内容（Hero/今天/资产行）高度随机型、字号与数据形态浮动，
  /// 固定间距无法保证截断位稳定；首帧后实测「顶部内容高 + 公告块内
  /// 露出部分（标题行 + 1.5 行公告）」，反推留白 = 视口高 − 两者之和
  /// （夹在安全区间内）。公告块本身完整渲染、块内不截断，所以下滑后
  /// 第二条与「查看全部」完整可见；只有 1 条公告时整块落在视口内。
  /// 公告关闭或收件箱为空时退回固定呼吸间距。测量值与滚动位置无关，
  /// 收敛后不再触发重建。
  void _scheduleFirstScreenGapMeasure() {
    if (_gapMeasureScheduled) return;
    _gapMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gapMeasureScheduled = false;
      if (!mounted) return;
      final viewportBox =
          _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
      final topBox =
          _topContentKey.currentContext?.findRenderObject() as RenderBox?;
      final noticeBox =
          _noticeSectionKey.currentContext?.findRenderObject() as RenderBox?;
      final firstRowBox =
          _noticeFirstRowKey.currentContext?.findRenderObject() as RenderBox?;
      if (viewportBox == null ||
          !viewportBox.attached ||
          topBox == null ||
          !topBox.attached) {
        return;
      }
      double gap;
      if (noticeBox != null &&
          noticeBox.attached &&
          firstRowBox != null &&
          firstRowBox.attached &&
          _noticeHead.latest.length >= 2) {
        // 公告块内露出部分：区块顶 → 首行顶（标题行 + 间距）+ 1.5 行。
        // 各行等高，首行高即行高；top 差值与滚动位置无关。
        final headerExtent =
            firstRowBox.localToGlobal(Offset.zero).dy -
            noticeBox.localToGlobal(Offset.zero).dy;
        final cutExtent = headerExtent + firstRowBox.size.height * 1.5;
        gap = (viewportBox.size.height - topBox.size.height - cutExtent).clamp(
          _minFirstScreenGap,
          viewportBox.size.height,
        );
      } else if (noticeBox != null && noticeBox.attached) {
        // 单条公告：整块（含查看全部）完整落在视口内。
        gap =
            (viewportBox.size.height -
                    topBox.size.height -
                    noticeBox.size.height)
                .clamp(_minFirstScreenGap, viewportBox.size.height);
      } else {
        gap = _hiddenNoticeGap;
      }
      if ((gap - _firstScreenGap).abs() > 0.5) {
        setState(() => _firstScreenGap = gap);
      }
    });
  }
}
