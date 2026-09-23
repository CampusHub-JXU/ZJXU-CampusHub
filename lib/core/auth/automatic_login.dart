import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../captcha/captcha_recognizer.dart';
import '../logging/app_logger.dart';
import 'auth_failure.dart';
import 'auth_operation_coordinator.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'captcha_challenge.dart';
import 'credential_store.dart';
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

/// 静默自动登录一次尝试的最终结果。
///
/// 只有 [committed] 代表**真实提交**（协调器的 typed ticket commit 产出了
/// receipt）；[manualRequired] 表示身份失败已达阈值，调用方必须提示用户手动
/// 登录一次，**不得**再静默重试。
enum AutomaticLoginOutcome {
  /// 已通过 `runAutomatic` 的 typed ticket commit 真实提交会话。
  committed,

  /// 无已保存凭据 / 账号不匹配 / opt-in 关闭或已撤销：不在自动范围。
  notEligible,

  /// 身份失败累计达阈值，自动登录已暂停，必须由用户手动登录一次。
  manualRequired,

  /// 冷却或人工验证码持有窗口内，本次跳过。
  cooldown,

  /// 同域已有交换在运行，本次让位。
  busy,

  /// 交换/提交未完成（识别失败、网络、超时、被撤销等）。
  failed,
}

/// 一次交换的产物：真实 receipt（成功）或 OCR 未识别标记。
///
/// 自动登录层**不**自己做身份/metadata 提交，receipt 只能来自真实 challenge
/// 提交里的 typed ticket commit；没有 receipt 一律不算成功。
class _AutomaticExchangeResult {
  const _AutomaticExchangeResult({this.receipt, this.ocrUnrecognized = false});

  final SessionCommitResult? receipt;

  /// OCR 未能给出答案：按瞬时失败退避（绝不猜、绝不重复识别）。
  final bool ocrUnrecognized;
}

/// 一次静默自动登录尝试的**带来源结果**。
///
/// [AutomaticLoginOutcome.committed] 只有在 [receipt] 非空时才是可信提交：
/// receipt 是唯一提交点（真实 challenge 的 typed ticket commit）产出的
/// account+epoch 句柄，调用方必须用它证明「这次提交确实发生了」，而不是
/// 用「同 owner 的最新 revision」推断。
class AutomaticLoginAttemptResult {
  const AutomaticLoginAttemptResult({required this.outcome, this.receipt});

  final AutomaticLoginOutcome outcome;

  /// 真实提交产出的 typed 句柄；无提交（含 OCR 未识别、失败、暂停、
  /// ticket 被拒）一律为 null。
  final SessionCommitResult? receipt;
}

/// 静默自动登录服务（前台单 isolate）。
///
/// 读已保存凭据 → prepare challenge → 本地 OCR → 把 ticket 交给真实 challenge
/// 提交；互斥/资格/退避/条件提交全部由 [AuthOperationCoordinator.runAutomatic]
/// 负责，本类**不**另造锁或提交路径。
///
/// 验证码位数按域固定：CAS（统一认证）= 4 位，教务（正方）= 6 位。每个
/// challenge 只调用一次 OCR；返回 null 即判瞬时失败退避，不做第二次长度尝试、
/// 不发额外网络请求。
///
/// 不变量：自动登录仅前台单 isolate 发起（workmanager 后台不发起 CAS/教务
/// 登录）；跨 isolate CookieJar 竞争未被消除，只被该不变量规避。
class AutomaticLoginService {
  AutomaticLoginService._({
    AuthOperationCoordinator? coordinator,
    CaptchaRecognizer? recognizer,
  }) : _coordinator = coordinator ?? AuthOperationCoordinator.instance,
       _recognizer = recognizer ?? defaultCaptchaRecognizer;

  static final AutomaticLoginService instance = AutomaticLoginService._();

  @visibleForTesting
  static AutomaticLoginService debugNew({
    AuthOperationCoordinator? coordinator,
    CaptchaRecognizer? recognizer,
  }) =>
      AutomaticLoginService._(coordinator: coordinator, recognizer: recognizer);

  final AuthOperationCoordinator _coordinator;
  final CaptchaRecognizer _recognizer;

  /// 本服务无可变状态（依赖均经 [debugNew] 注入）；与其它单例服务保持一致的
  /// 复位入口，便于测试在 tearDown 统一调用。
  @visibleForTesting
  void debugReset() {}

  /// CAS（统一认证）验证码固定 4 位。
  static const int casCaptchaLength = 4;

  /// 教务（正方）验证码固定 6 位。
  static const int academicCaptchaLength = 6;

  /// 尝试一次静默自动登录，只返回结果枚举（兼容既有调用方）。
  ///
  /// 需要证明「真实提交」的调用方（如 [AcademicAuthGuard]）必须改用
  /// [attemptWithReceipt]，用 receipt 的 account+epoch 归属本次提交。
  Future<AutomaticLoginOutcome> attempt(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
    CancelToken? cancelToken,
  }) async {
    final result = await attemptWithReceipt(
      domain,
      expectedAccount: expectedAccount,
      cancelToken: cancelToken,
    );
    return result.outcome;
  }

  /// 尝试一次静默自动登录，返回结果枚举 + 真实提交 receipt（若有）。
  ///
  /// receipt 直接取自 [AuthOperationCoordinator.runAutomatic] 的
  /// `outcome.receipt`（唯一提交点的 typed 句柄），**不做**任何第二次提交；
  /// 只有 `decision == committed` 时才附带 receipt，其余终态一律 null。
  /// 异常一律隔离为 [AutomaticLoginOutcome.failed]，绝不向调用方抛出。
  Future<AutomaticLoginAttemptResult> attemptWithReceipt(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
    CancelToken? cancelToken,
  }) async {
    try {
      final credentials = await _loadCredentials(domain);
      if (credentials == null) {
        return const AutomaticLoginAttemptResult(
          outcome: AutomaticLoginOutcome.notEligible,
        );
      }
      final account = credentials.$1.trim();
      final password = credentials.$2;
      if (account.isEmpty || password.isEmpty) {
        return const AutomaticLoginAttemptResult(
          outcome: AutomaticLoginOutcome.notEligible,
        );
      }
      final expected = expectedAccount?.trim();
      if (expected != null && expected.isNotEmpty && expected != account) {
        return const AutomaticLoginAttemptResult(
          outcome: AutomaticLoginOutcome.notEligible,
        );
      }

      final outcome = await _coordinator.runAutomatic<_AutomaticExchangeResult>(
        domain: domain,
        account: account,
        exchange: (ticket, token) => _exchange(
          domain,
          account: account,
          password: password,
          ticket: ticket,
          token: token,
        ),
        receiptOf: (value) => value.receipt,
      );

      if (outcome.decision == AuthRecoveryDecision.exchangeFailed) {
        // 所有终态失败都是瞬时失败：只推进 1/2/5 分钟退避阶梯，绝不累计
        // 身份失败计数（OCR 认错 ≠ 身份错）。
        await _coordinator.recordTransientFailure(
          domain,
          kind: (outcome.value?.ocrUnrecognized ?? false)
              ? AuthFailureKind.captchaRejected
              : AuthFailureClassifier.fromTransport(outcome.error),
        );
      }
      return AutomaticLoginAttemptResult(
        outcome: _mapDecision(outcome.decision),
        receipt: outcome.decision == AuthRecoveryDecision.committed
            ? outcome.receipt
            : null,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '静默自动登录执行失败（${domain.wireName}）',
        error: error,
        stackTrace: stackTrace,
      );
      return const AutomaticLoginAttemptResult(
        outcome: AutomaticLoginOutcome.failed,
      );
    }
  }

  /// 每域一次交换：prepare → 固定位数 OCR → 带 ticket 的真实 challenge 提交。
  Future<_AutomaticExchangeResult> _exchange(
    AuthRecoveryDomain domain, {
    required String account,
    required String password,
    required AuthRecoveryTicket ticket,
    required CancelToken token,
  }) async {
    switch (domain) {
      case AuthRecoveryDomain.cas:
        final challenge = await UnifiedAuthService.instance
            .prepareCaptchaChallenge(cancelToken: token);
        final captcha = await _recognize(challenge, casCaptchaLength);
        if (captcha == null) {
          return const _AutomaticExchangeResult(ocrUnrecognized: true);
        }
        final result = await UnifiedAuthService.instance.submitCaptchaChallenge(
          challengeId: challenge.id,
          username: account,
          password: password,
          captcha: captcha,
          cancelToken: token,
          recoveryTicket: ticket,
          // 自动路径显式禁止 WebView cookie 同步。
          syncWebViewCookies: false,
        );
        return _AutomaticExchangeResult(
          receipt: result is UnifiedAuthLoginSuccess ? result.receipt : null,
        );
      case AuthRecoveryDomain.academic:
        final challenge = await ZhengfangAuth.instance.prepareCaptchaChallenge(
          cancelToken: token,
        );
        final captcha = await _recognize(challenge, academicCaptchaLength);
        if (captcha == null) {
          return const _AutomaticExchangeResult(ocrUnrecognized: true);
        }
        final result = await ZhengfangAuth.instance.submitCaptchaChallenge(
          challengeId: challenge.id,
          username: account,
          password: password,
          captcha: captcha,
          cancelToken: token,
          recoveryTicket: ticket,
        );
        return _AutomaticExchangeResult(
          receipt: result is LoginSuccess ? result.receipt : null,
        );
    }
  }

  /// 单次 OCR：只按域固定位数调用一次，返回 null 即视为未识别。
  Future<String?> _recognize(
    CaptchaChallenge challenge,
    int expectedLength,
  ) async {
    final recognition = await _recognizer.recognize(
      challenge.bytes,
      expectedLength: expectedLength,
    );
    return recognition?.text;
  }

  Future<(String, String)?> _loadCredentials(AuthRecoveryDomain domain) =>
      switch (domain) {
        AuthRecoveryDomain.cas =>
          CredentialStore.instance.loadUnifiedAuthCredentials(),
        AuthRecoveryDomain.academic =>
          CredentialStore.instance.loadCredentials(),
      };

  AutomaticLoginOutcome _mapDecision(
    AuthRecoveryDecision decision,
  ) => switch (decision) {
    AuthRecoveryDecision.committed => AutomaticLoginOutcome.committed,
    AuthRecoveryDecision.manualRequired => AutomaticLoginOutcome.manualRequired,
    AuthRecoveryDecision.cooldown ||
    AuthRecoveryDecision.manualHoldActive => AutomaticLoginOutcome.cooldown,
    AuthRecoveryDecision.busy => AutomaticLoginOutcome.busy,
    AuthRecoveryDecision.disabled ||
    AuthRecoveryDecision.revoked ||
    AuthRecoveryDecision.accountMismatch => AutomaticLoginOutcome.notEligible,
    AuthRecoveryDecision.proceed ||
    AuthRecoveryDecision.exchangeFailed ||
    AuthRecoveryDecision.ticketRejected ||
    AuthRecoveryDecision.aborted => AutomaticLoginOutcome.failed,
  };
}
