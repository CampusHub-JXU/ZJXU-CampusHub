import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'auth_operation_coordinator.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'automatic_login.dart';
import 'background_auth_run.dart';
import 'background_session_gate.dart';
import 'credential_store.dart';
import 'unified_auth.dart';

/// 后台统一认证恢复的结果。
enum BackgroundRecoveryResult {
  /// 已真实重新登录（typed ticket commit 产出 receipt）。
  recovered,

  /// 前台正在使用（或读写门失败）：不申领、不动会话，交给前台自己处理。
  foregroundActive,

  /// 曾有已确认的统一认证身份，但无法自动恢复（未开启自动恢复 / 已暂停 /
  /// 冷却中 / 账号不一致）：后台不该也不能自动登录，应提醒用户回来重新登录。
  notEligible,

  /// 根本没有可恢复的身份：从未登录 / 无账号 / 用户主动退出登录（含已撤销）/
  /// 当前无活跃身份且自动恢复本就未开启。没有「过期」可言，**绝不提醒**。
  noIdentity,

  /// 服务端会话其实仍有效或探测不出（网络异常）：后台不做任何登录。
  undetermined,

  /// 已尝试但未完成（OCR 未识别、网络、被前台让位取消等）。
  failed,
}

/// WorkManager 后台 isolate 的统一认证静默恢复。
///
/// 只在教务处通知后台检查遇到 `authRequired`（服务端会话明确过期）时调用。
/// 桌面组件另由 BackgroundAuthContext 组合两域恢复，本类保留通知任务入口；
/// 两条路径的「申领 / 让位 / 预算 / epoch 钉住 / 释放」都走同一个共享原语
/// [BackgroundAuthRun]：
///
/// 1. 必须先经 [BackgroundSessionGate.tryClaim] 申领——前台心跳新鲜则让位；
/// 2. 申领期间每 [yieldPollInterval] 复查一次，前台回来即取消登录；本轮在
///    [BackgroundAuthContext] 内运行并**钉住申领时的 CAS epoch / 账号**：前台在
///    申领之后重新登录，本轮的撤销与自动恢复都会让位，不会踢掉新会话；
/// 3. 恢复资格（opt-in / 未撤销 / 未暂停 / 未冷却 / 账号一致）由既有
///    [AuthOperationCoordinator.automaticEligibility] 裁决，本类不另造判据；
/// 4. 登录本身完全复用前台的 [AutomaticLoginService]（challenge → 本地 OCR 一次
///    → typed ticket commit），不新增提交路径；
/// 5. 只有**确认可以自动恢复**时才会因探测到过期而持久登出身份——无法恢复的
///    用户不会被后台登出，仅收到本地提醒。
///
/// **不得夸大**：跨 isolate `PersistCookieJar` 竞争被大幅收窄（前台在用时后台
/// 完全不动、前台回来时重载磁盘 Cookie），但没有被消除。
class BackgroundCasRecovery {
  BackgroundCasRecovery._({
    BackgroundSessionGate? gate,
    Future<AuthRecoveryDecision> Function(String account)? eligibility,
    Future<String?> Function()? credentialAccount,
    Future<void> Function()? restoreSession,
    bool Function()? isLoggedIn,
    String? Function()? currentAccount,
    Future<bool?> Function()? validateSession,
    Future<AutomaticLoginAttemptResult> Function(
      String account,
      CancelToken token,
    )?
    attempt,
    Future<int?> Function()? readEpoch,
    this.pinReader,
    this.overallBudget = BackgroundAuthRun.defaultBudget,
    this.yieldPollInterval = BackgroundAuthRun.defaultYieldPollInterval,
    this.preflightTimeout = const Duration(seconds: 20),
    this.hardStopGrace = BackgroundAuthRun.defaultHardStopGrace,
  }) : _gate = gate ?? BackgroundSessionGate.instance,
       _readEpoch =
           readEpoch ??
           (() => AuthSessionPersistence.instance.readEpoch(
             CredentialSessionDomain.unified,
           )),
       _eligibility =
           eligibility ??
           ((account) => AuthOperationCoordinator.instance.automaticEligibility(
             AuthRecoveryDomain.cas,
             account: account,
           )),
       _credentialAccount =
           credentialAccount ??
           (() async =>
               (await CredentialStore.instance.loadUnifiedAuthCredentials())
                   ?.$1),
       _restoreSession =
           restoreSession ??
           (() => UnifiedAuthService.instance.restoreSession(
             syncWebViewCookies: false,
           )),
       _isLoggedIn =
           isLoggedIn ?? (() => UnifiedAuthService.instance.isLoggedIn),
       _currentAccount =
           currentAccount ?? (() => UnifiedAuthService.instance.currentAccount),
       _validateSession =
           validateSession ??
           (() => UnifiedAuthService.instance.validateSession(
             syncWebViewCookies: false,
           )),
       _attempt =
           attempt ??
           ((account, token) =>
               AutomaticLoginService.instance.attemptWithReceipt(
                 AuthRecoveryDomain.cas,
                 expectedAccount: account,
                 cancelToken: token,
               ));

  static final BackgroundCasRecovery instance = BackgroundCasRecovery._();

  @visibleForTesting
  static BackgroundCasRecovery debugNew({
    BackgroundSessionGate? gate,
    Future<AuthRecoveryDecision> Function(String account)? eligibility,
    Future<String?> Function()? credentialAccount,
    Future<void> Function()? restoreSession,
    bool Function()? isLoggedIn,
    String? Function()? currentAccount,
    Future<bool?> Function()? validateSession,
    Future<AutomaticLoginAttemptResult> Function(
      String account,
      CancelToken token,
    )?
    attempt,
    Future<int?> Function()? readEpoch,
    BackgroundSessionPinReader? pinReader,
    Duration overallBudget = BackgroundAuthRun.defaultBudget,
    Duration yieldPollInterval = const Duration(milliseconds: 20),
    Duration preflightTimeout = const Duration(seconds: 20),
    Duration hardStopGrace = BackgroundAuthRun.defaultHardStopGrace,
  }) => BackgroundCasRecovery._(
    readEpoch: readEpoch,
    // 测试默认桩：不读真实持久层；需要断言钉住行为的用例显式传入。
    pinReader: pinReader ?? (_) async => (epoch: 0, account: null),
    hardStopGrace: hardStopGrace,
    gate: gate,
    eligibility: eligibility,
    credentialAccount: credentialAccount,
    restoreSession: restoreSession,
    isLoggedIn: isLoggedIn,
    currentAccount: currentAccount,
    validateSession: validateSession,
    attempt: attempt,
    overallBudget: overallBudget,
    yieldPollInterval: yieldPollInterval,
    preflightTimeout: preflightTimeout,
  );

  final BackgroundSessionGate _gate;
  final Future<AuthRecoveryDecision> Function(String account) _eligibility;
  final Future<String?> Function() _credentialAccount;
  final Future<void> Function() _restoreSession;
  final bool Function() _isLoggedIn;
  final String? Function() _currentAccount;
  final Future<bool?> Function() _validateSession;
  final Future<AutomaticLoginAttemptResult> Function(
    String account,
    CancelToken token,
  )
  _attempt;
  final Future<int?> Function() _readEpoch;
  final BackgroundSessionPinReader? pinReader;

  /// 整轮总预算（自申领起算，**含**恢复 / 校验 / 自动登录）。
  ///
  /// 以前通知路径是「恢复 + 校验各至多 20s，再加 75s 登录预算」，最坏 115s 贴着
  /// 申领 TTL（2 分钟）；现与桌面组件统一为 [BackgroundAuthRun.defaultBudget]
  /// 并由共享原语硬性兜底。
  final Duration overallBudget;
  final Duration yieldPollInterval;

  /// 预算到期后给在途 await 响应取消的额外时间，过后放弃等待（结果 `failed`）。
  final Duration hardStopGrace;

  /// 恢复 / 校验各自的上限，超时按「探测不出」处理，不登出。整体仍受
  /// [overallBudget] + [hardStopGrace] 约束。
  final Duration preflightTimeout;

  Future<BackgroundRecoveryResult> recover() async {
    try {
      final run = await BackgroundAuthRun.execute<BackgroundRecoveryResult>(
        gate: _gate,
        budget: overallBudget,
        hardStopGrace: hardStopGrace,
        yieldPollInterval: yieldPollInterval,
        // 在任何会话读写之前钉住申领时的 CAS epoch / 账号。
        pinDomains: const {AuthRecoveryDomain.cas},
        pinReader: pinReader,
        label: '后台统一认证恢复',
        body: _recoverClaimed,
      );
      if (!run.claimed) {
        AppLogger.instance.auth(LogLevel.info, '后台统一认证恢复：前台在用或申领失败，让位');
        return BackgroundRecoveryResult.foregroundActive;
      }
      if (run.timedOut) return BackgroundRecoveryResult.failed;
      return run.value ?? BackgroundRecoveryResult.failed;
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '后台统一认证恢复异常',
        error: error,
        stackTrace: stackTrace,
      );
      return BackgroundRecoveryResult.failed;
    }
  }

  Future<BackgroundRecoveryResult> _recoverClaimed(
    BackgroundAuthRun run,
  ) async {
    try {
      await _restoreSession().timeout(preflightTimeout);
    } on TimeoutException {
      AppLogger.instance.auth(LogLevel.warn, '后台统一认证恢复：恢复会话超时，放弃');
      return BackgroundRecoveryResult.undetermined;
    }
    final account = (_currentAccount() ?? await _credentialAccount())?.trim();
    if (account == null || account.isEmpty) {
      return BackgroundRecoveryResult.noIdentity;
    }
    final decision = await _eligibility(account);
    if (decision != AuthRecoveryDecision.proceed) {
      AppLogger.instance.auth(
        LogLevel.info,
        '后台统一认证恢复：不在自动恢复范围（${decision.name}）',
      );
      // 用户主动退出登录（持久撤销）不是「过期」；未开启自动恢复 / 账号不一致
      // 且当前也没有活跃身份时同样没有东西可提醒。暂停 / 冷却 / 人工持有意味着
      // 自动恢复曾开启且账号一致，属于真实身份无法自动恢复。
      if (decision == AuthRecoveryDecision.revoked ||
          ((decision == AuthRecoveryDecision.disabled ||
                  decision == AuthRecoveryDecision.accountMismatch) &&
              !_isLoggedIn())) {
        return BackgroundRecoveryResult.noIdentity;
      }
      return BackgroundRecoveryResult.notEligible;
    }

    // 已确认可自动恢复，才允许因探测到过期而持久登出：登出后
    // AutomaticLoginService 才有真实登录表单可用。
    if (_isLoggedIn()) {
      final bool? validated;
      try {
        validated = await _validateSession().timeout(preflightTimeout);
      } on TimeoutException {
        AppLogger.instance.auth(LogLevel.warn, '后台统一认证恢复：会话校验超时，放弃');
        return BackgroundRecoveryResult.undetermined;
      }
      if (validated == true) return BackgroundRecoveryResult.undetermined;
      if (validated == null) return BackgroundRecoveryResult.undetermined;
      // revoked 记录必须带上被撤销的账号与撤销后的持久 epoch：前台迟到消费时，
      // 用户可能已经重新登录（epoch 已推进），此时这条记录不再适用。epoch 只在
      // 仍等于本轮钉住值（本轮自己的撤销推进后的值）时才带；被别人改过或读不到
      // 就不带，前台按「不适用」处理（少登出一次，不会误踢新会话）。
      run.recordChange(
        BackgroundSessionChangeKind.revoked,
        account: account,
        readEpoch: () async {
          final disk = await _readEpoch();
          final pinned = run.context.pinnedEpoch(
            CredentialSessionDomain.unified,
          );
          return pinned != null && disk != pinned ? null : disk;
        },
      );
    }

    final result = await _attempt(account, run.cancelToken);
    if (result.outcome == AutomaticLoginOutcome.committed &&
        result.receipt != null) {
      run.recordChange(BackgroundSessionChangeKind.committed);
      AppLogger.instance.auth(LogLevel.info, '后台统一认证恢复成功');
      return BackgroundRecoveryResult.recovered;
    }
    AppLogger.instance.auth(
      LogLevel.info,
      '后台统一认证恢复未完成（${result.outcome.name}）',
    );
    return result.outcome == AutomaticLoginOutcome.notEligible ||
            result.outcome == AutomaticLoginOutcome.manualRequired ||
            result.outcome == AutomaticLoginOutcome.cooldown
        ? BackgroundRecoveryResult.notEligible
        : BackgroundRecoveryResult.failed;
  }
}
