import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../core/actions/campus_action_executor.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/theme/app_design_tokens.dart';
import 'dorm_electricity_service.dart';
import 'dorm_usage_chart.dart';
import 'dorm_usage_background.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/detail_readout.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_feedback.dart';

/// 页面当前绑定的统一认证身份（账号 + sessionRevision）；未登录 / 空白
/// 账号一律账号 null，与服务 owner 判定保持一致。
typedef _AuthIdentity = ({String? account, int revision});

/// 一次加载 / 预警检查绑定的身份与代际：账号 + sessionRevision + 页面身份
/// 代际 + 加载票据，四者任一变化都让旧请求的迟到结果作废。
typedef _RequestCapture = ({
  String? account,
  int revision,
  int generation,
  int ticket,
});

class DormElectricityPage extends StatefulWidget {
  const DormElectricityPage({super.key});

  @override
  State<DormElectricityPage> createState() => _DormElectricityPageState();
}

class _DormElectricityPageState extends State<DormElectricityPage>
    with WidgetsBindingObserver {
  final _service = DormElectricityService.instance;
  double? _electricity;
  Timer? _usageTimer;
  bool _usageMonitoring = false;
  bool _usageBackgroundEnabled = false;
  bool _usageBackgroundBusy = false;

  Future<void> _setUsageBackground(bool enabled) async {
    if (!mounted ||
        _usageBackgroundBusy ||
        !_hasConfig ||
        _requiresUnifiedAuth) {
      return;
    }
    final identity = _currentIdentity();
    setState(() => _usageBackgroundBusy = true);
    try {
      final actual = await DormUsageBackground.instance.setEnabled(enabled);
      if (mounted && _currentIdentity() == identity) {
        setState(() => _usageBackgroundEnabled = actual);
      }
    } catch (_) {
      if (mounted && _currentIdentity() == identity) {
        setState(() => _usageBackgroundEnabled = false);
        AppFeedback.toast(context, '后台采集设置失败');
      }
    } finally {
      if (mounted && _currentIdentity() == identity) {
        setState(() => _usageBackgroundBusy = false);
      }
    }
  }

  void _stopUsageMonitoring() {
    _usageTimer?.cancel();
    _usageTimer = null;
    _usageMonitoring = false;
  }

  void _setUsageMonitoring(bool enabled) {
    if (!mounted) return;
    if (!enabled) {
      setState(_stopUsageMonitoring);
      return;
    }
    if (_usageMonitoring ||
        !_hasConfig ||
        _requiresUnifiedAuth ||
        _currentIdentity().account == null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() => _usageMonitoring = true);
    _usageTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(_pollUsage());
    });
    // Establish the first real measurement without waiting ten minutes.
    unawaited(_pollUsage());
  }

  Future<void> _pollUsage() async {
    if (!mounted || !_usageMonitoring) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true ||
        !_hasConfig ||
        _requiresUnifiedAuth ||
        _currentIdentity().account == null) {
      setState(_stopUsageMonitoring);
      return;
    }
    if (_loading || _refreshing) return;
    final updated = _service.lastUpdated;
    if (updated != null &&
        DateTime.now().difference(updated) < const Duration(minutes: 10)) {
      return;
    }
    if (!await DormUsageBackground.instance.tryAcquireAutoSamplingSlot()) {
      return;
    }
    if (!mounted || !_usageMonitoring) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true) {
      setState(_stopUsageMonitoring);
      return;
    }
    try {
      await _refresh();
      if (mounted &&
          _usageMonitoring &&
          (_error != null || !_hasConfig || _requiresUnifiedAuth)) {
        setState(_stopUsageMonitoring);
      }
    } catch (error, stackTrace) {
      if (mounted && _usageMonitoring) setState(_stopUsageMonitoring);
      AppLogger.instance.storage(
        LogLevel.warn,
        '耗电监测暂停',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed && _usageMonitoring) {
      setState(_stopUsageMonitoring);
    } else if (state == AppLifecycleState.resumed &&
        DormUsageBackground.instance.available &&
        _hasConfig &&
        !_loading &&
        !_refreshing &&
        ModalRoute.of(context)?.isCurrent == true) {
      // Import background samples without forcing a new network request.
      final identity = _currentIdentity();
      unawaited(
        _service.refreshUsageHistory().then((_) {
          if (mounted && _currentIdentity() == identity) setState(() {});
        }),
      );
    }
  }

  /// 后台加载在途（首帧之后的自动拉取 / 切换寝室）：只驱动状态行小
  /// spinner，绝不整页遮挡（见 design-guidelines 4.5）。
  bool _loading = false;
  bool _refreshing = false;
  bool _hasConfig = false;

  /// 寝室配置是否已确认。首帧有缓存视为已配置直接出数；无缓存时先显示
  /// 骨架，确认未配置后才切空态，不闪一下空态再闪数据。
  bool _configResolved = false;
  bool _requiresUnifiedAuth = false;
  bool _alertEnabled = false;
  double _alertThreshold = DormElectricityService.defaultAlertThreshold;
  String? _error;

  /// 最近一次观察到的统一认证身份：仅用于识别真实的身份推进（登出 /
  /// 换号 / 同号重登推进 sessionRevision），同一身份的重复通知不重复清空。
  _AuthIdentity _lastAuthIdentity = (account: null, revision: 0);

  /// 页面身份代际：每次认证身份变化推进一次。在途加载 / 预警检查捕获的
  /// 代际不一致时，迟到结果一律不落 UI、不发通知。
  int _identityGeneration = 0;

  /// 加载票据：每次 [_load] 递增，只有最新一次加载可以提交 UI。
  int _loadTicket = 0;

  /// 刷新票据：身份变化 / 新刷新接管后，旧刷新的收尾不得清掉新点亮态。
  int _refreshTicket = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastAuthIdentity = _currentIdentity();
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    // 首帧同步读 bootstrap 已恢复的缓存（服务按 owner 过滤），网络只在后台补齐。
    _electricity = _service.cachedElectricity;
    _hasConfig = _electricity != null;
    _configResolved = _hasConfig;
    unawaited(_load(forceRefresh: !_service.hasFreshCache));
  }

  /// 当前已验证的统一认证身份；未登录 / 空白账号视为账号 null（fail closed）。
  _AuthIdentity _currentIdentity() {
    final auth = UnifiedAuthService.instance;
    return (account: auth.verifiedAccount, revision: auth.sessionRevision);
  }

  /// 捕获一次加载 / 预警检查的身份与代际，并领取本次加载票据。
  _RequestCapture _captureRequest() {
    final identity = _currentIdentity();
    return (
      account: identity.account,
      revision: identity.revision,
      generation: _identityGeneration,
      ticket: ++_loadTicket,
    );
  }

  /// 捕获的身份是否仍是当前身份：页面挂载、代际未推进，且账号 +
  /// sessionRevision 均未变化。不看加载票据，因此**同一身份**下更新的加载
  /// 接管时，身份正确的低电量通知仍会下发（服务层已按同一身份判定预警），
  /// 只拦真正的跨账号 / 跨 revision 迟到结果。
  bool _isCaptureIdentityCurrent(_RequestCapture capture) {
    if (!mounted) return false;
    if (capture.generation != _identityGeneration) return false;
    final identity = _currentIdentity();
    return identity.account == capture.account &&
        identity.revision == capture.revision;
  }

  /// 是否仍是当前这次加载：身份未变化，且没有被更新的加载接管。
  bool _isCaptureCurrent(_RequestCapture capture) =>
      _isCaptureIdentityCurrent(capture) && capture.ticket == _loadTicket;

  /// 统一认证身份变化：同步清空旧身份的电量 / 配置 / 错误 / 预警视图（绝不
  /// 出现旧账号值的过渡帧），并使在途请求全部作废；已验证的新身份刷新一次，
  /// 登出 / 身份不完整只回落既有空态，不自动弹登录、不触 WebView。
  void _onAuthChanged() {
    final identity = _currentIdentity();
    final previous = _lastAuthIdentity;
    if (identity.account == previous.account &&
        identity.revision == previous.revision) {
      return;
    }
    _lastAuthIdentity = identity;
    _stopUsageMonitoring();
    _usageBackgroundEnabled = false;
    _usageBackgroundBusy = false;
    _identityGeneration++;
    _loadTicket++;
    _electricity = null;
    _hasConfig = false;
    _error = null;
    _requiresUnifiedAuth = false;
    _alertEnabled = false;
    _alertThreshold = DormElectricityService.defaultAlertThreshold;
    _refreshing = false;
    _loading = identity.account != null;
    // 未登录直接确认「无配置」回落空态；新身份先骨架，等配置结果再定。
    _configResolved = identity.account == null;
    if (!mounted) return;
    setState(() {});
    if (identity.account == null) return;
    // 延到本次认证广播结束后再拉：服务侧监听器先清各自缓存，页面再按新
    // 身份走 owner 门面刷新一次，不复用旧身份的迟到结果。
    unawaited(Future<void>.microtask(_reloadForCurrentIdentity));
  }

  Future<void> _reloadForCurrentIdentity() async {
    if (!mounted) return;
    if (_currentIdentity().account == null) return;
    await _load(forceRefresh: true);
  }

  @override
  void dispose() {
    _stopUsageMonitoring();
    WidgetsBinding.instance.removeObserver(this);
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// 始终非阻塞：进度只由状态行表达。[blocking] 仅用于切换寝室后的首次
  /// 拉取——先清掉旧寝室的读数改显示骨架，绝不把旧房间的值当新房间展示。
  ///
  /// 每个 await 边界都复核捕获的账号 + sessionRevision + 页面代际：认证
  /// 身份变化或出现更新的加载后，旧加载的迟到结果一律不落 UI、不发通知。
  Future<void> _load({bool forceRefresh = false, bool blocking = false}) async {
    if (!mounted) return;
    final capture = _captureRequest();
    setState(() {
      _loading = true;
      if (blocking) _electricity = null;
    });

    final hasConfig = await _service.hasRoomConfig();
    if (!_isCaptureCurrent(capture)) return;
    final alertEnabled = await _service.getAlertEnabled();
    if (!_isCaptureCurrent(capture)) return;
    final alertThreshold = await _service.getAlertThreshold();
    if (!_isCaptureCurrent(capture)) return;

    if (!hasConfig) {
      // 未配置 / 未登录 / 无主配置：回落到既有空态，不保留旧身份的任何
      // 电量 / 错误 / 预警残留。
      setState(() {
        _hasConfig = false;
        _electricity = null;
        _requiresUnifiedAuth = false;
        _error = null;
        _alertEnabled = false;
        _alertThreshold = DormElectricityService.defaultAlertThreshold;
        _configResolved = true;
        _loading = false;
      });
      return;
    }

    _hasConfig = true;
    _configResolved = true;
    _alertEnabled = alertEnabled;
    _alertThreshold = alertThreshold;

    final value = await _service.fetchElectricity(forceRefresh: forceRefresh);
    if (!_isCaptureCurrent(capture)) return;
    _electricity = value;
    _error = _service.lastError;
    _requiresUnifiedAuth = _service.requiresAuthentication;
    await _service.refreshUsageHistory();
    if (!_isCaptureCurrent(capture)) return;
    final backgroundEnabled = await DormUsageBackground.instance.enabled();
    if (!_isCaptureCurrent(capture)) return;
    _usageBackgroundEnabled = backgroundEnabled;

    // 查询失败（网关不健康）时跳过低电量预警，避免紧跟着再发一整轮
    // RPC，把失败面翻倍。
    if (forceRefresh && _error == null) {
      await _service.checkAndAlert(
        onAlert: ({required value, required threshold}) {
          // 回调可能晚于身份推进：只有发起本次检查的身份仍有效才下发通知；
          // 已交付到系统的通知无法撤回，这里只保证绝不带着旧身份发起。
          if (!_isCaptureIdentityCurrent(capture)) return;
          unawaited(
            _showLowElectricityNotification(value: value, threshold: threshold),
          );
        },
      );
      if (!_isCaptureCurrent(capture)) return;
    }

    setState(() => _loading = false);

    // 有读数时刷新失败：保留读数，状态行转「刷新失败」并补一条 SnackBar；
    // 无读数或需登录时由读数下方的横幅承载原因与动作。
    if (!mounted) return;
    if (_error != null && _electricity != null && !_requiresUnifiedAuth) {
      AppFeedback.toast(context, '电量刷新失败');
    }
  }

  /// 手动/下拉刷新：不覆盖内容，只点亮状态行或下拉指示器。
  ///
  /// 刷新自己持票：身份变化或被更新的刷新接管后，旧刷新的 finally 不得把
  /// 新身份的「正在刷新」点亮态清掉。
  Future<void> _refresh() async {
    if (_refreshing) return;
    final ticket = ++_refreshTicket;
    setState(() => _refreshing = true);
    try {
      await _load(forceRefresh: true, blocking: false);
    } finally {
      if (mounted && ticket == _refreshTicket) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _showLowElectricityNotification({
    required double value,
    required double threshold,
  }) async {
    try {
      await AppNotificationService.instance.showNotification(
        id: 100,
        title: '寝室电费不足',
        body:
            '剩余电量 ${_service.formatElectricity(value)} 度，'
            '低于 ${threshold.toInt()} 度阈值，请及时充值',
        payload: 'dorm-electricity',
      );
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '寝室电费低电量通知发送失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 进寝室设置；回来后寝室变了按「切换寝室」清旧读数拉新值，否则后台刷新。
  Future<void> _openSettings() async {
    if (_usageMonitoring) setState(_stopUsageMonitoring);
    final before = (await _service.loadRoomConfig())?.roomId;
    if (!mounted) return;
    await context.pushNamed('dorm-electricity-settings');
    if (!mounted) return;
    final after = (await _service.loadRoomConfig())?.roomId;
    if (!mounted) return;
    unawaited(_load(forceRefresh: true, blocking: before != after));
  }

  Future<void> _openRecharge() async {
    if (_usageMonitoring) setState(_stopUsageMonitoring);
    await CampusActionExecutor.instance.executeWechat(
      context,
      url: DormElectricityService.rechargeUrl,
      title: '电费充值',
      // 电费充值在「嘉大微生活」公众号内；拉起失败复制关键词，用户到
      // 微信「搜一搜」直达公众号（粘链接打不开）。
      searchKeyword: '嘉大微生活',
      successMessage: '已请求打开微信，若未直达请复制关键词到微信「搜一搜」搜索「嘉大微生活」充值',
      failureMessage: '未能拉起微信，「嘉大微生活」已复制，请在微信「搜一搜」粘贴搜索',
      autoCopyOnFailure: true,
    );
  }

  String _statusLabelFor(double value) {
    if (value >= 50) return '充足';
    if (value >= 20) return '适中';
    if (value >= 10) return '偏低';
    return '不足';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('寝室电费'),
        actions: [
          PopupMenuButton<_DormElectricityMenuAction>(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              switch (action) {
                case _DormElectricityMenuAction.refresh:
                  unawaited(_refresh());
                case _DormElectricityMenuAction.chooseRoom:
                  unawaited(_openSettings());
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _DormElectricityMenuAction.refresh,
                child: Text('刷新电量'),
              ),
              PopupMenuItem(
                value: _DormElectricityMenuAction.chooseRoom,
                child: Text('选择寝室'),
              ),
            ],
          ),
        ],
      ),
      body: _configResolved && !_hasConfig
          ? _buildNoConfig(context)
          : RefreshIndicator(
              onRefresh: _refresh,
              child: _buildContent(context, cs),
            ),
    );
  }

  Widget _buildNoConfig(BuildContext context) {
    return AppEmptyView(
      title: '尚未配置寝室',
      message: '选择寝室后即可查看剩余电量',
      icon: Icons.home_outlined,
      actionLabel: '去选择寝室',
      onAction: _openSettings,
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme cs) {
    final value = _electricity;
    final busy = _loading || _refreshing;
    // 骨架只用于「还没有任何读数且正在取」；取数失败则回到 `--` + 横幅。
    final skeleton = value == null && busy;
    // 无读数或需登录时横幅承载原因；有读数的普通失败只走状态行 + SnackBar。
    final showBanner =
        _error != null && (value == null || _requiresUnifiedAuth);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        // 无框读数：数字直接落在页面底色上，比瓦片多缩进 8。
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.sm, top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DetailReadout(
                      label: '剩余电量',
                      valueText: _service.formatElectricity(value),
                      unit: '度',
                      muted: value == null,
                      trailing: _buildStatus(cs, value, skeleton),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (skeleton) const SkeletonBox(height: 6, radius: 3),
                  ],
                ),
              ),
              // 行尾刷新图标自带 44 点按区，不再加右缩进。
              RefreshStatusLine(
                updatedAt: _service.lastUpdated,
                refreshing: busy,
                failed: _error != null,
                prefix: null,
                loadingLabel: '正在获取电量…',
                onRefresh: _refresh,
                refreshTooltip: '刷新电量',
              ),
              if (showBanner)
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.xs,
                    right: AppSpacing.sm,
                  ),
                  child: _buildErrorBanner(),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        DetailActionGrid(
          actions: [
            DetailAction(
              icon: Icons.account_balance_wallet_outlined,
              title: '充值',
              subtitle: '微信',
              onTap: _openRecharge,
              primary: true,
            ),
            DetailAction(
              icon: Icons.notifications_outlined,
              title: '低电提醒',
              subtitle: _alertEnabled
                  ? '低于 ${_alertThreshold.toInt()} 度'
                  : '未开启',
              onTap: _openSettings,
            ),
            DetailAction(
              icon: Icons.home_outlined,
              title: '寝室',
              subtitle: '点按更换',
              onTap: _openSettings,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_hasConfig) ...[
          DormUsageChart(
            points: _service.usagePoints,
            remainingKwh: value,
            currentIntervalValid: _service.usageCurrentIntervalValid,
            monitoring: _usageMonitoring,
            canMonitor: !busy && !_requiresUnifiedAuth,
            refreshFailed: _error != null,
            onMonitoringChanged: _setUsageMonitoring,
            backgroundAvailable: DormUsageBackground.instance.available,
            backgroundEnabled: _usageBackgroundEnabled,
            onBackgroundChanged:
                busy || _usageBackgroundBusy || _requiresUnifiedAuth
                ? null
                : (enabled) => unawaited(_setUsageBackground(enabled)),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Text(
            '下拉可立即刷新；电量 30 分钟内有效，离开页面也会在后台补齐。',
            style: context.appText.meta.copyWith(height: 1.4),
          ),
        ),
      ],
    );
  }

  bool _isLow(double? value) => value != null && value < 20;

  /// 标签行尾的电量状态：小圆点 + 文字，偏低 / 不足转 error 色。
  Widget? _buildStatus(ColorScheme cs, double? value, bool skeleton) {
    if (skeleton) return const SkeletonBox(width: 40, height: 14);
    if (value == null) return null;
    final color = _isLow(value) ? cs.error : cs.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          _statusLabelFor(value),
          style: context.appText.meta.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  // ── Error Banner ───────────────────────────────────────────────────────────

  Widget _buildErrorBanner() {
    // 认证失效保留 error 语义并将登录动作收进紧凑 TextButton；
    // 其余网络/解析错误使用中性底 + 错误色图标承载具体原因。
    final message = _requiresUnifiedAuth
        ? '电费获取失败，登录一卡通后重试'
        : switch (_error) {
            '数据解析失败' => '数据解析失败，请刷新重试',
            final value? => value,
            _ => '请确认已连接校园网络',
          };
    return AppBanner(
      message: message,
      icon: _requiresUnifiedAuth
          ? Icons.lock_outline_rounded
          : Icons.wifi_off_outlined,
      tone: _requiresUnifiedAuth ? AppBannerTone.error : AppBannerTone.neutral,
      actionLabel: _requiresUnifiedAuth ? '登录' : null,
      onAction: _requiresUnifiedAuth ? _loginAndRetry : null,
    );
  }

  Future<void> _loginAndRetry() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '登录一卡通后在后台完成电费认证，当前页面仍保持原生界面',
    );
    if (!mounted || !loggedIn) return;

    await _service.invalidateGatewaySession();
    if (!mounted) return;
    await _load(forceRefresh: true);
  }
}

enum _DormElectricityMenuAction { refresh, chooseRoom }
