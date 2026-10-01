import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/auth/auth_operation_coordinator.dart';
import '../../core/auth/auth_recovery_state_store.dart';
import '../../core/auth/auth_session_persistence.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/widgets/app_wallpaper_backdrop.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_tile_surface.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';

/// 版本号签名到悬浮导航条上缘的留白（底部 inset 已含导航条高度）。
const double _footerDockGap = 12;

/// 磁贴之间的间距，与功能页磁贴网格同值。
const double _tileGap = 10;

/// 状态未知时静默重试的延迟：「未知」不外露，只在后台再测一次。
const Duration _silentRetryDelay = Duration(seconds: 5);

/// 弹出教务登录界面并解析「是否登录成功」，生产默认 [showAcademicSystemLoginModal]。
///
/// 真实 [LoginWidget] 无法离线驱动到登录成功，测试注入替代件以验证
/// 「登录成功后留在本页、不自动跳转」的接线。
typedef AcademicLoginPrompt = Future<bool> Function(BuildContext context);

/// 登出步骤标识：测试经 [MyPage.logoutStepGate] 按步确定性暂停/放行或注入失败。
@visibleForTesting
enum LogoutStep {
  /// 记统一认证域「显式用户登出」（[AuthRecoveryStateStore.recordLogout]）。
  casRecord,

  /// 记教务域「显式用户登出」。
  academicRecord,

  /// 撤销统一认证会话（`UnifiedAuthService.markLoggedOut`）。
  casSession,

  /// 撤销教务会话（`ZhengfangAuth.logout`）。
  academicSession,
}

/// 测试注入点：每个 [LogoutStep] 效果执行前调用；实现可 await 挂起流程、
/// 或抛错注入步骤失败。生产为 null（直通，零行为差异）。
typedef LogoutStepGate = Future<void> Function(LogoutStep step);

class MyPage extends StatefulWidget {
  const MyPage({super.key, this.academicLoginPrompt, this.logoutStepGate});

  /// 测试注入点：替换教务登录弹窗。为 null 时走生产弹窗
  /// [showAcademicSystemLoginModal]，默认行为不变。
  @visibleForTesting
  final AcademicLoginPrompt? academicLoginPrompt;

  /// 测试注入点：登出分步闸门（暂停/放行/注入失败）。生产为 null。
  @visibleForTesting
  final LogoutStepGate? logoutStepGate;

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _campusLoggedIn = false;
  bool _academicLoggedIn = false;
  int _statusRefreshVersion = 0;

  /// 测活网络异常时的一次性静默重试；页面不展示「未知」。
  Timer? _silentRetryTimer;

  /// 登出「确认 + 效果」全流程去重位：进行中的重复点按一律忽略——不叠
  /// 第二个确认框、不跑第二遍登出，行上的登录/导航也暂不受理（避免与
  /// 登出交叠）。只做行为门控，不改视觉。
  bool _logoutBusy = false;

  /// 测试闸门在 initState 捕获一次：登出效果要在页面 dispose 后继续跑完，
  /// 中途不得再触碰 `widget`/`context`。
  LogoutStepGate? _logoutStepGate;

  /// 「关于」行版本号，仅取一次。
  late final Future<PackageInfo> _packageInfoFuture =
      PackageInfo.fromPlatform();

  @override
  void initState() {
    super.initState();
    _logoutStepGate = widget.logoutStepGate;
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    ZhengfangAuth.instance.addListener(_onAuthChanged);
    _refreshStatus();
  }

  @override
  void dispose() {
    _silentRetryTimer?.cancel();
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    ZhengfangAuth.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    unawaited(_refreshStatus());
  }

  /// 先按本地会话渲染，再测活校正。
  ///
  /// 测活返回 null（网络异常，无法下结论）时保持本地会话状态、不外露
  /// 「未知」，并安排一次静默重试；只有测活明确失败才显示为未登录。
  Future<void> _refreshStatus({bool silentRetry = false}) async {
    _silentRetryTimer?.cancel();
    final refreshVersion = ++_statusRefreshVersion;
    final campusLoggedIn = UnifiedAuthService.instance.isLoggedIn;
    final academicLoggedIn = ZhengfangAuth.instance.isLoggedIn;

    setState(() {
      _campusLoggedIn = campusLoggedIn;
      _academicLoggedIn = academicLoggedIn;
    });

    final campusValidationFuture = _validateSafely(
      campusLoggedIn
          ? UnifiedAuthService.instance.validateSession()
          : Future<bool?>.value(false),
    );
    final academicValidationFuture = _validateSafely(
      academicLoggedIn
          ? ZhengfangAuth.instance.validateSession()
          : Future<bool?>.value(false),
    );

    final campusValidation = await campusValidationFuture;
    final academicValidation = await academicValidationFuture;

    if (!mounted || refreshVersion != _statusRefreshVersion) return;

    setState(() {
      _campusLoggedIn =
          campusValidation ?? UnifiedAuthService.instance.isLoggedIn;
      _academicLoggedIn =
          academicValidation ?? ZhengfangAuth.instance.isLoggedIn;
    });

    final unknown = campusValidation == null || academicValidation == null;
    if (unknown && !silentRetry) {
      _silentRetryTimer = Timer(_silentRetryDelay, () {
        if (mounted) unawaited(_refreshStatus(silentRetry: true));
      });
    }
  }

  /// 测活兜底：validateSession 理论上内部吞网络异常返回 null，但部分路径
  /// （如 DioClient 未初始化）仍可能抛出；这里统一归入 null = 无法下结论。
  Future<bool?> _validateSafely(Future<bool?> validation) async {
    try {
      return await validation;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openCampusCardAction() async {
    // 登出进行中不受理行上登录/导航，避免与登出交叠出双身份竞态。
    if (_logoutBusy) return;
    if (!_campusLoggedIn) {
      // 未登录先弹统一认证登录；登录成功后**留在本页**（真机手测反馈），
      // 不再自动 push 一卡通页，只刷新两行登录状态。
      await showUnifiedAuthLoginModal(
        context,
        title: '登录一卡通',
        description: '登录后可查看一卡通余额与账单',
      );
      if (!mounted) return;
      await _refreshStatus();
      return;
    }
    await context.pushNamed('campus-card');
    if (!mounted) return;
    await _refreshStatus();
  }

  /// 教务行动作：已登录直达 H5 门户；未登录先弹教务登录，登录成功后
  /// **留在本页**（真机手测反馈），不再自动继续进门户，只刷新两行登录状态。
  Future<void> _openAcademicAction() async {
    // 登出进行中不受理行上登录/导航，避免与登出交叠出双身份竞态。
    if (_logoutBusy) return;
    if (!_academicLoggedIn) {
      // 未登录先弹教务登录；登录成功与否都停留在本页。
      final prompt = widget.academicLoginPrompt ?? showAcademicSystemLoginModal;
      await prompt(context);
      if (!mounted) return;
      await _refreshStatus();
      return;
    }
    await _openAcademicH5();
  }

  Future<void> _openAcademicH5() async {
    // 受信教务 H5 入口由受保护页面内部 headless 选路（直连 / WebVPN）并同步
    // 本次 mode 的 Cookie；这里不再手工 buildPortalUrl / syncCookiesToWebView，
    // 也不再把裸 URL 传给通用 external-webview。
    if (!mounted) return;
    await context.pushNamed(
      'external-webview',
      extra: {'title': '教务系统', 'academicEntry': true},
    );
    if (!mounted) return;
    await _refreshStatus();
  }

  /// 「退出登录」行：先弹确认框，确认后按固定顺序执行「显式用户登出」。
  ///
  /// 确认 + 登出全程 [_logoutBusy] 去重：进行中的重复点按一律忽略（不叠
  /// 第二个确认框、不跑第二遍登出）。
  Future<void> _promptLogout() async {
    if (_logoutBusy) return;
    _logoutBusy = true;
    try {
      final confirmed = await AppFeedback.confirm(
        context,
        title: '退出登录',
        message: '退出后，统一认证与教务都需要重新登录才能继续使用。',
        confirmLabel: '退出登录',
        cancelLabel: '返回',
        destructive: true,
      );
      // 一旦用户确认，四步效果与 mounted 无关地执行完毕：中途页面被销毁
      // 绝不允许留下「只撤销了一域」的半套登出。
      if (!confirmed) return;
      await _finishLogout();
    } finally {
      _logoutBusy = false;
    }
  }

  /// 失败反馈「重试」入口：整套登出再跑一遍（同样去重）。
  Future<void> _retryLogout() async {
    if (_logoutBusy) return;
    _logoutBusy = true;
    try {
      await _finishLogout();
    } finally {
      _logoutBusy = false;
    }
  }

  /// 执行登出效果并收尾：效果（[_performLogout]）不看 mounted，只有下面的
  /// 状态刷新与反馈属于 UI/context 工作，才用 mounted 门住。
  Future<void> _finishLogout() async {
    final outcome = await _performLogout();
    if (!mounted) return;
    await _refreshStatus();
    if (!mounted) return;
    _showLogoutFeedback(outcome);
  }

  /// 显式用户登出（四步顺序固定，勿改动）：先记两域「显式登出」语义，再撤销会话。
  ///
  /// - **绝不**调用 `logoutWebVpn()`（会 `deleteAll()` 整个统一认证 CookieJar）。
  /// - 每步 best-effort：单步失败记日志并继续后续步骤；失败与跳过都如实回报。
  /// - 「不误杀新登录」：确认时捕获会话指纹（sessionRevision + 身份 + 持久
  ///   epoch），撤销前逐域复核；期间落成新登录（指纹变化）则跳过该域撤销，
  ///   绝不撤销更新的会话。复核必须**同时**在闸门之前和之后各做一次：只在
  ///   闸门之前检查，会让「挂起期间落成的新登录」在闸门放行后被误撤销。
  /// - 四步效果与 mounted 无关；dispose 只影响 UI 收尾，不得中断效果。
  /// - 下游副作用（epay100 / 日历同步 / 桌面组件 / 电费提醒 / 各服务缓存）
  ///   由各自监听器自动收敛，这里不手动触发。
  Future<_LogoutOutcome> _performLogout() async {
    final failures = <String>[];
    final preserved = <String>[];
    final campusAuth = UnifiedAuthService.instance;
    final academicAuth = ZhengfangAuth.instance;

    // 确认时刻的会话指纹：与随后几步 await 之间落成的新登录区分开。
    final casFingerprint = await _captureFingerprint(
      CredentialSessionDomain.unified,
      () => campusAuth.sessionRevision,
      () => campusAuth.isLoggedIn ? campusAuth.currentAccount : null,
    );
    final academicFingerprint = await _captureFingerprint(
      CredentialSessionDomain.academic,
      () => academicAuth.sessionRevision,
      () => academicAuth.isLoggedIn ? academicAuth.currentStudentId : null,
    );

    await _logoutStep(LogoutStep.casRecord, '统一认证显式登出记录', failures, () {
      return AuthOperationCoordinator.instance.recordLogout(
        AuthRecoveryDomain.cas,
        kind: AuthLogoutKind.explicitUserLogout,
      );
    });
    await _logoutStep(LogoutStep.academicRecord, '教务显式登出记录', failures, () {
      return AuthOperationCoordinator.instance.recordLogout(
        AuthRecoveryDomain.academic,
        kind: AuthLogoutKind.explicitUserLogout,
      );
    });

    if (campusAuth.isLoggedIn) {
      final outcome = await _revokeSessionStep(
        LogoutStep.casSession,
        '统一认证会话撤销',
        failures,
        casFingerprint,
        CredentialSessionDomain.unified,
        () => campusAuth.sessionRevision,
        () => campusAuth.isLoggedIn ? campusAuth.currentAccount : null,
        () => campusAuth.markLoggedOut(),
      );
      if (outcome == _RevokeOutcome.preserved) preserved.add('统一认证');
    }
    if (academicAuth.isLoggedIn) {
      final outcome = await _revokeSessionStep(
        LogoutStep.academicSession,
        '教务会话撤销',
        failures,
        academicFingerprint,
        CredentialSessionDomain.academic,
        () => academicAuth.sessionRevision,
        () => academicAuth.isLoggedIn ? academicAuth.currentStudentId : null,
        () => academicAuth.logout(),
      );
      if (outcome == _RevokeOutcome.preserved) preserved.add('教务');
    }
    return _LogoutOutcome(failures: failures, preserved: preserved);
  }

  /// 单步撤销会话（含「不误杀新登录」复核）：
  ///
  /// 1. 闸门**之前**先复核一次指纹——已变化则直接跳过（不进闸门、不执行效果）；
  /// 2. 过闸门（测试可长时间挂起、也可注入失败）；
  /// 3. 闸门放行后**再复核一次**——这是关键补丁：挂起期间可能落成新登录，
  ///    只在闸门之前检查会让新会话被随后的无条件撤销误杀；
  /// 4. 复核通过才执行真正的撤销。
  ///
  /// 闸门/效果抛错 → 记失败并继续后续步骤；复核发现新登录 → 保留（不撤销）。
  Future<_RevokeOutcome> _revokeSessionStep(
    LogoutStep step,
    String label,
    List<String> failures,
    _SessionFingerprint fingerprint,
    CredentialSessionDomain domain,
    int Function() revisionOf,
    String? Function() identityOf,
    Future<void> Function() effect,
  ) async {
    try {
      final unchangedBefore = await _fingerprintUnchanged(
        fingerprint,
        domain,
        revisionOf,
        identityOf,
      );
      if (!unchangedBefore) return _RevokeOutcome.preserved;

      final gate = _logoutStepGate;
      if (gate != null) await gate(step);

      // 闸门之后、真正撤销之前重新校验：这是「持有 gate await 后身份再校验」
      // 的落点，不能只在 await 之前检查。
      final unchangedAfter = await _fingerprintUnchanged(
        fingerprint,
        domain,
        revisionOf,
        identityOf,
      );
      if (!unchangedAfter) return _RevokeOutcome.preserved;

      await effect();
      return _RevokeOutcome.revoked;
    } catch (error, stackTrace) {
      failures.add(label);
      AppLogger.instance.auth(
        LogLevel.warn,
        '「我的」页登出步骤失败（继续后续步骤）：$label',
        error: error,
        stackTrace: stackTrace,
      );
      return _RevokeOutcome.failed;
    }
  }

  /// 单步登出效果的 best-effort 包装：测试闸门 → 执行；失败记日志并计入
  /// [failures]（绝不静默当作成功），且绝不中断后续步骤。
  Future<void> _logoutStep(
    LogoutStep step,
    String label,
    List<String> failures,
    Future<void> Function() effect,
  ) async {
    try {
      final gate = _logoutStepGate;
      if (gate != null) await gate(step);
      await effect();
    } catch (error, stackTrace) {
      failures.add(label);
      AppLogger.instance.auth(
        LogLevel.warn,
        '「我的」页登出步骤失败（继续后续步骤）：$label',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 如实反馈：失败绝不静默当作成功——明示「未完全完成」并给可重试动作；
  /// 跳过新会话撤销也要说明。全部成功时不打扰（两行状态即真实反馈），并
  /// 清掉可能残留的旧失败提示，避免继续宣称「未完全完成」。
  void _showLogoutFeedback(_LogoutOutcome outcome) {
    if (outcome.failures.isEmpty && outcome.preserved.isEmpty) {
      AppFeedback.dismiss(context);
      return;
    }
    final message = <String>[
      if (outcome.failures.isNotEmpty)
        '退出登录未完全完成（${outcome.failures.join('、')}），可重试',
      if (outcome.preserved.isNotEmpty) '登出过程中有新的登录，已保留新会话',
    ].join('；');
    AppFeedback.toast(
      context,
      message,
      actionLabel: outcome.failures.isEmpty ? null : '重试',
      onAction: () => unawaited(_retryLogout()),
    );
  }

  String _statusLabel(bool loggedIn) => loggedIn ? '已登录' : '去登录';

  /// 顶部身份：优先教务学号，其次统一认证账号。
  String? _identity() {
    final academic = ZhengfangAuth.instance;
    if (academic.isLoggedIn) {
      final id = academic.currentStudentId;
      if (id != null && id.isNotEmpty) return id;
    }
    final campus = UnifiedAuthService.instance;
    if (campus.isLoggedIn) {
      final account = campus.currentAccount;
      if (account != null && account.isNotEmpty) return account;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loggedIn = _campusLoggedIn || _academicLoggedIn;
    return Scaffold(
      // 账号 / 设置磁贴的亚克力模糊共用一次背景读取（见 AppTileSurface）。
      body: BackdropGroup(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 与主页 / 功能页同一层壁纸与 Shader 背景，三个 tab 视觉连续。
            const AppWallpaperBackdrop(),
            SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  // 内容不满一屏时撑到视口高度，让 [Spacer] 把底部版本号锚到
                  // 页面底缘；大字号/内容超屏时自然回退为普通滚动。
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          kPlainListGutter,
                          AppSpacing.xl,
                          kPlainListGutter,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _MyHeader(
                              identity: _identity(),
                              onLogout: loggedIn
                                  ? () => unawaited(_promptLogout())
                                  : null,
                            ),
                            const SizedBox(height: AppSpacing.xxl),
                            const _MySectionHeader(),
                            const SizedBox(height: AppSpacing.md),
                            // 两块等高：按较高一块的内容撑齐。
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: _MyAccountTile(
                                      icon: Icons.badge_outlined,
                                      title: '统一认证',
                                      loggedIn: _campusLoggedIn,
                                      status: _statusLabel(_campusLoggedIn),
                                      statusKey: const Key('my_campus_status'),
                                      // 已登录进一卡通；未登录先弹统一认证登录。
                                      onTap: () =>
                                          unawaited(_openCampusCardAction()),
                                    ),
                                  ),
                                  const SizedBox(width: _tileGap),
                                  Expanded(
                                    child: _MyAccountTile(
                                      icon: Icons.school_outlined,
                                      title: '教务系统',
                                      loggedIn: _academicLoggedIn,
                                      status: _statusLabel(_academicLoggedIn),
                                      statusKey: const Key(
                                        'my_academic_status',
                                      ),
                                      // 已登录直达教务 H5；未登录先弹教务登录。
                                      onTap: () =>
                                          unawaited(_openAcademicAction()),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: _tileGap),
                            _MyTile(
                              icon: Icons.settings_outlined,
                              title: '设置',
                              status: '主题、学期、网络与关于',
                              onTap: () async {
                                await context.pushNamed('settings');
                                if (!mounted) return;
                                await _refreshStatus();
                              },
                            ),
                            const Spacer(),
                            _buildFooter(context, cs),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部签名：锚在悬浮导航条上方，点按进「关于」。
  Widget _buildFooter(BuildContext context, ColorScheme cs) {
    return Padding(
      padding: EdgeInsets.only(
        top: AppSpacing.xl,
        bottom: MediaQuery.paddingOf(context).bottom + _footerDockGap,
      ),
      child: Center(
        child: FutureBuilder<PackageInfo>(
          future: _packageInfoFuture,
          builder: (context, snapshot) => TextButton(
            onPressed: () => context.pushNamed('about'),
            style: TextButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(
              snapshot.hasData ? '嘉兴大学 v${snapshot.data!.version}' : '嘉兴大学',
            ),
          ),
        ),
      ),
    );
  }
}

/// 单步会话撤销的结果：已撤销 / 因有更新的登录而保留 / 执行失败。
enum _RevokeOutcome { revoked, preserved, failed }

/// 登出收尾依据：失败步骤与「已保留新登录」的域。
class _LogoutOutcome {
  const _LogoutOutcome({required this.failures, required this.preserved});

  /// 失败步骤的显示名（执行顺序）。
  final List<String> failures;

  /// 因「有更新的登录」而跳过撤销的域显示名。
  final List<String> preserved;
}

/// 确认时刻的会话指纹：内存 sessionRevision（同账号重登也会推进）+
/// 身份 + 持久 epoch 三元组。任一可观察变化即视为「有更新的登录」。
class _SessionFingerprint {
  const _SessionFingerprint({
    required this.revision,
    required this.identity,
    required this.epoch,
  });

  final int revision;
  final String? identity;

  /// 持久身份纪元；null = 读不到，退化为「revision + 身份」比较。
  final int? epoch;
}

/// 读持久 epoch；失败只记日志并返回 null（退化比较），不吞调用方流程。
Future<int?> _readPersistedEpochSafe(CredentialSessionDomain domain) async {
  try {
    return await AuthSessionPersistence.instance.readEpoch(domain);
  } catch (error, stackTrace) {
    AppLogger.instance.auth(
      LogLevel.warn,
      '读取会话持久 epoch 失败（退化为 revision + 身份比较）',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// 捕获会话指纹。epoch 读取是异步的：期间身份若已变化则重取一次，
/// 尽量让三元组来自同一时刻。
Future<_SessionFingerprint> _captureFingerprint(
  CredentialSessionDomain domain,
  int Function() revisionOf,
  String? Function() identityOf,
) async {
  var revision = revisionOf();
  var identity = identityOf();
  var epoch = await _readPersistedEpochSafe(domain);
  if (revisionOf() != revision || identityOf() != identity) {
    revision = revisionOf();
    identity = identityOf();
    epoch = await _readPersistedEpochSafe(domain);
  }
  return _SessionFingerprint(
    revision: revision,
    identity: identity,
    epoch: epoch,
  );
}

/// 撤销前复核：revision / 身份 / 持久 epoch 任一变化即视为「有更新的登录」，
/// 不得撤销。捕获侧 epoch 不可读时退化为前两项比较；复核侧 epoch 读失败
/// 时保守判为「已变化」（宁可漏撤销、不误杀新登录）。
Future<bool> _fingerprintUnchanged(
  _SessionFingerprint fingerprint,
  CredentialSessionDomain domain,
  int Function() revisionOf,
  String? Function() identityOf,
) async {
  if (revisionOf() != fingerprint.revision) return false;
  if (identityOf() != fingerprint.identity) return false;
  final capturedEpoch = fingerprint.epoch;
  if (capturedEpoch == null) return true;
  return await _readPersistedEpochSafe(domain) == capturedEpoch;
}

/// 顶部：大标题「我的」+ 学校与学号灰色小字；有登录时行尾放低调的登出入口。
class _MyHeader extends StatelessWidget {
  const _MyHeader({required this.identity, required this.onLogout});

  final String? identity;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '我的',
                style: Theme.of(context).textTheme.headlineMedium!
                    .copyWith(color: cs.onSurface),
              ),
              const SizedBox(height: 2),
              Text(
                '嘉兴大学 · ${identity ?? '未登录'}',
                key: const Key('my_identity'),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  letterSpacing: 0.2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (onLogout != null)
          IconButton(
            key: const Key('my_logout'),
            onPressed: onLogout,
            icon: const Icon(Icons.logout_rounded),
            tooltip: '退出登录',
            style: IconButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              minimumSize: const Size(44, 44),
              maximumSize: const Size(44, 44),
            ),
          ),
      ],
    );
  }
}

/// 「账号」分组标题：与功能页「功能 · 长按置顶」同一排版。
class _MySectionHeader extends StatelessWidget {
  const _MySectionHeader();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          '账号',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const Spacer(),
        Text(
          '点按进入对应服务',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 账号方磁贴：并排两块，上徽标、下标题 + 登录状态。已登录带主色圆点，
/// 未登录把「去登录」染主色作为行动提示。
class _MyAccountTile extends StatelessWidget {
  const _MyAccountTile({
    required this.icon,
    required this.title,
    required this.loggedIn,
    required this.status,
    required this.onTap,
    this.statusKey,
  });

  final IconData icon;
  final String title;
  final bool loggedIn;
  final String status;
  final Key? statusKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: title,
      child: AppTileSurface(
        padding: const EdgeInsets.all(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconBadge(
              icon: icon,
              accentColor: cs.primary,
              size: AppIconBadgeSize.medium,
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.2,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                if (loggedIn) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    status,
                    key: statusKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.25,
                      fontWeight: loggedIn ? null : FontWeight.w600,
                      color: loggedIn ? cs.onSurfaceVariant : cs.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 独立磁贴：与功能页宽磁贴同一配方（AppTileSurface + 中号徽标 +
/// 标题/状态两行 + 淡色微箭头），只是去掉置顶等交互。
class _MyTile extends StatelessWidget {
  const _MyTile({
    required this.icon,
    required this.title,
    required this.status,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: title,
      child: AppTileSurface(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.25,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
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
    );
  }
}
