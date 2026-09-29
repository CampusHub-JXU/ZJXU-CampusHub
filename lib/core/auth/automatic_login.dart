import 'dart:async';

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
import 'connect_mode_resolver.dart';
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
  const _AutomaticExchangeResult({
    this.receipt,
    this.ocrUnrecognized = false,
    this.failureKind = AuthFailureKind.unknown,
  });

  final SessionCommitResult? receipt;

  /// OCR 未能给出答案：按瞬时失败退避（绝不猜、绝不重复识别）。
  final bool ocrUnrecognized;
  final AuthFailureKind failureKind;
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

class _AutomaticLoginFlight {
  final token = CancelToken();
  late final Future<AutomaticLoginAttemptResult> result;
  int waiters = 0;
  bool settled = false;
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

  final _pending =
      <(AuthRecoveryDomain, String?, int, int), _AutomaticLoginFlight>{};
  final _tokens = <CancelToken>{};
  bool _foreground = true;

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) {
      _generation++;
      for (final token in _tokens.toList()) {
        token.cancel('application left foreground');
      }
    }
  }

  /// 取消未完成交换并复位前台状态，便于测试隔离。
  @visibleForTesting
  void debugReset() {
    setForeground(false);
    _pending.clear();
    _tokens.clear();
    _foreground = true;
  }

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
  }) {
    if (!_foreground || (cancelToken?.isCancelled ?? false)) {
      return Future.value(
        const AutomaticLoginAttemptResult(
          outcome: AutomaticLoginOutcome.failed,
        ),
      );
    }
    // 在首个 await 之前占位；身份变化后的请求不能加入旧登录事务。
    final key = (
      domain,
      expectedAccount,
      domain == AuthRecoveryDomain.cas
          ? UnifiedAuthService.instance.sessionRevision
          : ZhengfangAuth.instance.sessionRevision,
      _generation,
    );
    final flight = _pending.putIfAbsent(key, () {
      final flight = _AutomaticLoginFlight();
      _tokens.add(flight.token);
      flight.result =
          _attempt(
            domain,
            expectedAccount: expectedAccount,
            cancelToken: flight.token,
          ).whenComplete(() {
            flight.settled = true;
            if (identical(_pending[key], flight)) _pending.remove(key);
            _tokens.remove(flight.token);
          });
      return flight;
    });
    flight.waiters++;
    final waiter = Completer<AutomaticLoginAttemptResult>();
    var released = false;
    void releaseWaiter() {
      if (released) return;
      released = true;
      flight.waiters--;
      if (flight.waiters == 0 && !flight.settled) {
        if (identical(_pending[key], flight)) _pending.remove(key);
        flight.token.cancel('all automatic callers cancelled');
      }
    }

    unawaited(
      flight.result.then((result) {
        if (!waiter.isCompleted) {
          waiter.complete(result);
          releaseWaiter();
        }
      }),
    );
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) {
          if (!waiter.isCompleted) {
            waiter.complete(
              const AutomaticLoginAttemptResult(
                outcome: AutomaticLoginOutcome.failed,
              ),
            );
            releaseWaiter();
          }
        }),
      );
    }
    return waiter.future;
  }

  int _generation = 0;

  Future<AutomaticLoginAttemptResult> _attempt(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
    required CancelToken cancelToken,
  }) async {
    try {
      final credentials = await _loadCredentials(domain);
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
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
        failureOf: (value) => value.ocrUnrecognized
            ? AuthFailureKind.captchaRejected
            : value.failureKind,
        callerCancelToken: cancelToken,
      );
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
          failureKind: result is UnifiedAuthLoginFailure
              ? result.kind
              : AuthFailureKind.unknown,
        );
      case AuthRecoveryDomain.academic:
        final auth = ZhengfangAuth.instance;
        final mode = await ConnectModeResolver.instance.resolve(
          targetUrl: ZhengfangAuth.directAcademicServiceUrl,
        );
        if (token.isCancelled) throw token.cancelError!;
        if (mode == null) {
          return const _AutomaticExchangeResult(
            failureKind: AuthFailureKind.networkUnavailable,
          );
        }
        // 不改全局模式：模式只绑定到本次 challenge，提交成功后才由
        // ZhengfangAuth 收敛全局模式，避免打断用户正在进行的人工登录。
        if (mode == ZhengfangMode.webVpn) {
          var ready = await auth.ensureWebVpnGatewaySession(
            syncWebViewCookies: false,
          );
          if (ready != true) {
            await attemptWithReceipt(
              AuthRecoveryDomain.cas,
              expectedAccount: UnifiedAuthService.instance.currentAccount,
              cancelToken: token,
            );
            if (token.isCancelled) throw token.cancelError!;
            ready = await auth.ensureWebVpnGatewaySession(
              syncWebViewCookies: false,
            );
          }
          if (ready != true) {
            return const _AutomaticExchangeResult(
              failureKind: AuthFailureKind.networkUnavailable,
            );
          }
        }
        final challenge = await auth.prepareCaptchaChallenge(
          cancelToken: token,
          mode: mode,
          automatic: true,
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
          failureKind: result is LoginFailure
              ? result.kind
              : AuthFailureKind.unknown,
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
