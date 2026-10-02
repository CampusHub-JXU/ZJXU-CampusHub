import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/notice/notice_detail.dart';
import '../../core/notice/notice_model.dart';
import '../../core/notice/notice_sync_store.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_theme_controller.dart';
import '../../core/theme/page_transition_activity.dart';
import '../../core/theme/personalization_controller.dart';
import '../../core/theme/widgets/app_wallpaper_backdrop.dart';
import '../../core/update/update_checker.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import '../../shared/widgets/update_dialog.dart';
import '../../core/academic/exam_model.dart';
import '../../core/academic/schedule_cache_snapshot.dart';
import 'campus_snapshot_coordinator.dart';
import 'function_zone/function_zone_section.dart';
import 'home_presentation_resolver.dart';
import 'home_zone_controller.dart';
import 'models/home_presentation.dart';
import 'models/home_snapshot.dart';
import 'widgets/home_asset_strip.dart';
import 'widgets/home_campus_notice_section.dart';
import 'widgets/home_event_banner.dart';
import 'widgets/home_primary_status_hero.dart';
import 'widgets/home_today_section.dart';
import 'widget/campus_widget_sync.dart';

/// 首页：天气 App 式的单一纵向连续滚动页。
///
/// 第一屏只回答「今天什么状态」：环境行 → 无框 Hero（下一节课/当前
/// 状态）→（可选）事件横幅 → 紧凑「今天」列表 → 资产行（校园卡 +
/// 电费）→「校园公告」简化预览（紧随资产行，不再压到首屏底部）→
/// 「功能」锚点段落（全部入口的轻量小按钮工具条，含课表——原快捷
/// 入口行已并入）。底部 dock 通过 [HomeZoneController] 做 ScrollSpy，
/// 在 首页/功能 之间自动切换高亮。数据获取与刷新行为与旧版一致，
/// 展示层由 [resolveHomePresentation]（纯函数）从 [HomeSnapshot] 派生。
/// 教务登录弹层的呈现函数：返回 true 表示弹层内登录成功。
typedef HomeLoginPromptPresenter = Future<bool> Function(BuildContext context);

class HomePage extends StatefulWidget {
  const HomePage({super.key, @visibleForTesting this.loginPromptPresenter});

  /// 测试注入点：替换教务登录弹层（默认走 shared 的
  /// `showAcademicSystemLoginModal`）。生产路由不传该参数。
  @visibleForTesting
  final HomeLoginPromptPresenter? loginPromptPresenter;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bootstrapController = AppBootstrapController.instance;
  final _snapshotCoordinator = CampusSnapshotCoordinator.instance;
  final _scrollController = ScrollController();

  /// 功能区锚点：dock「功能」点击的滚动定位与 ScrollSpy 判定都基于它。
  final _functionSectionKey = GlobalKey();

  /// 滚动视口：ScrollSpy 用它把功能区顶部的全局坐标换算成视口内坐标。
  final _scrollViewportKey = GlobalKey();

  String _campusCardBalance = '--';
  String _dormElectricity = '--';
  ExamEntry? _nextExam;
  ScheduleCacheSnapshot? _scheduleSnapshot;
  bool _courseLoggedIn = false;
  bool _hasScheduleCache = false;
  bool _hasAvailableUpdate = false;
  bool _hasHydratedBootstrapState = false;

  /// 转场期间收到数据变更广播、等转场结束后补一次采纳。
  bool _campusDataPendingAfterTransition = false;

  /// 认证上下文世代：统一认证 / 教务任一身份通知即推进。私有刷新在 await
  /// 前捕获它，返回后不一致说明期间发生过登录 / 登出 / 换号 / 同号重登
  /// （后者 `sessionRevision` 可能不增），结果一律不得写回展示。
  int _authGeneration = 0;

  /// 教务处通知载荷：Hero 角标、校园公告区块共用（后台 isolate 写盘后
  /// 由 store.reload 经此 ValueNotifier 回流刷新）。
  NoticeInboxHead _noticeHead = NoticeInboxHead.empty;

  /// 浮动底栏（约 74 高）+ 12 间距 + 24 呼吸空间；SafeArea(bottom: false)
  /// 之下还需叠加真实底部安全区。
  static const double _bottomNavClearance = 110;

  /// 首页左右留白：无框版式靠留白分区，比通用页边距更宽。
  static const double _pageGutter = 24;

  /// 首页主要段落之间的留白。
  static const double _sectionGap = 36;

  /// 功能区段落顶部越过视口该比例线时，dock 高亮切到「功能」。
  static const double _zoneTriggerViewportFraction = 0.45;

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
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
    _bootstrapController.phase.addListener(_onBootstrapPhaseChanged);
    UpdateChecker.instance.availableRelease.addListener(
      _onAvailableReleaseChanged,
    );
    NoticeSyncStore.instance.inboxHead.addListener(_onNoticeHeadChanged);
    _noticeHead = NoticeSyncStore.instance.inboxHead.value;
    CampusDataChangeBus.instance.revision.addListener(_onCampusDataChanged);
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
    UnifiedAuthService.instance.removeListener(_onUnifiedAuthChanged);
    _bootstrapController.phase.removeListener(_onBootstrapPhaseChanged);
    UpdateChecker.instance.availableRelease.removeListener(
      _onAvailableReleaseChanged,
    );
    NoticeSyncStore.instance.inboxHead.removeListener(_onNoticeHeadChanged);
    CampusDataChangeBus.instance.revision.removeListener(_onCampusDataChanged);
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
    if (isJwcNoticeDetailUrl(notice.url)) {
      context.pushNamed(
        'notice-detail',
        extra: {'title': notice.title, 'url': notice.url},
      );
      return;
    }
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

  /// 统一认证身份变化（登录 / 登出 / 换号 / 同号重登）：推进认证世代作废
  /// 在途私有刷新结果，并同步按当前 owner 重新采纳内存投影——校园卡余额与
  /// 电费都带统一认证 owner 归属校验，登出 / 换号后立即回落占位符，
  /// 不保留上一身份的内容。
  void _onUnifiedAuthChanged() {
    if (!mounted) return;
    _authGeneration++;
    _reAdoptPrivateProjection();
  }

  /// 教务身份变化：与统一认证同一路径重新采纳投影（考试 / 课表带学号
  /// 归属校验），并保持既有「刷新下一节课」行为。
  void _onAcademicAuthChanged() {
    if (!mounted) return;
    _authGeneration++;
    _reAdoptPrivateProjection();
    if (_isBootstrapReady) {
      _refreshNextCourse();
    }
  }

  /// 认证身份变化后同步重新采纳内存投影（不发网络）。
  ///
  /// bootstrap 本地状态恢复前不采纳，避免用半截缓存覆盖既有 hydrate 时序；
  /// 采纳来源 [CampusSnapshotCoordinator.restore] 本身按当前 owner 归属
  /// 过滤（校园卡余额 / 电费 / 考试 / 课表都带 owner 校验），登出 / 换号只会
  /// 得到空值，不保留上一身份的任何投影。
  void _reAdoptPrivateProjection() {
    if (!mounted || !_hasHydratedBootstrapState) return;
    setState(() {
      _adoptRestoreData(_snapshotCoordinator.restore(DateTime.now()));
    });
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
    _adoptRestoreData(_snapshotCoordinator.restore(DateTime.now()));
    CampusWidgetSync.instance.requestSync();
  }

  /// 把协调器的内存缓存投影采纳进首页状态（不发网络）。
  void _adoptRestoreData(HomeRestoreData data) {
    _scheduleSnapshot = data.scheduleSnapshot;
    _hasScheduleCache = data.hasScheduleCache;
    _courseLoggedIn = data.courseLoggedIn;
    _campusCardBalance = data.campusCardBalance;
    _dormElectricity = data.dormElectricity;
    _nextExam = data.nextExam;
  }

  /// 任一校园数据缓存变化（课表/成绩/考试/校园卡/电费写入点 ping 总线）。
  ///
  /// 只从内存缓存重新采纳投影并重建，**不**再发 fetch/网络：否则
  /// notify → fetch → notify 会成环。bootstrap 本地状态恢复前直接跳过，
  /// 交给既有 hydrate 时序，避免用半截缓存覆盖。
  ///
  /// 页面转场进行中（课表等页 pop 回首页的 220ms 内，课表写缓存正好 ping
  /// 总线）不立刻 setState：整页重建 + 重绘会和转场抢帧。记一笔，转场结束后
  /// 再采纳一次——采纳的是内存缓存最新值，合并多次 ping 不丢数据。
  void _onCampusDataChanged() {
    if (!mounted || !_hasHydratedBootstrapState) return;
    final activity = PageTransitionActivity.instance;
    if (activity.isBusy) {
      if (_campusDataPendingAfterTransition) return;
      _campusDataPendingAfterTransition = true;
      unawaited(
        activity.whenIdle().then((_) {
          _campusDataPendingAfterTransition = false;
          _onCampusDataChanged();
        }),
      );
      return;
    }
    setState(() {
      _adoptRestoreData(_snapshotCoordinator.restore(DateTime.now()));
    });
  }

  Future<void> _refreshDeferredContent() async {
    await _refreshCampusCardBalance();
    await Future.wait<void>([
      _refreshNextCourse(),
      _refreshDormElectricity(),
      _refreshExam(),
      _refreshGrades(),
    ]);
    CampusWidgetSync.instance.requestSync();
  }

  Future<void> _refreshNextCourse() async {
    if (!_isBootstrapReady) return;
    final authGuard = _authGeneration;
    try {
      final result = await _snapshotCoordinator.refreshSchedule();
      if (!mounted || authGuard != _authGeneration) return;

      setState(() {
        _scheduleSnapshot = result.snapshot;
        _hasScheduleCache = result.hasScheduleCache;
        _courseLoggedIn = result.courseLoggedIn;
      });
    } catch (_) {
      if (!mounted || authGuard != _authGeneration) return;
      // 网络失败时保留已有缓存快照，仅同步登录态。
      setState(() {
        _courseLoggedIn = _snapshotCoordinator.courseLoggedInForCache(
          _hasScheduleCache,
        );
      });
    }
  }

  Future<void> _refreshCampusCardBalance() async {
    final cachedText = _snapshotCoordinator.cachedCampusCardBalanceText();
    if (cachedText != null && mounted) {
      setState(() {
        _campusCardBalance = cachedText;
      });
      return;
    }
    final authGuard = _authGeneration;
    try {
      final text = await _snapshotCoordinator.fetchCampusCardBalanceText();
      if (!mounted || authGuard != _authGeneration) return;
      setState(() {
        _campusCardBalance = text;
      });
    } catch (e) {
      if (!mounted || authGuard != _authGeneration) return;
      NetworkErrorToast.show(context, e);
    }
  }

  /// 电费刷新：房间配置 / 余额都按当前统一认证 owner 归属（无 owner 标记
  /// 或归属他人时 `hasRoomConfig` 即为 false，直接回落占位符）。await 前捕获
  /// 认证世代，房间配置与网络结果都只在世代未变时写回；登出 / 换号后迟到的
  /// 旧 owner 结果一律丢弃。
  Future<void> _refreshDormElectricity() async {
    if (!_isBootstrapReady) return;
    final authGuard = _authGeneration;
    final hasRoomConfig = await _snapshotCoordinator.hasElectricityRoomConfig();
    if (!mounted || authGuard != _authGeneration) return;
    if (!hasRoomConfig) {
      setState(() {
        _dormElectricity = '--';
      });
      return;
    }
    try {
      final text = await _snapshotCoordinator.fetchElectricityText();
      if (!mounted || authGuard != _authGeneration) return;
      setState(() {
        _dormElectricity = text;
      });
    } catch (e) {
      if (!mounted || authGuard != _authGeneration) return;
      NetworkErrorToast.show(context, e);
    }
  }

  Future<void> _refreshExam() async {
    if (!_isBootstrapReady) return;
    final authGuard = _authGeneration;
    final cached = _snapshotCoordinator.cachedNextExam;
    if (cached != null && mounted) {
      setState(() {
        _nextExam = cached;
      });
    }
    if (!_snapshotCoordinator.isAcademicLoggedIn) return;
    try {
      final next = await _snapshotCoordinator.fetchNextExam();
      if (!mounted || authGuard != _authGeneration) return;
      setState(() {
        _nextExam = next;
      });
    } catch (e) {
      if (!mounted || authGuard != _authGeneration) return;
      NetworkErrorToast.show(context, e);
    }
  }

  Future<void> _refreshGrades() async {
    if (!_isBootstrapReady) return;
    if (!_snapshotCoordinator.isAcademicLoggedIn) return;
    try {
      await _snapshotCoordinator.warmGrades();
    } catch (e) {
      if (!mounted) return;
      NetworkErrorToast.show(context, e);
    }
  }

  /// 统一的路由跳转：返回首页后按目的地触发对应的延迟刷新。
  Future<void> _pushFeatureRoute(BuildContext context, String routeName) async {
    await context.pushNamed(routeName);
    if (!mounted) return;
    // push 的 Future 在 pop **开始**时就完成（路由 didPop 之后），此时返回转场
    // 才刚起步。刷新里的缓存读取 / JSON 解码 / setState 都跑在 UI 线程，
    // 等转场落定再开始，避免与首页重新露出的头几帧抢帧。
    await PageTransitionActivity.instance.whenIdle();
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
    // alignment 0：功能区顶对齐视口顶——dock「功能」的语义是直达功能区，
    // 而非最小可见（新布局功能区起点已在首屏内，最小可见会原地不动）。
    await Scrollable.ensureVisible(
      sectionContext,
      alignment: 0.0,
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
        // 功能区磁贴的亚克力模糊共用一次背景读取（见 AppTileSurface）。
        body: BackdropGroup(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const AppWallpaperBackdrop(),
              SafeArea(
                bottom: false,
                child: ValueListenableBuilder<HomeTextColorMode>(
                  valueListenable:
                      AppThemeController.instance.homeTextColorMode,
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
      ),
    );
  }

  Widget _buildScrollBody(BuildContext context) {
    final presentation = _resolvePresentation();
    final now = DateTime.now();
    final bottomClearance =
        MediaQuery.paddingOf(context).bottom + _bottomNavClearance;

    final heroWidget = HomePrimaryStatusHero(
      hero: presentation.hero,
      envDateText: _formatEnvDate(now),
      envStatusText: presentation.weekLabel,
      canShowUpdateAction: _canShowUpdateAction,
      unreadNoticeCount: _noticeHead.unreadCount,
      onOpenSchedule: () async {
        await _pushFeatureRoute(context, 'schedule');
      },
      onNotificationTap: () => context.pushNamed('notification-center'),
      onUpdateTap: _handleUpdateTap,
      // 登录成功后由既有的教务身份监听刷新首页，这里无需再处理结果。
      onLoginTap: () =>
          (widget.loginPromptPresenter ?? showAcademicSystemLoginModal)(
            context,
          ),
    );

    final todayWidget = HomeTodaySection(
      today: presentation.today,
      onOpenSchedule: () async {
        await _pushFeatureRoute(context, 'schedule');
      },
    );

    final assetWidget = HomeAssetStrip(
      status: presentation.status,
      onCampusCardTap: () => _pushFeatureRoute(context, 'campus-card'),
      onElectricityTap: () => _pushFeatureRoute(context, 'dorm-electricity'),
    );

    return SingleChildScrollView(
      key: _scrollViewportKey,
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _pageGutter,
              AppSpacing.xl,
              _pageGutter,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heroWidget,
                if (presentation.alert != null) ...[
                  const SizedBox(height: AppSpacing.xl),
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
                const SizedBox(height: _sectionGap),
                todayWidget,
                const SizedBox(height: _sectionGap),
                assetWidget,
              ],
            ),
          ),
          // 公告 + 功能区尾段：公告开关变化时整段重建。公告紧随资产行
          //（用户可不经滚动直达完整公告列表），其后是功能区小按钮段落。
          ValueListenableBuilder<bool>(
            valueListenable:
                PersonalizationController.instance.homeCampusNoticeEnabled,
            builder: (context, noticeEnabled, _) {
              final noticeVisible = noticeEnabled && !_noticeHead.isEmpty;
              final noticeWidget = HomeCampusNoticeSection(
                head: _noticeHead,
                onTapNotice: _openCampusNotice,
                onTapAll: () => context.pushNamed('notification-center'),
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (noticeVisible)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _pageGutter,
                        _sectionGap,
                        _pageGutter,
                        AppSpacing.sectionBreak,
                      ),
                      child: noticeWidget,
                    ),
                  // 功能区锚点：key 挂在容器上，ensureVisible 滚动到位后
                  // 标题不贴视口顶；公告关闭时顶距退回普通段落间距。
                  Container(
                    key: _functionSectionKey,
                    padding: EdgeInsets.only(
                      top: noticeVisible ? 0 : AppSpacing.sectionBreak,
                      bottom: bottomClearance,
                    ),
                    child: FunctionZoneSection(
                      campusCardBalance: _campusCardBalance,
                      dormElectricity: _dormElectricity,
                      padding: EdgeInsets.fromLTRB(
                        _pageGutter,
                        0,
                        _pageGutter,
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
}
