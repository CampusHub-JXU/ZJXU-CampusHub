import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/actions/campus_action_executor.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/config/app_config.dart';
import '../../core/logging/app_logger.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_tile_surface.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';

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
    final revision = auth.sessionRevision;
    if (!auth.isLoggedIn) return (account: null, revision: revision);
    final account = auth.currentAccount?.trim();
    if (account == null || account.isEmpty) {
      return (account: null, revision: revision);
    }
    return (account: account, revision: revision);
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
    // 身份推进（换号 / 同号重登推进 sessionRevision）：立即自动拉一次余额，
    // 无需用户再点查询；登出、身份未知、同一 revision 的重复通知都不拉。
    // 用微任务延到本次通知广播结束再拉——服务端监听器会先清缓存、推进身份
    // 世代，拉取捕获到的才是新身份上下文。
    if (identity.account != null &&
        (identity.account != previous.account ||
            identity.revision != previous.revision)) {
      unawaited(Future<void>.microtask(_pullBalanceAfterLogin));
    }
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
        actions: [
          if (!authRequired)
            IconButton(
              tooltip: '刷新余额',
              onPressed: _balanceLoading ? null : _refreshBalance,
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (isAndroid)
            PopupMenuButton<_CampusCardMenuAction>(
              tooltip: '更多操作',
              onSelected: (action) {
                switch (action) {
                  case _CampusCardMenuAction.addShortcut:
                    _requestPaymentShortcut();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem<_CampusCardMenuAction>(
                  value: _CampusCardMenuAction.addShortcut,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.add_to_home_screen_outlined),
                    title: Text('添加至桌面'),
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
          _buildBalanceCard(context, balance, lastUpdated),
          const SizedBox(height: AppSpacing.lg),
          _buildActionTile(
            context,
            icon: Icons.qr_code_2_outlined,
            title: '付款码',
            subtitle: '出示一卡通二维码快速付款',
            onTap: _openPaymentCodePage,
          ),
          const SizedBox(height: AppSpacing.md),
          _buildActionTile(
            context,
            icon: Icons.receipt_long_outlined,
            title: '账单',
            subtitle: '查看校园卡消费明细',
            onTap: () => _openCampusCardWebView(title: '校园卡账单'),
          ),
          const SizedBox(height: AppSpacing.md),
          _buildActionTile(
            context,
            icon: Icons.add_card_outlined,
            title: '充值',
            subtitle: '在微信服务号内完成充值',
            onTap: _openRechargePage,
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _refreshBalance,
              icon: _balanceLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: Text(_balanceLoading ? '正在刷新' : '刷新余额'),
            ),
          ),
        ],
      ),
    );
  }

  // ── Balance Card ────────────────────────────────────────────────────────

  Widget _buildBalanceCard(
    BuildContext context,
    double? balance,
    DateTime? lastUpdated,
  ) {
    final cs = Theme.of(context).colorScheme;
    final balanceText = balance != null ? balance.toStringAsFixed(2) : '--';
    final timeText = lastUpdated != null
        ? '${lastUpdated.month}/${lastUpdated.day} '
              '${lastUpdated.hour.toString().padLeft(2, '0')}:'
              '${lastUpdated.minute.toString().padLeft(2, '0')} 更新'
        : '暂未获取余额';

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
    final failureTone = failureIsSerious
        ? cs.onErrorContainer
        : cs.onSurfaceVariant;
    final failureBackground = failureIsSerious
        ? cs.errorContainer
        : cs.surfaceContainerHighest;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.credit_card_outlined, size: 18, color: cs.primary),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  '校园卡余额',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: _obscured ? '显示余额' : '隐藏余额',
                onPressed: () => setState(() => _obscured = !_obscured),
                icon: Icon(
                  _obscured
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
                iconSize: 20,
                color: cs.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          // 大字号 / 窄屏下金额整体等比缩小，不挤压换行。
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '¥',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    _obscured ? '****' : balanceText,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      letterSpacing: -1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (balance == null) ...[
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
                        style: TextStyle(
                          fontSize: 12,
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
                BalanceFailureKind.authRequired => FilledButton.tonalIcon(
                  onPressed: _balanceLoading ? null : _handleLogin,
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('登录统一认证'),
                ),
                BalanceFailureKind.authExpired => FilledButton.tonalIcon(
                  onPressed: _balanceLoading ? null : _handleLogin,
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('重新登录'),
                ),
                _ => FilledButton.tonalIcon(
                  onPressed: _balanceLoading ? null : _refreshBalance,
                  icon: const Icon(Icons.touch_app_outlined, size: 18),
                  label: Text(_balanceLoading ? '正在查询余额' : '点击查询余额'),
                ),
              },
            ),
          ] else
            Row(
              children: [
                Icon(Icons.schedule, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    timeText,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Action Tiles ────────────────────────────────────────────────────────

  Widget _buildActionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return AppTileSurface(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 13,
      ),
      onTap: onTap,
      child: Row(
        children: [
          AppIconBadge(
            icon: icon,
            accentColor: cs.primary,
            size: AppIconBadgeSize.medium,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ],
      ),
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

  /// 统一认证登录成功后的余额刷新入口：优先由 [_onAuthChanged] 的登录拉取
  /// 覆盖；仅当模态期间身份完全未变（如 authExpired 重登）才显式拉一次。
  Future<void> _handleLogin() async {
    final identityAtOpen = _currentIdentity();
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可查询校园卡余额',
    );
    if (!loggedIn || !mounted) return;
    // 期间身份已推进（含模态内登录成功 / 别处登录 / 同号重登推进 revision）时，
    // _onAuthChanged 的登录拉取已经覆盖，这里不得重复拉；仅当身份完全未变
    //（如 authExpired 重登）才显式拉一次。
    if (_currentIdentity() != identityAtOpen) return;
    unawaited(_pullBalanceAfterLogin());
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
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
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
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openRechargePage() async {
    if (!mounted) return;
    await CampusActionExecutor.instance.executeWechat(
      context,
      url: AppConfig.xiaofubaoRechargeUri.toString(),
      title: '一卡通充值',
      successMessage: '已跳转到微信，请在微信中完成充值',
      failureMessage: '未能打开页面，充值链接已复制，请到微信中打开',
      autoCopyOnFailure: true,
    );
  }

  Future<void> _requestPaymentShortcut() async {
    final result = await AppShortcutService.instance
        .requestCampusCardPaymentShortcutResult();
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.message),
        action: result.canOpenPermissionSettings
            ? SnackBarAction(
                label: '去设置',
                onPressed: () {
                  AppShortcutService.instance.openShortcutPermissionSettings();
                },
              )
            : null,
      ),
    );
  }
}

// ── Campus Card Action ──────────────────────────────────────────────────────

enum _CampusCardMenuAction { addShortcut }
