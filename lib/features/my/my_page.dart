import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme/app_theme_controller.dart';
import '../../core/auth/auth_operation_coordinator.dart';
import '../../core/auth/auth_recovery_state_store.dart';
import '../../core/auth/auth_session_persistence.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/login_shell.dart';
import '../schedule/schedule_service.dart';

/// 行级视觉 token（自首页功能瓦片 / 「今天」列表行提取，全 App 行规格同档）：
/// 徽标与文字列之间的固定间距，发丝分隔线缩进公式也复用它。
const double _rowIconTextGap = 10;

/// 组行标题规格：15/w600/h1.2（Apple semibold 行标题档），
/// 与 _GroupRowTile 及年级行的手写样式收敛为单一来源。
TextStyle _rowTitleStyle(ColorScheme cs) => TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  height: 1.2,
  color: cs.onSurface,
);

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

  /// 测活请求本身失败（网络异常）：无法下结论，不能沿用「已登录」。
  /// 之前这里回退到缓存的登录态，导致显示已登录但实际会话已失效。
  bool _campusStatusUnknown = false;
  bool _academicStatusUnknown = false;
  bool _campusStatusChecking = false;
  bool _academicStatusChecking = false;
  bool _hasScheduleCache = false;
  DateTime? _scheduleUpdatedAt;
  int _statusRefreshVersion = 0;

  /// 登出「确认 + 效果」全流程去重位：进行中的重复点按一律忽略——不叠
  /// 第二个确认框、不跑第二遍登出，行上的登录/导航也暂不受理（避免与
  /// 登出交叠）。只做行为门控，不改视觉。
  bool _logoutBusy = false;

  /// 测试闸门在 initState 捕获一次：登出效果要在页面 dispose 后继续跑完，
  /// 中途不得再触碰 `widget`/`context`。
  LogoutStepGate? _logoutStepGate;

  /// 底部签名行版本号，仅取一次。
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
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    ZhengfangAuth.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final term = ScheduleService.instance.getCurrentTermContext();
    final snapshot = ScheduleService.instance.preferredSnapshot(
      termContext: term,
    );
    final refreshVersion = ++_statusRefreshVersion;
    final campusLoggedIn = UnifiedAuthService.instance.isLoggedIn;
    final academicLoggedIn = ZhengfangAuth.instance.isLoggedIn;

    setState(() {
      _campusLoggedIn = campusLoggedIn;
      _academicLoggedIn = academicLoggedIn;
      _campusStatusChecking = campusLoggedIn;
      _academicStatusChecking = academicLoggedIn;
      _campusStatusUnknown = false;
      _academicStatusUnknown = false;
      _hasScheduleCache = snapshot?.hasData ?? false;
      _scheduleUpdatedAt = snapshot?.lastUpdatedAt;
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
      // null = 测活请求网络异常，登录态未知；不再回退到缓存的「已登录」。
      _campusStatusUnknown = campusValidation == null;
      _academicStatusUnknown = academicValidation == null;
      _campusLoggedIn =
          campusValidation ?? UnifiedAuthService.instance.isLoggedIn;
      _academicLoggedIn =
          academicValidation ?? ZhengfangAuth.instance.isLoggedIn;
      _campusStatusChecking = false;
      _academicStatusChecking = false;
      _hasScheduleCache = snapshot?.hasData ?? false;
      _scheduleUpdatedAt = snapshot?.lastUpdatedAt;
    });
  }

  /// 测活兜底：validateSession 理论上内部吞网络异常返回 null，但部分路径
  /// （如 DioClient 未初始化）仍可能抛出；这里统一归入 null = 状态未知，
  /// 避免 _refreshStatus 中断导致 UI 永久停留在「正在校验」。
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

  /// 右上角登出入口：先弹确认框，确认后按固定顺序执行「显式用户登出」。
  ///
  /// 确认 + 登出全程 [_logoutBusy] 去重：进行中的重复点按一律忽略（不叠
  /// 第二个确认框、不跑第二遍登出）。
  Future<void> _promptLogout() async {
    if (_logoutBusy) return;
    _logoutBusy = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('退出登录'),
          content: const Text('退出后，统一认证与教务都需要重新登录才能继续使用。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('返回'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出登录'),
            ),
          ],
        ),
      );
      // 一旦用户确认，四步效果与 mounted 无关地执行完毕：中途页面被销毁
      // 绝不允许留下「只撤销了一域」的半套登出。
      if (confirmed != true) return;
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
    final messenger = ScaffoldMessenger.of(context);
    if (outcome.failures.isEmpty && outcome.preserved.isEmpty) {
      messenger.hideCurrentSnackBar();
      return;
    }
    final message = <String>[
      if (outcome.failures.isNotEmpty)
        '退出登录未完全完成（${outcome.failures.join('、')}），可重试',
      if (outcome.preserved.isNotEmpty) '登出过程中有新的登录，已保留新会话',
    ].join('；');
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: outcome.failures.isEmpty
            ? null
            : SnackBarAction(
                label: '重试',
                onPressed: () => unawaited(_retryLogout()),
              ),
      ),
    );
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '未缓存';
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  String _academicSubtitle() {
    if (_academicStatusChecking) {
      if (_hasScheduleCache) {
        return '正在校验教务状态 · 课表缓存 ${_formatTime(_scheduleUpdatedAt)}';
      }
      return '正在校验教务状态 · 课表未缓存';
    }
    if (_academicStatusUnknown) {
      return '登录状态未知 · 点按重新校验';
    }
    if (_academicLoggedIn) {
      if (_hasScheduleCache) {
        return '已登录 · 课表更新 ${_formatTime(_scheduleUpdatedAt)}';
      }
      return '已登录 · 课表未缓存';
    }
    if (_hasScheduleCache) {
      return '未登录 · 课表缓存 ${_formatTime(_scheduleUpdatedAt)}';
    }
    return '未登录 · 课表未缓存';
  }

  String _campusSubtitle() {
    if (_campusStatusChecking) {
      return '正在校验统一认证状态';
    }
    if (_campusStatusUnknown) {
      return '登录状态未知 · 点按重新校验';
    }
    return _campusLoggedIn ? '已登录' : '未登录';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryIconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    return Scaffold(
      // 不再挂空顶栏：标题语义由正文 large title「我的」承担，
      // 状态栏留白交给 [SafeArea] 处理。
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            // 内容不满一屏时撑到视口高度，让 [Spacer] 把底部签名锚到
            // 页面底缘（大字号/内容超屏时自然回退为普通滚动）。
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.pageMargin,
                        AppSpacing.xl,
                        AppSpacing.pageMargin,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Apple large-title 头部行：无卡容器，纯文字块与卡片
                          // 左缘对齐；直接复用全局 Apple 字阶展示档
                          // headlineMedium（28/w700 + 收紧字距 -0.4），与
                          // 首页 Hero 大字同一展示语言，建立一致的排版重心。
                          // 行尾放低调的登出入口（仅至少一端已登录时出现），
                          // 标题左缘与体量不变。
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  '我的',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium!
                                      .copyWith(color: cs.onSurface),
                                ),
                              ),
                              if (_campusLoggedIn || _academicLoggedIn)
                                IconButton(
                                  onPressed: () => unawaited(_promptLogout()),
                                  icon: const Icon(Icons.logout_rounded),
                                  tooltip: '退出登录',
                                  style: IconButton.styleFrom(
                                    foregroundColor: cs.onSurfaceVariant,
                                    minimumSize: const Size(44, 44),
                                    maximumSize: const Size(44, 44),
                                  ),
                                ),
                            ],
                          ),
                          // 头部到卡片群的呼吸空间，与首页环境行 → Hero
                          // 的大留白同一意图（按本页体量收窄为 24）。
                          const SizedBox(height: AppSpacing.xl),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                _GroupRowTile(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(AppRadius.card),
                                  ),
                                  icon: Icons.account_balance_wallet_outlined,
                                  iconColor: primaryIconColor,
                                  title: '统一认证（含一卡通）',
                                  subtitle: _campusSubtitle(),
                                  subtitleKey: const Key('my_campus_status'),
                                  onTap: () {
                                    if (_campusStatusUnknown) {
                                      // 状态未知时点按 = 重新测活，而不是直接弹登录框。
                                      unawaited(_refreshStatus());
                                    } else {
                                      // 已登录直接进一卡通页；未登录先弹统一
                                      // 认证登录，避免绕过登录直接落到受保护页。
                                      unawaited(_openCampusCardAction());
                                    }
                                  },
                                ),
                                _buildHairlineDivider(context),
                                _GroupRowTile(
                                  borderRadius: BorderRadius.vertical(
                                    bottom: Radius.circular(AppRadius.card),
                                  ),
                                  icon: Icons.school_outlined,
                                  iconColor: primaryIconColor,
                                  title: '教务系统',
                                  subtitle: _academicSubtitle(),
                                  subtitleKey: const Key('my_academic_status'),
                                  onTap: () => unawaited(
                                    _academicStatusUnknown
                                        ? _refreshStatus()
                                        : _openAcademicAction(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: _GroupRowTile(
                              borderRadius: BorderRadius.circular(
                                AppRadius.card,
                              ),
                              icon: Icons.settings_outlined,
                              iconColor: primaryIconColor,
                              title: '设置',
                              subtitle: '主题、学期、网络与调试选项',
                              onTap: () async {
                                await context.pushNamed('settings');
                                if (!mounted) return;
                                await _refreshStatus();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    _buildFooter(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部签名行：锚在视口底缘（dock 上方），让首屏留白成为刻意构图；
  /// 版本号规格与设置页「关于」一致。
  Widget _buildFooter(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.xl,
        AppSpacing.pageMargin,
        // SafeArea(bottom: false) 之下自行叠加底部安全区 + dock 高度。
        MediaQuery.paddingOf(context).bottom + 110,
      ),
      child: Center(
        child: FutureBuilder<PackageInfo>(
          future: _packageInfoFuture,
          builder: (context, snapshot) {
            final version = snapshot.hasData
                ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                : '';
            return Text(
              '嘉兴大学 $version',
              style: textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
            );
          },
        ),
      ),
    );
  }

  /// 组内行间发丝分隔线：左缩进对齐文本起始列（行 padding 16 + 徽标 + 间距 10）。
  Widget _buildHairlineDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 1,
      margin: const EdgeInsets.only(
        left: AppSpacing.lg + AppBadgeSize.smallBox + _rowIconTextGap,
      ),
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }
}

/// 分组卡内的 iOS Settings 式横排行：徽标 + 文字列 + 行尾箭头。
///
/// 文字规格与首页功能瓦片一致（标题 15/w600、副标题 13），内容垂直居中；
/// 涟漪经 [RoundedSuperellipseBorder] 裁剪，组内首末行只圆外侧角，
/// 让按压高光贴住卡面轮廓。
class _GroupRowTile extends StatelessWidget {
  const _GroupRowTile({
    required this.borderRadius,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.subtitleKey,
  });

  /// 涟漪裁剪形状：组内首行只圆上角、末行只圆下角，单行组取整卡圆角。
  final BorderRadius borderRadius;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Key? subtitleKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(borderRadius: borderRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.lg,
          ),
          child: Row(
            children: [
              AppIconBadge(
                icon: icon,
                accentColor: iconColor,
                size: AppIconBadgeSize.small,
              ),
              const SizedBox(width: _rowIconTextGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _rowTitleStyle(cs),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      key: subtitleKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
            ],
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
