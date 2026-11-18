import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/actions/campus_action_executor.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/config/app_config.dart';
import '../../core/logging/app_logger.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/detail_readout.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_feedback.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({super.key});

  /// Whether the automatic balance refresh was triggered (for testing).
  static bool debugAutoRefreshTriggered = false;

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  bool _balanceLoading = false;
  bool _obscured = false;

  /// 首屏「未登录自动弹一次登录」的一次性窗口：窗口关闭后（已弹过 / 入场
  /// 已登录 / 任何认证状态变化）不再自动弹登录，只能由用户点击登录入口
  /// 触发，避免 rebuild、认证通知或瞬时失败反复打断。
  bool _initialLoginPromptResolved = false;
  VoidCallback? _bootstrapPhaseListener;

  /// 最近一次观察到的明确认证身份（未登录 / 身份不完整时账号为 null），用于
  /// 只在真实身份推进（换号 / 同号重登推进 sessionRevision）时自动拉余额；
  /// 同一 revision 的重复认证通知不重拉。
  ({String? account, int revision}) _lastAuthIdentity = (
    account: null,
    revision: 0,
  );

  /// 在途余额请求启动时固定的身份：完成时据此判定结果是否过期。
  ({String? account, int revision})? _inFlightIdentity;

  /// 旧请求在途时排队到其结算后补拉的新身份请求（多次排队合并为一次）。
  ({bool showFeedback, bool forceRefresh})? _queuedRefresh;

  /// 每成功排定一次登录后拉取即递增：[_handleLogin] 据此判断本次登录是否已
  /// 被 [_onAuthChanged] 的身份推进拉取覆盖，保证两条路径合计恰好拉一次。
  int _pullEpoch = 0;

  /// 登录成功欠下的余额拉取：无论通知先来后来、账号何时就绪，登录最终保证
  /// 恰好拉一次；弹窗进行中一律推迟到弹窗结算后才真正发出。
  bool _pendingLoginPull = false;

  /// 登录弹窗进行中深度（防嵌套）：期间所有登录拉取推迟——弹窗内的重复
  /// 认证通知会作废在途请求，过早发出的拉取既白费触网又让余额悬空。
  int _loginModalDepth = 0;

  @override
  void initState() {
    super.initState();
    _lastAuthIdentity = _currentIdentity();
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    _scheduleAutoRefreshIfNeeded();
    _scheduleInitialLoginPrompt();
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    _detachBootstrapListener();
    super.dispose();
  }

  /// 当前明确认证身份（账号 + sessionRevision）；未登录或身份不完整（active
  /// 但无账号）一律视为账号 null（未知），与 [CampusCardService] 的 owner
  /// 判定保持一致。同一 revision 的重复通知视为同一身份。
  ({String? account, int revision}) _currentIdentity() {
    final auth = UnifiedAuthService.instance;
    return (account: auth.verifiedAccount, revision: auth.sessionRevision);
  }

  void _onAuthChanged() {
    // 任何认证状态变化都结束首屏一次性窗口：登录成功展示内容，登出只回到
    // 登录门，都不得再自动弹登录。
    _initialLoginPromptResolved = true;
    _detachBootstrapListener();
    final identity = _currentIdentity();
    final previous = _lastAuthIdentity;
    _lastAuthIdentity = identity;
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {});
    // 身份推进（换号 / 同号重登推进 sessionRevision）恰好欠一次登录拉取。
    // 用微任务延到本次通知广播结束再拉——服务端监听器会先清缓存、推进身份
    // 世代，拉取捕获到的才是新身份上下文。
    if (identity.account != null &&
        (identity.account != previous.account ||
            identity.revision != previous.revision)) {
      _pendingLoginPull = true;
    }
    // 收敛已欠下的登录拉取：同 revision 的重复通知不新欠、不重拉；登录
    // 弹窗进行中一律推迟到弹窗结算；账号未就绪继续等下一次认证通知。
    _settlePendingLoginPull();
  }

  /// 落实登录欠下的拉取：排定恰好一次。弹窗进行中推迟（弹窗内的重复认证
  /// 通知会作废在途请求，拉取必须等弹窗结算后发出才活得下来）；账号未就绪
  /// 则保持欠账，由后续认证通知继续收敛——绝不因通知顺序把拉取悬空。
  void _settlePendingLoginPull() {
    if (!_pendingLoginPull || !mounted) return;
    if (_loginModalDepth > 0) return;
    if (_currentIdentity().account == null) return;
    _pendingLoginPull = false;
    _pullEpoch++;
    unawaited(Future<void>.microtask(_pullBalanceAfterLogin));
  }

  /// 登录后余额拉取入口：force 关闭，只在 owner 绑定缓存缺失 / 过期时触网
  ///（不覆盖新鲜缓存）；初始化自动刷新与 [_handleLogin] 都收敛到这里去重。
  Future<void> _pullBalanceAfterLogin() => _refreshBalance(forceRefresh: false);

  void _detachBootstrapListener() {
    final listener = _bootstrapPhaseListener;
    if (listener == null) return;
    _bootstrapPhaseListener = null;
    AppBootstrapController.instance.phase.removeListener(listener);
  }

  /// 首屏一次性登录引导：仅当「进入页面即未登录」且引导 / 认证状态已确定
  ///（暖启动已恢复持久身份）时，post-frame 自动唤起一次原生登录弹窗。
  void _scheduleInitialLoginPrompt() {
    void listener() {
      _maybeAutoPromptInitialLogin();
      if (_initialLoginPromptResolved) _detachBootstrapListener();
    }

    _maybeAutoPromptInitialLogin();
    if (_initialLoginPromptResolved) return;
    _bootstrapPhaseListener = listener;
    AppBootstrapController.instance.phase.addListener(listener);
  }

  void _maybeAutoPromptInitialLogin() {
    if (_initialLoginPromptResolved || !mounted) return;
    final phase = AppBootstrapController.instance.phase.value;
    final authStateKnown =
        phase == AppBootstrapPhase.localStateReady ||
        phase == AppBootstrapPhase.completed;
    // 暖启动未完成时持久身份可能仍在恢复，不得提前弹登录。
    if (!authStateKnown) return;
    _initialLoginPromptResolved = true;
    if (UnifiedAuthService.instance.isLoggedIn) return;
    // post-frame 再弹，避免在 build / 通知回调里直接压路由；主动要一帧，
    // 不依赖恰好有动画在跑。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || UnifiedAuthService.instance.isLoggedIn) return;
      unawaited(_handleLogin());
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scheduleAutoRefreshIfNeeded() {
    // 未登录不做自动查询：登录由登录门负责，查询在登录成功后进行。
    if (!UnifiedAuthService.instance.isLoggedIn) return;
    if (CampusCardService.instance.cachedBalance != null) return;

    final phase = AppBootstrapController.instance.phase;
    if (phase.value == AppBootstrapPhase.localStateReady ||
        phase.value == AppBootstrapPhase.completed) {
      // Warm-up already done — balance is genuinely missing.
      _autoRefreshBalance();
      return;
    }

    // Wait for bootstrap warm-up to restore persisted balance first.
    void listener() {
      final p = AppBootstrapController.instance.phase.value;
      if (p == AppBootstrapPhase.localStateReady ||
          p == AppBootstrapPhase.completed) {
        AppBootstrapController.instance.phase.removeListener(listener);
        if (!mounted) return;
        if (CampusCardService.instance.cachedBalance == null) {
          _autoRefreshBalance();
        }
      }
    }

    AppBootstrapController.instance.phase.addListener(listener);
  }

  void _autoRefreshBalance() {
    // 等暖启动期间可能已登出：无身份不发起查询，也绝不借此自动登录。
    if (!UnifiedAuthService.instance.isLoggedIn) return;
    CampusCardPage.debugAutoRefreshTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshBalance(showFeedback: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 未登录：整页登录门（与付款码页同款 [AuthRequiredView]），登录入口清晰
    // 唯一——不再把登录按钮藏进余额卡，也不让用户先撞一次查询错误再找按钮。
    final authRequired = !UnifiedAuthService.instance.isLoggedIn;
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;

    return Scaffold(
      appBar: AppAppBar(
        title: const Text('校园卡'),
        // AppBar 只留 ⋮：刷新主要靠下拉 + 余额卡状态行，菜单里保留「刷新
        // 余额」给不习惯下拉的用户（见 design-guidelines 4.5 / 4.6）。
        actions: [
          if (!authRequired || isAndroid)
            PopupMenuButton<_CampusCardMenuAction>(
              tooltip: '更多操作',
              onSelected: (action) {
                switch (action) {
                  case _CampusCardMenuAction.refresh:
                    _refreshBalance();
                  case _CampusCardMenuAction.addShortcut:
                    _requestPaymentShortcut();
                }
              },
              itemBuilder: (context) => [
                if (!authRequired)
                  PopupMenuItem<_CampusCardMenuAction>(
                    value: _CampusCardMenuAction.refresh,
                    enabled: !_balanceLoading,
                    child: const ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.refresh_rounded),
                      title: Text('刷新余额'),
                    ),
                  ),
                if (isAndroid)
                  const PopupMenuItem<_CampusCardMenuAction>(
                    value: _CampusCardMenuAction.addShortcut,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.add_to_home_screen_outlined),
                      title: Text('添加付款码到桌面'),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: authRequired ? _buildAuthGate(context) : _buildBalanceView(context),
    );
  }

  /// 未登录整页登录门：与付款码页共用 [AuthRequiredView]，动作直接唤起原生
  /// 统一认证登录弹窗（[_handleLogin]）；关闭弹窗后登录门保持可用。
  Widget _buildAuthGate(BuildContext context) {
    return AuthRequiredView(
      title: '需要登录统一认证后继续',
      message: '登录统一认证后可查询校园卡余额',
      buttonLabel: '登录统一认证',
      icon: Icons.credit_card_outlined,
      onAction: _handleLogin,
    );
  }

  Widget _buildBalanceView(BuildContext context) {
    final service = CampusCardService.instance;
    final balance = service.cachedBalance;
    final lastUpdated = service.lastUpdated;
    return RefreshIndicator(
      onRefresh: () => _refreshBalance(showFeedback: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.sm,
          AppSpacing.pageMargin,
          AppSpacing.xl,
        ),
        children: [
          _buildReadout(context, balance, lastUpdated),
          const SizedBox(height: AppSpacing.lg),
          _buildActionGrid(context),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Text(
              '下拉可立即刷新；余额 5 分钟内有效，离开页面也会在后台补齐。',
              style: context.appText.meta.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // ── Balance Readout ─────────────────────────────────────────────────────

  /// 无框余额读数：数字直接落在页面底色上（design-guidelines 4.7），下方是
  /// 状态行；没有余额时改为失败说明 + 登录 / 重试动作。
  Widget _buildReadout(
    BuildContext context,
    double? balance,
    DateTime? lastUpdated,
  ) {
    final cs = Theme.of(context).colorScheme;
    final balanceText = balance != null ? balance.toStringAsFixed(2) : '--';

    final failure = CampusCardService.instance.lastBalanceFailure;
    final (failureMessage, failureIcon) = switch (failure) {
      BalanceFailureKind.authRequired => (
        '请先登录统一认证，再查询校园卡余额',
        Icons.lock_outline_rounded,
      ),
      BalanceFailureKind.authExpired => (
        '登录已失效，请重新登录统一认证',
        Icons.lock_outline_rounded,
      ),
      BalanceFailureKind.serviceUnavailable => (
        '一卡通服务暂时不可用，请稍后重试',
        Icons.info_outline_rounded,
      ),
      BalanceFailureKind.network => ('网络不可用，请检查网络后重试', Icons.wifi_off_rounded),
      BalanceFailureKind.none => (null, null),
    };
    // 只有「明确认证失效」用警示底色；网络 / 服务不可用保持中性提示，
    // 不得把可重试的故障渲染成需要重新登录。
    final failureIsSerious = failure == BalanceFailureKind.authExpired;
    final failureTone = failureIsSerious ? cs.onErrorContainer : cs.onSurface;
    final failureBackground = failureIsSerious
        ? cs.errorContainer
        : cs.surfaceContainerHigh;

    return Padding(
      // 比瓦片多缩进 8；眼睛按钮自带 44 点按区，右侧不再缩进。
      padding: const EdgeInsets.only(left: AppSpacing.sm, top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailReadout(
            label: '校园卡余额',
            valueText: _obscured ? '****' : balanceText,
            unit: '元',
            muted: balance == null,
            trailing: IconButton(
              tooltip: _obscured ? '显示余额' : '隐藏余额',
              onPressed: () => setState(() => _obscured = !_obscured),
              icon: Icon(
                _obscured
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
              iconSize: 20,
              color: cs.onSurfaceVariant,
              // 显式 standard density：compact 会把 44 约束盒缩水到 36，
              // 最小点按区必须真实 ≥ 44x44。
              visualDensity: VisualDensity.standard,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ),
          if (balance == null) ...[
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                children: [
                  if (failureMessage != null && failureIcon != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: failureBackground,
                        borderRadius: AppRadius.chipBorder,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(failureIcon, size: 14, color: failureTone),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              failureMessage,
                              style: context.appText.meta.copyWith(
                                height: 1.4,
                                color: failureTone,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: switch (failure) {
                      BalanceFailureKind.authRequired => FilledButton.icon(
                        onPressed: _balanceLoading ? null : _handleLogin,
                        icon: const Icon(Icons.login_rounded, size: 18),
                        label: const Text('登录统一认证'),
                      ),
                      BalanceFailureKind.authExpired => FilledButton.icon(
                        onPressed: _balanceLoading ? null : _handleLogin,
                        icon: const Icon(Icons.login_rounded, size: 18),
                        label: const Text('重新登录'),
                      ),
                      _ => FilledButton.icon(
                        onPressed: _balanceLoading ? null : _refreshBalance,
                        icon: const Icon(Icons.touch_app_outlined, size: 18),
                        label: Text(_balanceLoading ? '正在查询余额' : '点击查询余额'),
                      ),
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ] else ...[
            const SizedBox(height: AppSpacing.sm),
            RefreshStatusLine(
              updatedAt: lastUpdated,
              refreshing: _balanceLoading,
              failed: failure != BalanceFailureKind.none,
            ),
          ],
        ],
      ),
    );
  }

  // ── Action Grid ─────────────────────────────────────────────────────────

  /// 付款码 / 账单 / 充值 三等宽格：付款码是主动作（primary 实底），其余
  /// 两格走亚克力瓦片；与寝室电费页共用 [DetailActionGrid]。
  Widget _buildActionGrid(BuildContext context) {
    return DetailActionGrid(
      actions: [
        DetailAction(
          icon: Icons.qr_code_2_outlined,
          title: '付款码',
          subtitle: '出示扫码',
          onTap: _openPaymentCodePage,
          primary: true,
        ),
        DetailAction(
          icon: Icons.receipt_long_outlined,
          title: '账单',
          subtitle: '消费明细',
          onTap: () => _openCampusCardWebView(title: '校园卡账单'),
        ),
        DetailAction(
          icon: Icons.add_card_outlined,
          title: '充值',
          subtitle: '微信',
          onTap: _openRechargePage,
        ),
      ],
    );
  }

  // ── WebView ─────────────────────────────────────────────────────────────

  Future<void> _openPaymentCodePage() async {
    await context.pushNamed('campus-card-payment');
  }

  Future<void> _openCampusCardWebView({required String title}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UnifiedAuthProtectedWebViewPage(
          title: title,
          url: CampusCardService.statusPageUrl,
          serviceUrl: CampusCardService.statusPageCasServiceUrl,
          loginDescription: '账号为校园一卡通号，校外网络自动通过 WebVPN 访问',
          authRequiredTitle: '需要登录一卡通后继续',
          authRequiredButtonLabel: '登录一卡通',
          prepareAuthenticatedUrl: CampusCardService.instance.prepareStatusPage,
          onHomePressed: () => context.goNamed('home'),
        ),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }

  /// 统一认证登录成功后的余额刷新入口：登录弹窗以 true 返回就是「已登录」的
  /// 直接凭据，此刻起恰好欠一次并立即发出余额拉取（弹窗内的重复认证通知
  /// 再也作废不了它）；期间 [_onAuthChanged] 的身份推进拉取（account+
  /// sessionRevision）被弹窗推迟，也在这里收口成同一次——[_pullEpoch] 已
  /// 推进（弹窗外已有拉取覆盖）才不重复。登录通知先来后来、账号何时就绪
  /// 都不悬空。
  Future<void> _handleLogin() async {
    final pullEpochAtOpen = _pullEpoch;
    _loginModalDepth++;
    final bool loggedIn;
    try {
      loggedIn = await showUnifiedAuthLoginModal(
        context,
        title: '登录统一认证',
        description: '登录后可查询校园卡余额',
      );
    } finally {
      _loginModalDepth--;
    }
    if (!loggedIn || !mounted) return;
    if (_pullEpoch != pullEpochAtOpen) return;
    _pendingLoginPull = true;
    _settlePendingLoginPull();
  }

  /// 余额拉取调度：同身份在途请求去重；跨身份的新拉取排到旧请求结算后补拉
  /// 一次（合并多次排队），旧请求的迟到结果与反馈一律作废。
  Future<void> _refreshBalance({
    bool showFeedback = true,
    bool forceRefresh = true,
  }) async {
    final requestIdentity = _currentIdentity();
    if (_balanceLoading) {
      // 同身份在途请求去重；跨身份（换号 / 同号重登）的拉取绝不能被旧请求
      // 挡掉——合并排队一次，旧请求结算后自动为当前身份补拉。
      if (_inFlightIdentity != requestIdentity) {
        final queued = _queuedRefresh;
        _queuedRefresh = (
          showFeedback: (queued?.showFeedback ?? false) || showFeedback,
          forceRefresh: (queued?.forceRefresh ?? false) || forceRefresh,
        );
      }
      return;
    }
    setState(() => _balanceLoading = true);
    _inFlightIdentity = requestIdentity;

    double? balance;
    try {
      balance = await CampusCardService.instance.fetchBalance(
        forceRefresh: forceRefresh,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新异常',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final queued = _queuedRefresh;
    _queuedRefresh = null;
    _inFlightIdentity = null;
    if (!mounted) return;
    // 页面层独立判定结果过期（不只依赖服务端丢弃）：身份已推进时，旧请求
    // 的成功 / 失败反馈一律作废，不得覆盖新身份的 UI 与提示。
    final resultStale = requestIdentity != _currentIdentity();
    if (queued != null) {
      // 新身份拉取排在旧请求之后：旧反馈作废，立即为当前身份补拉一次，
      // loading 保持连续。
      setState(() => _balanceLoading = false);
      unawaited(
        _refreshBalance(
          showFeedback: queued.showFeedback,
          forceRefresh: queued.forceRefresh,
        ),
      );
      return;
    }
    setState(() => _balanceLoading = false);
    // 无明确 owner 的迟到补拉（排队期间已登出）静默结束，不在登录门上弹提示。
    if (!showFeedback || resultStale || requestIdentity.account == null) return;
    _showRefreshFeedback(balance);
  }

  /// 刷新结果反馈文案：区分「有余额在手（保留旧值）」与「完全无余额」两种
  /// 失败语气；成功只说已刷新。
  void _showRefreshFeedback(double? balance) {
    final cached = CampusCardService.instance.cachedBalance;
    final failure = CampusCardService.instance.lastBalanceFailure;
    final String message;
    if (balance != null) {
      message = '校园卡余额已刷新';
    } else if (cached != null) {
      message = switch (failure) {
        BalanceFailureKind.authRequired => '请先登录统一认证，再查询校园卡余额',
        BalanceFailureKind.authExpired => '登录已失效，请重新登录统一认证',
        BalanceFailureKind.serviceUnavailable => '刷新失败，仍显示上次余额，请稍后重试',
        BalanceFailureKind.network => '刷新失败，仍显示上次余额，请切换网络后重试',
        BalanceFailureKind.none => '刷新失败，仍显示上次余额，请稍后重试',
      };
    } else {
      message = switch (failure) {
        BalanceFailureKind.authRequired => '请先登录统一认证，再查询校园卡余额',
        BalanceFailureKind.authExpired => '登录已失效，请重新登录统一认证',
        BalanceFailureKind.serviceUnavailable => '一卡通服务暂时不可用，请稍后重试',
        BalanceFailureKind.network => '网络不可用，请检查网络后重试',
        BalanceFailureKind.none => '暂未获取到校园卡余额，请稍后重试',
      };
    }
    AppFeedback.toast(context, message);
  }

  Future<void> _openRechargePage() async {
    if (!mounted) return;
    await CampusActionExecutor.instance.executeWechat(
      context,
      url: AppConfig.xiaofubaoRechargeUri.toString(),
      title: '一卡通充值',
      successMessage: '已请求打开微信，若未直达请复制链接在微信中完成充值',
      failureMessage: '未能拉起微信，充值链接已复制，请在微信中粘贴打开',
      autoCopyOnFailure: true,
    );
  }

  Future<void> _requestPaymentShortcut() async {
    final result = await AppShortcutService.instance
        .requestCampusCardPaymentShortcutResult();
    if (!mounted) return;

    AppFeedback.toast(
      context,
      result.message,
      actionLabel: result.canOpenPermissionSettings ? '去设置' : null,
      onAction: result.canOpenPermissionSettings
          ? AppShortcutService.instance.openShortcutPermissionSettings
          : null,
    );
  }
}

// ── Campus Card Action ──────────────────────────────────────────────────────

enum _CampusCardMenuAction { refresh, addShortcut }
