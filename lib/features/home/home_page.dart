import 'dart:async';

import 'package:material_ui/material_ui.dart';
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
import '../../core/theme/app_typography.dart';
import '../../core/theme/page_transition_activity.dart';
import '../../core/theme/personalization_controller.dart';
import '../../core/theme/widgets/app_wallpaper_backdrop.dart';
import '../../core/update/apk_update_controller.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_progress_text.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_surface_style.dart';
import '../../shared/widgets/app_tile_surface.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import '../../shared/widgets/update_dialog.dart';
import '../../core/academic/exam_model.dart';
import '../../core/academic/schedule_cache_snapshot.dart';
import '../second_classroom/second_classroom_model.dart';
import 'campus_snapshot_coordinator.dart';
import 'function_zone/function_zone_section.dart';
import 'home_presentation_resolver.dart';
import 'home_zone_controller.dart';
import 'models/home_asset_state.dart';
import 'models/home_presentation.dart';
import 'models/home_snapshot.dart';
import 'models/home_today_agenda.dart';
import 'widgets/home_asset_strip.dart';
import 'widgets/home_campus_notice_section.dart';
import 'widgets/home_event_banner.dart';
import 'widgets/home_primary_status_hero.dart';
import 'widgets/home_today_agenda_cards.dart';
import 'widgets/home_today_section.dart';
import 'widget/campus_widget_sync.dart';

/// 首页：天气 App 式的单一纵向连续滚动页。
///
/// 第一屏只回答「今天什么状态」：环境行 → 无框 Hero（下一节课/当前
/// 状态）→（可选）事件横幅 → 资产行（校园卡 + 电费）→（可选）「校园公告」
/// 简化预览 →「今天」锚点段落（紧凑今天课程/考试列表或空态）→
/// 「功能」锚点段落（全部入口的轻量小按钮工具条，含课表——原快捷
/// 入口行已并入）。底部 dock 通过 [HomeZoneController] 做 ScrollSpy，
/// 在 首页/今天/功能 之间自动切换高亮。数据获取与刷新行为与旧版一致，
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

  /// 今天区锚点：dock「今天」点击的滚动定位与 ScrollSpy 判定都基于它。
  final _todaySectionKey = GlobalKey();

  /// 功能区锚点：dock「功能」点击的滚动定位与 ScrollSpy 判定都基于它。
  final _functionSectionKey = GlobalKey();

  /// 滚动视口：ScrollSpy 用它把功能区顶部的全局坐标换算成视口内坐标。
  final _scrollViewportKey = GlobalKey();

  /// 资产行两项的独立获取状态（在途计数 + 是否已尝试 + 配置缺失），
  /// 由真实任务生命周期驱动；展示态在 `_resolveAssetState` 里派生，
  /// 不在 build 中发请求、也不用计时器伪装加载。
  int _campusCardInFlight = 0;
  int _electricityInFlight = 0;
  bool _campusCardAttempted = false;
  bool _electricityAttempted = false;
  bool _electricityNotConfigured = false;

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

  /// 「今天」板块本地二课活动缓存（订阅 + 已报名缓存，零网络读取）。
  List<SecondClassroomActivity> _subscribedActivities = const [];
  List<SecondClassroomActivity> _cachedActivities = const [];

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

  /// 更新角标的阶段集合：仅在「有可见进度 / 就绪可装」时才需要持续投影；
  /// 对账 / 清理等瞬态不单独表达（详情以弹窗为准）。
  static const Set<ApkUpdatePhase> _updateStatusPhases = <ApkUpdatePhase>{
    ApkUpdatePhase.enqueued,
    ApkUpdatePhase.downloading,
    ApkUpdatePhase.paused,
    ApkUpdatePhase.verifying,
    ApkUpdatePhase.readyToInstall,
    ApkUpdatePhase.permissionRequired,
  };

  /// 后台下载 / 就绪状态（无新版本角标也要给出入口，否则转后台后无法重新
  /// 打开弹窗取消或安装）。
  ApkUpdateState get _updateState => ApkUpdateController.instance.state.value;

  bool get _hasManagedUpdateInFlight =>
      _updateStatusPhases.contains(_updateState.phase);

  bool get _canShowUpdateAction =>
      (UpdateChecker.instance.isUpdateEnabled && _hasAvailableUpdate) ||
      _hasManagedUpdateInFlight;

  /// 角标 tooltip 的状态投影：下载中给紧凑进度，就绪给「已就绪」提示；
  /// 其余情况保持「发现新版本」。
  String? get _updateStatusText => describeManagedUpdateProgress(_updateState);

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
    // 后台下载进度 / 就绪状态驱动更新角标的可见性与 tooltip（非阻塞提示）。
    ApkUpdateController.instance.state.addListener(_onUpdateStateChanged);
    NoticeSyncStore.instance.inboxHead.addListener(_onNoticeHeadChanged);
    _noticeHead = NoticeSyncStore.instance.inboxHead.value;
    CampusDataChangeBus.instance.revision.addListener(_onCampusDataChanged);
    _scrollController.addListener(_onScrollChanged);
    HomeZoneController.instance
      ..scrollToTop = _scrollToTop
      ..scrollToToday = _scrollToToday
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
    ApkUpdateController.instance.state.removeListener(_onUpdateStateChanged);
    NoticeSyncStore.instance.inboxHead.removeListener(_onNoticeHeadChanged);
    CampusDataChangeBus.instance.revision.removeListener(_onCampusDataChanged);
    _scrollController.removeListener(_onScrollChanged);
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToToday = null
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

  void _onUpdateStateChanged() {
    if (!mounted) return;
    setState(() {});
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
    _resetAssetLifecycle();
    _reAdoptPrivateProjection();
    _scheduleAssetRefreshAfterLogin(_authGeneration);
  }

  /// 登录 / 换号 / 同号重登后补一次资产行刷新。
  ///
  /// 前台 [CampusRefreshCoordinator] 虽也会在身份变化时刷新服务层缓存，但它
  /// 不经过本页的「在途 / 已尝试 / 未配置」信号：身份复位后若没有本页发起
  /// 的请求，资产行会一直停在静态的 `preparing`（`--`），失败也无法进入
  /// 「获取失败」可重试态。因此已登录且 bootstrap 就绪时由本页自己排一次，
  /// 与其它刷新路径一样等页面转场落定再开始；等待期间若世代再次推进
  /// （又一次身份变化）则放弃，由新的那次负责。登出不排（资产行为「待登录」）。
  void _scheduleAssetRefreshAfterLogin(int generation) {
    if (!_hasHydratedBootstrapState ||
        !_snapshotCoordinator.isUnifiedLoggedIn) {
      return;
    }
    unawaited(() async {
      await PageTransitionActivity.instance.whenIdle();
      if (!mounted || generation != _authGeneration) return;
      await Future.wait<void>([
        _refreshCampusCardBalance(),
        _refreshDormElectricity(),
      ]);
    }());
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

  /// 身份变化（登录 / 登出 / 换号 / 同号重登）时复位资产行的生命周期信号：
  /// 清在途计数与「已尝试 / 未配置」标记，配合 owner 归属校验让旧值立即
  /// 回落，并在下轮真实请求前呈现正确的加载 / 待登录态。
  void _resetAssetLifecycle() {
    _campusCardInFlight = 0;
    _electricityInFlight = 0;
    _campusCardAttempted = false;
    _electricityAttempted = false;
    _electricityNotConfigured = false;
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
      unawaited(_refreshLocalSecondClassroomAgenda());
      unawaited(_refreshDeferredContent());
    });
  }

  Future<void> _refreshLocalSecondClassroomAgenda() async {
    final loaded = await _snapshotCoordinator
        .loadLocalSecondClassroomActivities();
    if (!mounted) return;
    setState(() {
      _subscribedActivities = loaded.subscribed;
      _cachedActivities = loaded.cached;
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
    _nextExam = data.nextExam;
    // 校园卡 / 电费的展示值不再缓存成字符串：资产状态由当前服务缓存 +
    // 在途请求派生（见 `_resolveCampusCardAsset` / `_resolveElectricityAsset`）。
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

  /// 校园卡余额刷新：真实任务生命周期驱动资产行状态。
  ///
  /// 有新鲜缓存时直接展示、不发网络；否则计入在途计数（`_campusCardInFlight`）
  /// 并发起真实请求。值只在服务成功落盘后由 `CampusDataChangeBus` 回流，
  /// 本方法只维护「在途 / 已尝试」信号与失败提示，绝不写死字符串。
  /// await 前捕获认证世代，登出 / 换号后迟到的旧 owner 结果一律丢弃。
  Future<void> _refreshCampusCardBalance() async {
    if (!_isBootstrapReady) return;
    // 已有请求在途（含「获取失败」被连点重试）：不并发再发一条。
    if (_campusCardInFlight > 0) return;
    final authGuard = _authGeneration;
    if (_snapshotCoordinator.cachedCampusCardBalanceText() != null) {
      // 已有新鲜缓存：直接展示，不发网络。
      if (!mounted || authGuard != _authGeneration) return;
      setState(() {
        _campusCardAttempted = true;
      });
      return;
    }
    if (!mounted || authGuard != _authGeneration) return;
    setState(() {
      _campusCardInFlight++;
      _campusCardAttempted = true;
    });
    try {
      await _snapshotCoordinator.fetchCampusCardBalanceText();
    } catch (e) {
      if (!mounted || authGuard != _authGeneration) return;
      NetworkErrorToast.show(context, e);
    } finally {
      if (mounted && authGuard == _authGeneration) {
        setState(_endCampusCardFetch);
      }
    }
  }

  void _endCampusCardFetch() {
    _campusCardInFlight = _campusCardInFlight > 0 ? _campusCardInFlight - 1 : 0;
  }

  /// 电费刷新：房间配置 / 余额都按当前统一认证 owner 归属（无 owner 标记
  /// 或归属他人时 `hasRoomConfig` 即为 false，呈现「未设置」，绝不伪装成加载）。
  /// await 前捕获认证世代，登出 / 换号后迟到的旧 owner 结果一律丢弃。
  Future<void> _refreshDormElectricity() async {
    if (!_isBootstrapReady) return;
    // 已有请求在途（含「获取失败」被连点重试）：不并发再发一条。
    if (_electricityInFlight > 0) return;
    final authGuard = _authGeneration;
    if (!_snapshotCoordinator.isUnifiedLoggedIn) {
      // 无统一认证身份：不发请求，资产行由身份派生为「待登录」。
      if (!mounted) return;
      setState(() {
        _electricityAttempted = true;
      });
      return;
    }
    if (!mounted || authGuard != _authGeneration) return;
    setState(() {
      _electricityInFlight++;
      _electricityAttempted = true;
    });
    try {
      final hasRoomConfig = await _snapshotCoordinator
          .hasElectricityRoomConfig();
      if (!mounted || authGuard != _authGeneration) return;
      if (!hasRoomConfig) {
        setState(() {
          _electricityNotConfigured = true;
        });
        return;
      }
      _electricityNotConfigured = false;
      await _snapshotCoordinator.fetchElectricityText();
    } catch (e) {
      if (!mounted || authGuard != _authGeneration) return;
      NetworkErrorToast.show(context, e);
    } finally {
      if (mounted && authGuard == _authGeneration) {
        setState(_endElectricityFetch);
      }
    }
  }

  void _endElectricityFetch() {
    _electricityInFlight = _electricityInFlight > 0
        ? _electricityInFlight - 1
        : 0;
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
      case 'second-classroom':
        await _refreshLocalSecondClassroomAgenda();
    }
  }

  void _handleUpdateTap() {
    final release = UpdateChecker.instance.availableRelease.value;
    if (release == null) {
      // 无缓存新版本但仍有受管下载在途 / 已就绪：重开受管弹窗，可查看进度、
      // 取消或安装（与「设置 → 检查更新」的恢复路径一致）。
      if (_updateState.phase.isActive) {
        showManagedUpdateDialog(context);
      }
      return;
    }
    showUpdateDialog(context, release);
  }

  // ── dock ScrollSpy 与锚点滚动 ─────────────────────────────────────────────

  Future<void> _scrollToTop() async {
    if (!_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: AppMotion.scroll,
      curve: AppMotion.standard,
    );
  }

  Future<void> _scrollToToday() => _scrollToSection(_todaySectionKey);

  Future<void> _scrollToFunction() => _scrollToSection(_functionSectionKey);

  Future<void> _scrollToSection(GlobalKey sectionKey) async {
    final sectionContext = sectionKey.currentContext;
    final viewportContext = _scrollViewportKey.currentContext;
    if (sectionContext == null || viewportContext == null) return;
    if (!_scrollController.hasClients) return;

    final viewportBox = viewportContext.findRenderObject() as RenderBox?;
    final sectionBox = sectionContext.findRenderObject() as RenderBox?;
    if (viewportBox == null || sectionBox == null) return;

    // 直接算目标偏移，而不是先 ensureVisible 再回拉：两段动画会顿一下。
    // 留出状态栏高度 + 8dp，让区块标题落在实色区而不是渐隐羽化区里
    // （状态栏透明后，区块顶对齐屏幕顶 = 标题被羽化洗掉）。
    final topInset = MediaQuery.paddingOf(context).top;
    final sectionTop = sectionBox
        .localToGlobal(Offset.zero, ancestor: viewportBox)
        .dy;
    final target = (_scrollController.offset + sectionTop - topInset - 8).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      target,
      duration: AppMotion.scroll,
      curve: AppMotion.standard,
    );
  }

  /// ScrollSpy：按自下而上优先级判定当前可视分区（0 = 主页，1 = 今天，
  /// 2 = 功能）。
  ///
  /// 锚点顶部坐标相对滚动视口（而非屏幕）计算，保证状态栏/SafeArea
  /// 差异不影响判定；`offset <= 0` 护栏确保空状态（首屏内容很矮、锚点
  /// 天然高于判定线）时刚打开页面 dock 仍高亮「主页」。分区实际变化时
  /// 才通知（[HomeZoneController] 内部去重），滚动过程中不产生多余重建。
  void _onScrollChanged() {
    final viewportBox =
        _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    final todayBox =
        _todaySectionKey.currentContext?.findRenderObject() as RenderBox?;
    final functionBox =
        _functionSectionKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null ||
        todayBox == null ||
        functionBox == null ||
        !viewportBox.attached ||
        !todayBox.attached ||
        !functionBox.attached ||
        !_scrollController.hasClients) {
      return;
    }
    if (_scrollController.offset <= 0) {
      HomeZoneController.instance.updateZone(0);
      return;
    }
    final trigger = viewportBox.size.height * _zoneTriggerViewportFraction;
    final functionTop = functionBox
        .localToGlobal(Offset.zero, ancestor: viewportBox)
        .dy;
    if (functionTop <= trigger) {
      HomeZoneController.instance.updateZone(2);
      return;
    }
    final todayTop = todayBox
        .localToGlobal(Offset.zero, ancestor: viewportBox)
        .dy;
    HomeZoneController.instance.updateZone(todayTop <= trigger ? 1 : 0);
  }

  /// 校园卡余额展示状态（纯函数派生，见 [resolveHomeAssetState]）。
  HomeAssetState _resolveCampusCardAsset() => resolveHomeAssetState(
    bootstrapReady: _isBootstrapReady,
    loggedIn: _snapshotCoordinator.isUnifiedLoggedIn,
    value: _snapshotCoordinator.campusCardDisplayValue(),
    inFlight: _campusCardInFlight,
    attempted: _campusCardAttempted,
    authRequired: _snapshotCoordinator.campusCardAuthRequired,
    notConfigured: false,
  );

  /// 宿舍电费展示状态；比校园卡多一个「未设置寝室」维度。
  HomeAssetState _resolveElectricityAsset() => resolveHomeAssetState(
    bootstrapReady: _isBootstrapReady,
    loggedIn: _snapshotCoordinator.isUnifiedLoggedIn,
    value: _snapshotCoordinator.electricityDisplayValue(),
    inFlight: _electricityInFlight,
    attempted: _electricityAttempted,
    authRequired: _snapshotCoordinator.electricityRequiresAuthentication,
    notConfigured: _electricityNotConfigured,
  );

  HomePresentation _resolvePresentation() {
    final now = DateTime.now();
    final campusCardAsset = _resolveCampusCardAsset();
    final electricityAsset = _resolveElectricityAsset();
    final snapshot = HomeSnapshot(
      now: now,
      courseLoggedIn: _courseLoggedIn,
      hasScheduleCache: _hasScheduleCache,
      courses: _scheduleSnapshot?.courses ?? const [],
      changeRules: _scheduleSnapshot?.changeRules ?? const [],
      dateOverrides: _scheduleSnapshot?.dateOverrides ?? const [],
      isBeforeSemesterStart: SemesterCalendar.instance.isBeforeSemesterStart(
        now,
      ),
      isAfterSemesterEnd: SemesterCalendar.instance.isAfterSemesterEnd(now),
      currentWeek: SemesterCalendar.instance.weekForDate(now),
      semesterStartDate: SemesterCalendar.instance.semesterStartDate.value,
      nextExam: _nextExam,
      campusCardBalance: campusCardAsset.value ?? '--',
      dormElectricity: electricityAsset.value ?? '--',
      campusCardAsset: campusCardAsset,
      electricityAsset: electricityAsset,
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
        // 页面主体跟随主题色（个性化 / 壁纸取色都在这里生效）。
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        // 功能区磁贴的亚克力模糊共用一次背景读取（见 AppTileSurface）。
        body: BackdropGroup(
          child: Stack(
            children: [
              SafeArea(
                // 顶部不吃系统内边距：内容要能从状态栏底下滚过去，状态栏才是
                // 真透明（否则滚动后状态栏位置会留下一条 Scaffold 底色「横杠」）。
                // 首屏的让位改在滚动内容里补 `paddingOf(context).top`。
                top: false,
                bottom: false,
                child: ValueListenableBuilder<HomeTextColorMode>(
                  valueListenable:
                      AppThemeController.instance.homeTextColorMode,
                  builder: (context, _, _) =>
                      // 「今天全部课程」开关变化时重建滚动内容，Today 段落
                      // 在剩余/全天形态间即时切换。
                      ValueListenableBuilder<bool>(
                        valueListenable: PersonalizationController
                            .instance
                            .fullDayCoursesEnabled,
                        builder: (context, _, _) => _buildScrollBody(context),
                      ),
                ),
              ),
              // 状态栏滚动微羽化：静止于首屏时为全透明（克制流体底自身已保证图标与文字可读，
              // 不在顶部叠加发白横带）；仅在页面上滚、内容将穿过状态栏时平滑淡入柔和底色保护。
              if (MediaQuery.paddingOf(context).top > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.paddingOf(context).top + 18,
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _scrollController,
                      builder: (context, _) {
                        final offset = _scrollController.hasClients
                            ? _scrollController.offset
                            : 0.0;
                        final t = (offset / 36.0).clamp(0.0, 1.0);
                        final eased = t * t * (3.0 - 2.0 * t);
                        if (eased <= 0.001) return const SizedBox.shrink();
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        final tint = Theme.of(context).scaffoldBackgroundColor;
                        final peak = (isDark ? 0.72 : 0.78) * eased;
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: const [0.0, 0.36, 0.64, 0.84, 1.0],
                              colors: [
                                tint.withValues(alpha: peak),
                                tint.withValues(alpha: peak * 0.88),
                                tint.withValues(alpha: peak * 0.54),
                                tint.withValues(alpha: peak * 0.18),
                                tint.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        );
                      },
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
      updateStatusText: _updateStatusText,
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

    final todayAgenda = resolveHomeTodayAgenda(
      now: now,
      exams: _snapshotCoordinator.cachedExams ?? const [],
      subscribedActivities: _subscribedActivities,
      cachedActivities: _cachedActivities,
      excludeExamCourseName: presentation.hero.kind == HomeHeroKind.examSoon
          ? presentation.hero.courseName
          : null,
    );

    final assetWidget = HomeAssetStrip(
      status: presentation.status,
      onCampusCardTap: () => _pushFeatureRoute(context, 'campus-card'),
      onElectricityTap: () => _pushFeatureRoute(context, 'dorm-electricity'),
      // 获取失败（无缓存）时，资产行整行点击改为受控重试；其余状态仍是
      // 既有的进入对应详情页导航，不改变正常状态的手势语义。
      onCampusCardRetry: () async {
        await _refreshCampusCardBalance();
      },
      onElectricityRetry: () async {
        await _refreshDormElectricity();
      },
    );

    return SingleChildScrollView(
      key: _scrollViewportKey,
      controller: _scrollController,
      child: Stack(
        children: [
          // 流体背景 / 壁纸只覆盖首屏，并且**随内容一起上滚**：滚到公告与
          // 功能区时它已经离开视口，那两段因此坐在纯白 / 纯黑纸面上，
          // 不会被 shader 或壁纸染色。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.sizeOf(context).height,
            child: AppWallpaperBackdrop(scrollController: _scrollController),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  _pageGutter,
                  AppSpacing.xl + MediaQuery.paddingOf(context).top,
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
                    // 资产行紧随 Hero / 事件横幅下方（校园公告紧随资产行）。
                    const SizedBox(height: _sectionGap),
                    assetWidget,
                  ],
                ),
              ),
              // 今天区（含今日公告）+ 功能区尾段：公告开关变化时整段重建。
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
                      const SizedBox(height: 28),
                      // 今天区锚点：始终留在树中，供 dock「今天」滚动定位与 ScrollSpy 判定。
                      Container(
                        key: _todaySectionKey,
                        padding: const EdgeInsets.symmetric(
                          horizontal: _pageGutter,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _TodayZoneHeader(
                              courseCount:
                                  !presentation.today.isPreview &&
                                      !presentation.today.isCollapsed &&
                                      presentation.today.courses.isNotEmpty
                                  ? presentation.today.courses.length
                                  : null,
                              onOpenSchedule: () => unawaited(
                                _pushFeatureRoute(context, 'schedule'),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (!presentation.today.isEmpty)
                              todayWidget
                            else if (!todayAgenda.hasExtras)
                              _TodayEmptyState(
                                onOpenSchedule: () => unawaited(
                                  _pushFeatureRoute(context, 'schedule'),
                                ),
                              ),
                            if (todayAgenda.hasExtras) ...[
                              if (!presentation.today.isEmpty)
                                const SizedBox(height: AppSpacing.sm),
                              HomeTodayAgendaCards(
                                agenda: todayAgenda,
                                onOpenExam: () => unawaited(
                                  _pushFeatureRoute(context, 'exam'),
                                ),
                                onOpenSecondClassroom: () => unawaited(
                                  _pushFeatureRoute(
                                    context,
                                    'second-classroom',
                                  ),
                                ),
                              ),
                            ],
                            // 今日公告并入「今天」区收尾：与议程卡片同卡面配方，
                            // 无当日新增公告时卡片自身收起不占位。
                            if (noticeVisible) ...[
                              const SizedBox(height: AppSpacing.sm),
                              noticeWidget,
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      // 功能区锚点：key 挂在容器上，顶距由上一段落的 sectionBreak 承担，
                      // 滚动到位后标题落在实色区而不是状态栏羽化区。
                      Container(
                        key: _functionSectionKey,
                        padding: EdgeInsets.only(bottom: bottomClearance),
                        child: FunctionZoneSection(
                          campusCardBalance:
                              presentation.status.campusCardBalance,
                          dormElectricity: presentation.status.dormElectricity,
                          padding: const EdgeInsets.fromLTRB(
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
        ],
      ),
    );
  }
}

/// 今天段落头：与 `_FunctionZoneHeader` 视觉一致，左「今天」标题（可选
/// 次级课数计数）、右「查看课表」入口。
class _TodayZoneHeader extends StatelessWidget {
  const _TodayZoneHeader({this.courseCount, required this.onOpenSchedule});

  final int? courseCount;
  final VoidCallback onOpenSchedule;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    return Row(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '今天',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
            ),
            if (courseCount != null && courseCount! > 0) ...[
              const SizedBox(width: 8),
              Text(
                '$courseCount 节课',
                style: context.appText.meta.copyWith(
                  color: secondaryTextColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: '查看课表',
          child: InkWell(
            onTap: onOpenSchedule,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '查看课表',
                    style: context.appText.meta.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: cs.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 今天区空态：无课程与考试安排时以轻量瓦片承接，整块可点进完整课表。
class _TodayEmptyState extends StatelessWidget {
  const _TodayEmptyState({required this.onOpenSchedule});

  final VoidCallback onOpenSchedule;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '今天暂无课程与考试安排',
      child: AppHardTileShell(
        radius: AppRadius.tile,
        child: AppTileSurface(
          borderRadius: AppRadius.tileBorder,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          blurred: false,
          onTap: onOpenSchedule,
          child: Row(
            children: [
              AppIconBadge(
                icon: Icons.calendar_today_outlined,
                accentColor: cs.primary,
                size: AppIconBadgeSize.medium,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '今天暂无课程与考试安排',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.appText.rowTitle.copyWith(height: 1.25),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
