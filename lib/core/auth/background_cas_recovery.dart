import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'auth_operation_coordinator.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'automatic_login.dart';
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
/// 桌面组件另由 BackgroundAuthContext 组合两域恢复，本类保留通知任务入口：
///
/// 1. 必须先经 [BackgroundSessionGate.tryClaim] 申领——前台心跳新鲜则让位；
/// 2. 申领期间每 [yieldPollInterval] 复查一次，前台回来即取消登录；
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
    this.overallBudget = const Duration(seconds: 75),
    this.yieldPollInterval = const Duration(seconds: 2),
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
    Duration overallBudget = const Duration(seconds: 75),
    Duration yieldPollInterval = const Duration(milliseconds: 20),
  }) => BackgroundCasRecovery._(
    readEpoch: readEpoch,
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

  final Duration overallBudget;
  final Duration yieldPollInterval;

  Future<BackgroundRecoveryResult> recover() async {
    final claim = await _gate.tryClaim();
    if (claim == null) {
      AppLogger.instance.auth(LogLevel.info, '后台统一认证恢复：前台在用或申领失败，让位');
      return BackgroundRecoveryResult.foregroundActive;
    }

    var revokedIdentity = false;
    String? revokedAccount;
    var committed = false;
    Timer? poll;
    Timer? budget;
    final token = CancelToken();
    try {
      await _restoreSession();
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
        final validated = await _validateSession();
        if (validated == true) return BackgroundRecoveryResult.undetermined;
        if (validated == null) return BackgroundRecoveryResult.undetermined;
        revokedIdentity = true;
        revokedAccount = account;
      }

      poll = Timer.periodic(yieldPollInterval, (_) async {
        if (token.isCancelled) return;
        if (await _gate.shouldYield(claim) && !token.isCancelled) {
          token.cancel('foreground took over');
        }
      });
      budget = Timer(overallBudget, () {
        if (!token.isCancelled) token.cancel('background recovery budget');
      });

      final result = await _attempt(account, token);
      if (result.outcome == AutomaticLoginOutcome.committed &&
          result.receipt != null) {
        committed = true;
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
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '后台统一认证恢复异常',
        error: error,
        stackTrace: stackTrace,
      );
      return BackgroundRecoveryResult.failed;
    } finally {
      poll?.cancel();
      budget?.cancel();
      // revoked 记录必须带上被撤销的账号与撤销后的持久 epoch：前台迟到消费时，
      // 用户可能已经重新登录（epoch 已推进），此时这条记录不再适用。读不到
      // epoch 就不带，前台按「不适用」处理（少登出一次，不会误踢新会话）。
      int? revokedEpoch;
      if (revokedIdentity && !committed) {
        try {
          revokedEpoch = await _readEpoch();
        } catch (_) {
          revokedEpoch = null;
        }
      }
      await _gate.release(
        claim,
        change: committed
            ? BackgroundSessionChangeKind.committed
            : revokedIdentity
            ? BackgroundSessionChangeKind.revoked
            : null,
        changeAccount: revokedAccount,
        changeEpoch: revokedEpoch,
      );
    }
  }
}
