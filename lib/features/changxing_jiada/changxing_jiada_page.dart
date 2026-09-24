import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/unified_auth.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_service.dart';
import 'changxing_jiada_widgets.dart';

/// 首屏数据快照：与 [ChangxingJiadaService] 的三个拉取一一对应。
typedef ChangxingDashboardSnapshot = ({
  ChangxingUserProfile profile,
  int unreadCount,
  List<ChangxingApplication> applications,
});

/// 测试注入（为空时走 [ChangxingJiadaService.instance]）：会话恢复返回是否已有
/// token；CAS 登录内部仍做完整 CAS/WebVPN/token 校验。
typedef ChangxingSessionRestorer = Future<bool> Function();
typedef ChangxingCasLogin = Future<void> Function();
typedef ChangxingSignOut = Future<void> Function();
typedef ChangxingDashboardFetcher =
    Future<ChangxingDashboardSnapshot> Function();

/// 入口提示态：需要登录（原生统一认证）或可重试的失败态。
enum _EntryPrompt {
  signedOut, // 已退出登录
  cancelled, // 用户取消了统一认证登录弹窗
  needLogin, // 明确需要一卡通统一认证（会话缺失或 CAS 判定未认证）
  sessionExpired, // 畅行业务 token 明确过期（服务端 500001）
  loginFailed, // 登录失败（业务/网络原因），可重试登录
  loadFailed, // 登录会话仍在但数据加载失败，只重试加载
}

/// 畅行嘉大主页面（精简入口流）。
///
/// 单一稳定 Scaffold + 内联状态，无全屏加载页/登录中间页整屏切换：
/// * 已有归属当前统一认证账号的 token：直接内联加载仪表盘（四类业务入口 +
///   我的申请）；token 归属 / 会话 revision 不符时一律视为没有 token；
/// * 监听统一认证变化：登出 / 换号 / 同账号新 revision 立即清空
///   profile 与申请，并用 generation + 身份戳作废在途仪表盘响应，绝不渲染
///   上一个账号的数据；
/// * 新身份就绪：先尝试复用归属该身份的持久 token，没有才走 CAS 登录，
///   该路径不弹统一认证弹窗，避免监听回调成环；
/// * 明确未统一认证：直接弹原生统一认证登录 [showUnifiedAuthLoginModal]，登录
///   成功自动继续到仪表盘，不要求再点一次；CAS 判定未认证最多弹一次，不循环；
/// * 网络未知失败不弹登录框（≠认证失效），停在 [AppErrorView] 单次重试；
/// * 严禁 CAS H5 登录页、严禁后台自动登录、不清理全局 Cookie。
class ChangxingJiadaPage extends StatefulWidget {
  const ChangxingJiadaPage({
    super.key,
    this.sessionRestorer,
    this.casLogin,
    this.signOut,
    this.dashboardFetcher,
  });

  static const titleText = '畅行嘉大';

  /// 以下均为测试注入；为空时走 [ChangxingJiadaService.instance]。
  final ChangxingSessionRestorer? sessionRestorer;
  final ChangxingCasLogin? casLogin;
  final ChangxingSignOut? signOut;
  final ChangxingDashboardFetcher? dashboardFetcher;

  @override
  State<ChangxingJiadaPage> createState() => _ChangxingJiadaPageState();
}

class _ChangxingJiadaPageState extends State<ChangxingJiadaPage> {
  bool _connecting = true;
  bool _loadingContent = false;
  bool _entryBusy = false;
  _EntryPrompt? _prompt;
  String? _promptDetail;
  String? _error;

  ChangxingUserProfile? _profile;
  int _unreadCount = 0;
  List<ChangxingApplication> _applications = [];

  /// 当前展示仪表盘归属的 CAS 账号与 `sessionRevision`（页内身份戳）：
  /// 两者与实时统一认证身份不一致时，任何 profile/申请都不得渲染。
  String? _dashboardOwner;
  int _dashboardRevision = 0;

  /// 仪表盘抓取代际：身份变化 / 新抓取时递增，只接纳最新一代结果。
  int _dashboardGeneration = 0;

  /// 最近一次监听到的统一认证身份；用于区分「身份真的变化」与重复通知。
  String? _observedOwner;
  int _observedRevision = 0;

  ChangxingJiadaService get _service => ChangxingJiadaService.instance;

  /// 当前明确的统一认证账号；未登录 / 空白账号一律为 null。
  String? get _currentOwner {
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn) return null;
    final account = auth.currentAccount?.trim();
    return (account == null || account.isEmpty) ? null : account;
  }

  /// 仪表盘数据必须同时满足：已有 profile、归属账号仍是当前账号、
  /// 且抓取时的 `sessionRevision` 未漂移。监听时序异常时也不渲染错身份数据。
  bool get _loggedIn {
    if (_profile == null) return false;
    final owner = _currentOwner;
    if (owner == null) return false;
    return _dashboardOwner == owner &&
        _dashboardRevision == UnifiedAuthService.instance.sessionRevision;
  }

  /// 捕获的身份（owner + revision）是否仍是当前实时身份。
  bool _isLiveIdentity(String owner, int revision) {
    final auth = UnifiedAuthService.instance;
    return auth.isLoggedIn &&
        _currentOwner == owner &&
        auth.sessionRevision == revision;
  }

  bool _hasDashboardFor(String owner, int revision) =>
      _profile != null &&
      _dashboardOwner == owner &&
      _dashboardRevision == revision;

  void _observeCurrentIdentity() {
    _observedOwner = _currentOwner;
    _observedRevision = UnifiedAuthService.instance.sessionRevision;
  }

  int get _pendingCount => _applications
      .where((item) => item.status == 0 || item.status == 1 || item.status == 5)
      .length;

  ChangxingApplication? get _latestApplication {
    if (_applications.isEmpty) return null;
    final sorted = [..._applications]
      ..sort((a, b) {
        final left =
            a.upTime ?? a.startTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right =
            b.upTime ?? b.startTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    return sorted.first;
  }

  @override
  void initState() {
    super.initState();
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
    _observeCurrentIdentity();
    _initialize();
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onUnifiedAuthChanged);
    super.dispose();
  }

  /// 统一认证身份变化：登出 / A→B / 同账号新 revision 立即清空页面数据，
  /// 并作废所有在途抓取（generation + 身份戳双重守卫）。
  void _onUnifiedAuthChanged() {
    if (!mounted) return;
    final owner = _currentOwner;
    final revision = UnifiedAuthService.instance.sessionRevision;

    if (owner == null) {
      if (_observedOwner == null && _observedRevision == revision) return;
      _observedOwner = null;
      _observedRevision = revision;
      _applySignedOut();
      return;
    }
    if (_observedOwner == owner && _observedRevision == revision) return;
    _observedOwner = owner;
    _observedRevision = revision;
    _applyIdentityChanged();
  }

  /// 登出 / 身份不可信：页面立即停止展示任何账号数据。
  void _applySignedOut() => _resetPageState(prompt: _EntryPrompt.signedOut);

  /// 新身份（换号 / 同账号新 revision / 首次登录）：清空旧数据后有界进入。
  void _applyIdentityChanged() {
    _resetPageState(prompt: null);
    // 该路径由监听回调触发，绝不再弹统一认证弹窗（避免成环）：
    // 先复用绑定当前身份的持久 token，没有才走一次 CAS SSO。
    unawaited(_signIn(allowUnifiedAuthPrompt: false));
  }

  /// 清空页面数据并作废所有在途抓取（generation + 身份戳双重守卫）；
  /// [prompt] 为 null 表示等待新身份的有界进入，否则展示该提示态。
  void _resetPageState({required _EntryPrompt? prompt}) {
    _dashboardGeneration++;
    setState(() {
      _connecting = prompt == null;
      _loadingContent = false;
      _profile = null;
      _dashboardOwner = null;
      _dashboardRevision = 0;
      _applications = [];
      _unreadCount = 0;
      _error = null;
      _prompt = prompt;
      _promptDetail = null;
    });
  }

  Future<void> _initialize() async {
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn) {
      // 进入页面时统一认证身份可能尚未从本地恢复：先做一次本地身份恢复
      // （无网络、不同步 WebView Cookie）。token 的归属校验依赖可信身份，
      // 身份未就绪时 restoreSession 不会标记已恢复，之后仍可重试。
      try {
        await auth.restoreSession(syncWebViewCookies: false);
      } catch (_) {
        // 本地身份恢复失败按未登录处理，不阻断页面。
      }
      if (!mounted) return;
    }
    if (_loggedIn) {
      setState(() => _connecting = false);
      return;
    }
    // FR-5：无可信身份 / 无 token 时不显示"一键登录"中间页，直接进入登录流程。
    await _signIn();
  }

  Future<bool> _restoreSession() async {
    final restorer = widget.sessionRestorer;
    if (restorer != null) return restorer();
    await _service.restoreSession();
    return _service.hasToken;
  }

  Future<void> _loginViaCas() {
    return widget.casLogin?.call() ?? _service.loginViaCas();
  }

  Future<ChangxingDashboardSnapshot> _fetchDashboard() async {
    final fetcher = widget.dashboardFetcher;
    if (fetcher != null) return fetcher();
    final results = await Future.wait<dynamic>([
      _service.fetchUserProfile(),
      _service.fetchUnreadCount(),
      _service.fetchApplications(),
    ]);
    return (
      profile: results[0] as ChangxingUserProfile,
      unreadCount: results[1] as int,
      applications: results[2] as List<ChangxingApplication>,
    );
  }

  /// 登录入口：一次用户动作最多弹一次统一认证登录弹窗。
  Future<void> _signIn({bool allowUnifiedAuthPrompt = true}) async {
    if (_entryBusy) return;
    _entryBusy = true;
    try {
      await _runSignIn(allowUnifiedAuthPrompt: allowUnifiedAuthPrompt);
    } finally {
      _releaseEntryBusy();
    }
  }

  Future<void> _runSignIn({required bool allowUnifiedAuthPrompt}) async {
    if (!mounted) return;
    setState(() {
      _connecting = true;
      _prompt = null;
      _promptDetail = null;
    });

    // 明确未认证（统一认证会话缺失）：不再走注定失败的 CAS 链路，直接原生登录。
    if (allowUnifiedAuthPrompt && !UnifiedAuthService.instance.isLoggedIn) {
      await _promptUnifiedLogin();
      return;
    }

    final owner = _currentOwner;
    if (owner == null) {
      // 身份不可信：不发起无归属的 CAS 登录。
      if (allowUnifiedAuthPrompt) {
        await _promptUnifiedLogin();
      } else {
        _showPrompt(_EntryPrompt.needLogin, detail: '统一认证未生效，请重新登录后再试');
      }
      return;
    }
    final revision = UnifiedAuthService.instance.sessionRevision;

    try {
      // 已存在归属当前身份的持久 token 时跳过 CAS SSO，直接加载仪表盘。
      final hasSession = await _restoreSession();
      if (!mounted) return;
      if (!_isLiveIdentity(owner, revision)) return;
      if (!hasSession) {
        await _loginViaCas();
        if (!mounted) return;
        if (!_isLiveIdentity(owner, revision)) return;
      }
      await _loadDashboard(fromEntry: true);
    } on ChangxingNeedUnifiedAuthException {
      if (!mounted || !_isLiveIdentity(owner, revision)) return;
      if (allowUnifiedAuthPrompt) {
        // 明确的认证失效信号：弹一次原生统一认证登录。
        await _promptUnifiedLogin();
      } else {
        // 重试后仍是明确未认证：有界停止，不再循环弹窗。
        _showPrompt(_EntryPrompt.needLogin, detail: '统一认证未生效，请重新登录后再试');
      }
    } on ChangxingCasLoginException catch (e) {
      // 业务侧明确失败：不弹登录框（网络未知 ≠ 认证失效）。
      if (!mounted || !_isLiveIdentity(owner, revision)) return;
      _showPrompt(_EntryPrompt.loginFailed, detail: e.message);
    } catch (_) {
      // 网络未知失败：有界回退到单次重试态，不弹登录框。
      if (!mounted || !_isLiveIdentity(owner, revision)) return;
      _showPrompt(_EntryPrompt.loginFailed);
    }
  }

  Future<void> _promptUnifiedLogin() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '畅行嘉大仅支持校园网内直连访问，请连接校园网后完成统一认证',
    );
    if (!mounted) return;
    if (!loggedIn) {
      _showPrompt(_EntryPrompt.cancelled);
      return;
    }
    // 登录成功后自动继续到仪表盘，不再要求用户点第二次。
    await _runSignIn(allowUnifiedAuthPrompt: false);
  }

  void _showPrompt(_EntryPrompt prompt, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _prompt = prompt;
      _promptDetail = detail;
    });
  }

  /// 提示态动作：加载失败只重试加载，其余重走登录流程。
  Future<void> _retryFromPrompt() async {
    if (_entryBusy) return;
    if (_prompt != _EntryPrompt.loadFailed) {
      await _signIn();
      return;
    }
    _entryBusy = true;
    try {
      setState(() {
        _connecting = true;
        _prompt = null;
        _promptDetail = null;
      });
      await _loadDashboard(fromEntry: true);
    } finally {
      _releaseEntryBusy();
    }
  }

  /// 释放入口忙碌标记：当前身份若还没有终态页面状态（仪表盘 / 明确提示），
  /// 为它续走一次有界进入；否则收敛到非连接态，绝不留空白页。
  void _releaseEntryBusy() {
    _entryBusy = false;
    if (!mounted) return;
    final owner = _currentOwner;
    final revision = UnifiedAuthService.instance.sessionRevision;
    final needsEntry =
        owner != null && !_hasDashboardFor(owner, revision) && _prompt == null;
    if (needsEntry) {
      unawaited(_signIn(allowUnifiedAuthPrompt: false));
    } else {
      setState(() => _connecting = false);
    }
  }

  Future<void> _loadDashboard({
    bool fromEntry = false,
    bool showGlobalLoading = false,
  }) async {
    final owner = _currentOwner;
    if (owner == null) {
      // 无明确身份：不发起抓取（fail closed），不把任何结果当成本会话数据。
      if (fromEntry) {
        _showPrompt(_EntryPrompt.needLogin, detail: '统一认证未生效，请重新登录后再试');
      }
      return;
    }
    final revision = UnifiedAuthService.instance.sessionRevision;
    final generation = ++_dashboardGeneration;

    if (showGlobalLoading && mounted) {
      setState(() => _loadingContent = true);
    }

    try {
      final snapshot = await _fetchDashboard();
      if (!_acceptDashboard(generation, owner, revision)) return;
      setState(() {
        _profile = snapshot.profile;
        _unreadCount = snapshot.unreadCount;
        _applications = snapshot.applications;
        _dashboardOwner = owner;
        _dashboardRevision = revision;
        _prompt = null;
        _promptDetail = null;
        _error = null;
      });
    } on ChangxingAuthExpiredException catch (e) {
      // 明确的业务 token 过期：回到「重新登录」提示，不自动循环弹窗。
      // 迟到的过期结果只对发起时的身份有效，换号 / 重登后不得影响新会话。
      if (!_acceptDashboard(generation, owner, revision)) return;
      setState(() {
        _connecting = false;
        _profile = null;
        _dashboardOwner = null;
        _dashboardRevision = 0;
        _applications = [];
        _unreadCount = 0;
        _prompt = _EntryPrompt.sessionExpired;
        _promptDetail = e.message;
        _error = null;
      });
    } catch (e) {
      if (!_acceptDashboard(generation, owner, revision)) return;
      if (fromEntry) {
        _showPrompt(_EntryPrompt.loadFailed, detail: '数据加载失败，请稍后重试');
      } else {
        setState(() => _error = '加载数据失败：$e');
      }
    } finally {
      if (mounted && generation == _dashboardGeneration) {
        setState(() => _loadingContent = false);
      }
    }
  }

  /// 只接纳「最新一代 + 发起时身份仍是当前身份」的仪表盘结果。
  bool _acceptDashboard(int generation, String owner, int revision) {
    if (!mounted || generation != _dashboardGeneration) return false;
    return _isLiveIdentity(owner, revision);
  }

  Future<void> _logout() async {
    await (widget.signOut ?? _service.logout)();
    if (!mounted) return;
    // 显式登出只清畅行 token，统一认证身份可能仍在：记录当前身份，
    // 避免随后同身份的重复通知把用户自动带回仪表盘。
    _observeCurrentIdentity();
    _applySignedOut();
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = _loggedIn;
    // 单一稳定 Scaffold：只交换 body（内联连接态 / 提示态 / 仪表盘），无整屏切换。
    // profile 存在但身份戳不符（监听时序异常）时也按连接态 fail closed，
    // 绝不把上一个身份的 profile / 申请渲染给当前会话。
    return Scaffold(
      appBar: AppAppBar(
        title: Text(
          ChangxingJiadaPage.titleText,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        actions: loggedIn
            ? [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loadingContent
                      ? null
                      : () => _loadDashboard(showGlobalLoading: true),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                IconButton(
                  tooltip: '退出登录',
                  onPressed: _logout,
                  icon: const Icon(Icons.logout, size: 20),
                ),
              ]
            : null,
      ),
      body: loggedIn
          ? _buildDashboardBody()
          : (_connecting || _profile != null)
          ? _buildConnectingBody()
          : _buildPromptBody(),
    );
  }

  /// 内联连接态：安静的小指示器，替代原先的整屏加载 Scaffold。
  Widget _buildConnectingBody() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: 14),
                Text(
                  '正在连接校园通行服务…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 提示态：需要登录 → [AuthRequiredView]；失败可重试 → [AppErrorView]（两者自带统一入场动画，不再叠加过渡）。
  Widget _buildPromptBody() {
    final detail = _promptDetail;
    void onRetry() => _retryFromPrompt();
    final signedOut = _prompt == _EntryPrompt.signedOut;
    if (signedOut || _prompt == _EntryPrompt.cancelled) {
      return AuthRequiredView(
        title: signedOut ? '已退出登录' : '已取消登录',
        message: signedOut ? '退出后重新登录可继续办理' : '登录一卡通统一认证后即可继续办理',
        buttonLabel: '登录',
        onAction: onRetry,
      );
    }
    return switch (_prompt) {
      _EntryPrompt.needLogin => AuthRequiredView(
        title: '需要登录一卡通',
        message: detail ?? '畅行嘉大需要校园网环境，请完成一卡通统一认证',
        buttonLabel: '登录',
        onAction: onRetry,
      ),
      _EntryPrompt.sessionExpired => AuthRequiredView(
        title: '登录已失效',
        message: detail ?? '畅行嘉大登录已失效，请重新登录',
        buttonLabel: '重新登录',
        onAction: onRetry,
      ),
      _EntryPrompt.loginFailed => AppErrorView(
        title: '登录失败',
        message: detail ?? '登录未完成，请稍后重试',
        retryLabel: '重试',
        onRetry: onRetry,
      ),
      _EntryPrompt.loadFailed => AppErrorView(
        title: '加载失败',
        message: detail ?? '数据加载失败，请稍后重试',
        retryLabel: '重试',
        onRetry: onRetry,
      ),
      // 不可达：_connecting 与 _loggedIn 优先，signedOut/cancelled 已在上方返回。
      _ => const SizedBox.shrink(),
    };
  }

  Widget _buildDashboardBody() {
    final profile = _profile!;

    return RefreshIndicator(
      onRefresh: () => _loadDashboard(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _buildProfileCard(profile),
          const SizedBox(height: 22),
          ChangxingSectionHeading(
            title: '快速办理',
            trailing: '${ChangxingFormType.values.length} 项',
          ),
          const SizedBox(height: 10),
          _buildActionCard(),
          const SizedBox(height: 22),
          ChangxingSectionHeading(
            title: '我的申请',
            trailing: '${_applications.length} 条',
          ),
          if ((_error ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            ChangxingErrorBanner(message: _error!),
          ],
          const SizedBox(height: 10),
          if (_loadingContent && _applications.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_applications.isEmpty)
            const ChangxingEmptyApplications()
          else
            for (final item in _applications) ...[
              _buildApplicationCard(item),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _buildProfileCard(ChangxingUserProfile profile) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final trimmedName = profile.name.trim();
    final initial = trimmedName.isEmpty ? '通' : trimmedName.substring(0, 1);
    final latest = _latestApplication;

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  initial,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trimmedName.isEmpty ? '未命名用户' : trimmedName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      profile.jobNo.isEmpty ? '学号未同步' : profile.jobNo,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ChangxingInfoGrid(
            items: [
              (
                label: '联系电话',
                value: profile.phone.isEmpty ? '—' : profile.phone,
              ),
              (
                label: '紧急联系人',
                value: profile.emergencyContact.isEmpty
                    ? '—'
                    : '${profile.emergencyContact}  ${profile.emergencyPhone}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ChangxingMetric(value: _unreadCount, label: '未读消息'),
              ),
              const _MetricDivider(),
              Expanded(
                child: ChangxingMetric(value: _pendingCount, label: '办理中'),
              ),
              const _MetricDivider(),
              Expanded(
                child: ChangxingMetric(
                  value: _applications.length,
                  label: '申请总数',
                ),
              ),
            ],
          ),
          if (latest != null) ...[
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '最近申请',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${latest.typeLabel} · ${latest.statusLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (latest.upTime != null)
                  Text(
                    _fmt(latest.upTime),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard() {
    final cs = Theme.of(context).colorScheme;
    final actions = ChangxingFormType.values;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            ChangxingActionRow(
              icon: _actionIcon(actions[i]),
              title: actions[i].actionLabel,
              hint: _actionHint(actions[i]),
              onTap: () => _openForm(actions[i]),
            ),
            if (i < actions.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                indent: 64,
                endIndent: 16,
                color: cs.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildApplicationCard(ChangxingApplication item) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = _statusColor(cs, item.status);

    final specs = <({String label, String value})>[
      if (item.departmentName.isNotEmpty)
        (label: '班级', value: item.departmentName),
      if (item.userJobNo.isNotEmpty) (label: '学号', value: item.userJobNo),
      if (item.userPhone.isNotEmpty) (label: '电话', value: item.userPhone),
      if (item.startTime != null) (label: '开始', value: _fmt(item.startTime)),
      if (item.endTime != null) (label: '结束', value: _fmt(item.endTime)),
      if (item.trafficTool.isNotEmpty) (label: '交通', value: item.trafficTool),
      if (item.shouldShowRemark) (label: '审批', value: item.remark),
      if (item.type == 3 && item.backStatus != 0) ...[
        if (item.emergencyContact.isNotEmpty)
          (label: '紧急联系人', value: item.emergencyContact),
        if (item.emergencyPhone.isNotEmpty)
          (label: '联系人电话', value: item.emergencyPhone),
        if (item.notBackReason.isNotEmpty)
          (label: '不返校原因', value: item.notBackReason),
      ],
      if (item.upTime != null) (label: '更新', value: _fmt(item.upTime)),
    ];

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIconBadge(
                icon: _actionIcon(
                  item.formType ?? ChangxingFormType.leaveRequest,
                ),
                accentColor: color,
                size: AppIconBadgeSize.medium,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.typeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.userName.isEmpty ? '未知用户' : item.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ChangxingStatusChip(label: item.statusLabel, color: color),
            ],
          ),
          if (specs.isNotEmpty) ...[
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            const SizedBox(height: 14),
            ChangxingInfoGrid(items: specs),
          ],
          if (item.descr.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              item.descr,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (item.canEdit) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () {
                  final type = item.formType;
                  if (type == null) return;
                  _openForm(type, applicationId: item.id);
                },
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('编辑申请'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _actionHint(ChangxingFormType action) {
    switch (action) {
      case ChangxingFormType.leaveRequest:
        return '临时请假';
      case ChangxingFormType.leaveSchool:
        return '离校出行';
      case ChangxingFormType.backSchool:
        return '返校确认';
      case ChangxingFormType.overtime:
        return '晚归补登';
    }
  }

  IconData _actionIcon(ChangxingFormType action) {
    switch (action) {
      case ChangxingFormType.leaveRequest:
        return Icons.event_note_outlined;
      case ChangxingFormType.leaveSchool:
        return Icons.directions_walk_outlined;
      case ChangxingFormType.backSchool:
        return Icons.how_to_reg_outlined;
      case ChangxingFormType.overtime:
        return Icons.schedule_outlined;
    }
  }

  Future<void> _openForm(
    ChangxingFormType formType, {
    int? applicationId,
  }) async {
    final Map<String, dynamic> query = applicationId == null
        ? <String, dynamic>{}
        : <String, dynamic>{'id': '$applicationId'};
    final result = await context.pushNamed<bool>(
      formType.routeName,
      queryParameters: query,
    );
    if (result == true && mounted) {
      await _loadDashboard();
    }
  }

  Color _statusColor(ColorScheme cs, int status) {
    switch (status) {
      case 0:
      case 1:
        return cs.tertiary;
      case 2:
        return cs.error;
      case 3:
        return cs.onSurfaceVariant;
      case 4:
      case 6:
        return cs.primary;
      case 5:
        return cs.secondary;
      default:
        return cs.onSurfaceVariant;
    }
  }

  String _fmt(DateTime? dateTime) {
    if (dateTime == null) return '-';
    final local = dateTime.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
