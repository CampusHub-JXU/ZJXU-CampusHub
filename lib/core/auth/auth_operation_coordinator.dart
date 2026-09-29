import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';

import 'auth_failure.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'credential_store.dart';
import 'isolated_auth_session.dart';

/// 自动恢复的结果判定。[AuthRecoveryDecision.committed] 才是「已成功提交」；
/// 交换失败与提交被拒是独立结果，不能用同一个 `proceed` 掩盖。
enum AuthRecoveryDecision {
  /// 内部资格判定通过（不会作为最终 outcome 返回）。
  proceed,

  /// 交换成功且 commit 回调完成（唯一 didCommit 为 true 的值）。
  committed,

  /// 交换执行了但结果不成功或抛错（未提交）。
  exchangeFailed,

  /// 交换成功但 commit 前持久 ticket 校验失败（被撤销/epoch 变化/人工持有抢占）。
  ticketRejected,

  /// 取消不合作的交换在 abort 窗口内仍未结束，本次让位（同 isolate 内该
  /// 交换真正结束前不会再开始第二次交换）。
  aborted,

  disabled,
  revoked,
  cooldown,

  /// 人工验证码持有窗口未过期，本次跳过。
  manualHoldActive,

  /// 身份失败累计达到阈值，自动登录**已暂停**：guard 侧应提示用户手动登录，
  /// **不得**静默循环重试。手动成功（`recordSuccess`）后重新武装。
  manualRequired,

  accountMismatch,

  /// 同 isolate 内该域已有交换在运行，本次跳过。
  busy,
}

/// 取消不合作的交换到达 abort 窗口时抛出的内部信号。
class _ExchangeHandle {
  _ExchangeHandle(this.token);

  final CancelToken token;

  /// 被人工登录接管取消（区别于 deadline/调用方取消）。
  bool preempted = false;
}

class _ExchangeAborted implements Exception {
  const _ExchangeAborted();

  @override
  String toString() => 'automatic exchange aborted (abort window exceeded)';
}

enum AuthRecoveryEnableResult { enabled, credentialsMissing, accountMismatch }

/// 一次自动事务的结果。[didCommit] 仅在真正提交成功时为 true。
class AuthAutomaticOutcome<T> {
  const AuthAutomaticOutcome({
    required this.decision,
    this.value,
    this.ticket,
    this.receipt,
    this.error,
  });

  final AuthRecoveryDecision decision;
  final T? value;
  final AuthRecoveryTicket? ticket;

  /// 真实 challenge 提交产出的 typed receipt（仅 [decision] 为 committed 时
  /// 非空）。自动恢复层不再自己写身份/metadata，只接受该句柄。
  final SessionCommitResult? receipt;
  final Object? error;

  bool get didCommit => decision == AuthRecoveryDecision.committed;
  bool get didExchange =>
      decision == AuthRecoveryDecision.committed ||
      decision == AuthRecoveryDecision.exchangeFailed ||
      decision == AuthRecoveryDecision.ticketRejected ||
      decision == AuthRecoveryDecision.aborted;
}

/// 认证事务协调器（阶段 2 使用）。
///
/// - 交换前与 commit 前各校验一次持久 ticket；commit 回调只在两次校验都
///   通过后执行，因此身份/metadata 副作用永不早于 ticket 验证。
/// - 交换有硬 deadline，到期通过 [CancelToken] 取消底层 Dio；对取消不合作的
///   交换另有一个 abort 窗口，到期返回 [AuthRecoveryDecision.aborted]。
/// - 人工验证码持有窗口期间自动恢复跳过。
///
/// ## 新不变量：自动登录仅前台单 isolate 发起
/// **workmanager 后台 isolate 不得发起 CAS / 教务登录**（后台只做纯 Dio 的
/// 信息刷新与通知）。因此本协调器**不再**用持久交换 lease 假装跨 isolate
/// 互斥：跨 isolate 的状态互斥由 `AuthFileLock` 的短 RMW 收敛，同 isolate
/// 非重入由 [_runningExchanges] 保证。若将来需要后台登录，必须重新引入真正的
/// 跨 isolate 协调，而不是恢复「过期即接管」的 lease。
///
/// ## 固定加锁顺序
/// 不跨 await 持有文件锁；每个 store 调用内部短暂持状态锁。无反向顺序。
///
/// ## 跨 isolate CookieJar 风险（未消除，必须遵守上述不变量）
/// 持久 epoch/ticket **不能**消除跨 isolate `PersistCookieJar` 的内存镜像陈旧
/// 与文件竞争。所有登录/Cookie 交换只能来自前台单 isolate；后台不发起登录，
/// 从根上避免并发写 Cookie。
class AuthOperationCoordinator {
  AuthOperationCoordinator._({
    required AuthRecoveryStateStore stateStore,
    Future<Directory> Function()? directoryProvider,
  }) : _store = stateStore,
       debugDirectoryProvider = directoryProvider;

  static final AuthOperationCoordinator instance = AuthOperationCoordinator._(
    stateStore: AuthRecoveryStateStore.instance,
  );

  @visibleForTesting
  static AuthOperationCoordinator debugNew({
    required AuthRecoveryStateStore store,
    required Future<Directory> Function() directoryProvider,
  }) => AuthOperationCoordinator._(
    stateStore: store,
    directoryProvider: directoryProvider,
  );

  final AuthRecoveryStateStore _store;

  /// 同 isolate 内正在运行的交换域；用于「取消不合作的交换真正结束前不得
  /// 开始第二次交换」的保证。这是**唯一**的运行时非重入机制（跨 isolate 由
  /// 前台单 isolate 不变量 + `AuthFileLock` 短 RMW 收敛）。
  final Set<AuthRecoveryDomain> _runningExchanges = <AuthRecoveryDomain>{};

  /// 正在运行的自动交换句柄；人工登录开始时据此**立即取消**在途自动交换，
  /// 否则它会在后台继续 prepare/提交（最长 deadline 90s），顶掉用户的验证码。
  final Map<AuthRecoveryDomain, _ExchangeHandle> _activeExchanges =
      <AuthRecoveryDomain, _ExchangeHandle>{};

  /// 连续瞬时失败计数（前台单 isolate 内存态，不持久化），用于 1/2/5 分钟
  /// 退避阶梯；成功或凭据变更时清零。
  final Map<AuthRecoveryDomain, int> _transientFailures =
      <AuthRecoveryDomain, int>{};

  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;

  @visibleForTesting
  Future<(String, String)?> Function(AuthRecoveryDomain domain)?
  debugCredentialLoader;

  @visibleForTesting
  void debugReset() {
    debugDirectoryProvider = null;
    debugCredentialLoader = null;
    _runningExchanges.clear();
    _activeExchanges.clear();
    _transientFailures.clear();
    for (final timer in _manualTimers.values) {
      timer.cancel();
    }
    _manualTimers.clear();
    _manualHolders.clear();
  }

  // ── opt-in / 退出 / 失败 ──────────────────────────────────────────

  Future<AuthRecoveryEnableResult> enableAutomaticRecovery(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
  }) async {
    final credentials = await _loadCredentials(domain);
    if (credentials == null) return AuthRecoveryEnableResult.credentialsMissing;
    final account = credentials.$1.trim();
    if (account.isEmpty) return AuthRecoveryEnableResult.credentialsMissing;
    if (expectedAccount != null && expectedAccount.trim() != account) {
      return AuthRecoveryEnableResult.accountMismatch;
    }
    final record = await _store.read(domain);
    await _store.enable(
      domain,
      account: account,
      credentialRevision: record.credentialRevision,
    );
    return AuthRecoveryEnableResult.enabled;
  }

  Future<void> disableAutomaticRecovery(AuthRecoveryDomain domain) =>
      _store.disable(domain);

  /// 显式登出 vs 业务过期的语义区分由 [AuthLogoutKind] 保证。
  Future<void> recordLogout(
    AuthRecoveryDomain domain, {
    required AuthLogoutKind kind,
  }) => _store.recordLogout(domain, kind: kind);

  /// 记录一次**瞬时/识别失败**（OCR 未识别、验证码被拒、网络、超时等）。
  ///
  /// **OCR 认错 ≠ 身份错**：只按 1/2/5 分钟阶梯推进冷却，**不**累计身份失败
  /// 计数，因此连续识别失败不会把用户推进「需手动登录」。`cooldown` 显式给出
  /// 时优先于阶梯。
  Future<void> recordTransientFailure(
    AuthRecoveryDomain domain, {
    required AuthFailureKind kind,
    Duration? cooldown,
  }) async {
    final attempt = (_transientFailures[domain] ?? 0) + 1;
    _transientFailures[domain] = attempt;
    await _store.recordTransientFailure(
      domain,
      kind: kind,
      now: DateTime.now(),
      cooldown: cooldown ?? AuthRecoveryStateStore.transientBackoffFor(attempt),
    );
  }

  /// 记录一次**身份失败**（服务端明确判定账号/密码错误）。
  ///
  /// 只有调用方明确判定为身份错误时才可调用（不得由 [AuthFailureKind] 自动
  /// 推断）；累计达到阈值后 [automaticEligibility] 返回
  /// [AuthRecoveryDecision.manualRequired]。
  Future<void> recordIdentityFailure(
    AuthRecoveryDomain domain, {
    required AuthFailureKind kind,
    Duration? cooldown,
  }) => _store.recordIdentityFailure(
    domain,
    kind: kind,
    now: DateTime.now(),
    cooldown: cooldown,
  );

  /// 自动或手动成功：清零身份失败计数与冷却，重新武装自动恢复。
  Future<void> recordSuccess(AuthRecoveryDomain domain) async {
    _transientFailures.remove(domain);
    await _store.recordSuccess(domain);
  }

  Future<void> onCredentialsChanged(AuthRecoveryDomain domain) async {
    _transientFailures.remove(domain);
    await _store.onCredentialsChanged(domain);
  }

  // ── 人工验证码持有窗口 ───────────────────────────────────────────

  /// 开始/延长人工验证码持有窗口；自动恢复遇到未过期窗口必须跳过。
  Future<void> beginManualAttempt(
    AuthRecoveryDomain domain, {
    Duration ttl = AuthRecoveryStateStore.defaultManualHoldTtl,
  }) async {
    await _store.beginManualHold(domain, ttl: ttl);
  }

  /// 结束人工持有窗口（无条件清除，无 token 协议）。
  Future<void> endManualAttempt(AuthRecoveryDomain domain) =>
      _store.endManualHold(domain);

  final _manualHolders = <AuthRecoveryDomain, int>{};
  final _manualTimers = <AuthRecoveryDomain, Timer>{};

  Duration _failureCooldown(AuthRecoveryDomain domain, Duration? specified) {
    final failures = (_transientFailures[domain] ?? 0) + 1;
    _transientFailures[domain] = failures;
    return specified ?? AuthRecoveryStateStore.transientBackoffFor(failures);
  }

  /// 页面持有人工验证码期间续租；多个页面关闭其中一个不会释放另一个的窗口。
  ///
  /// 获取时若同域有在途自动交换，立即取消它（记为被人工接管：只清 ticket，
  /// 不计失败、不冷却）。
  Future<void> Function() acquireManualAttempt(AuthRecoveryDomain domain) {
    _manualHolders[domain] = (_manualHolders[domain] ?? 0) + 1;
    final active = _activeExchanges[domain];
    if (active != null && !active.token.isCancelled) {
      active.preempted = true;
      active.token.cancel('manual login took over');
      AppLogger.instance.auth(
        LogLevel.info,
        '人工登录开始，取消在途自动恢复（${domain.wireName}）',
      );
    }
    unawaited(_persistManualHold(domain));
    _manualTimers.putIfAbsent(
      domain,
      () => Timer.periodic(const Duration(minutes: 1), (_) {
        unawaited(_persistManualHold(domain));
      }),
    );
    var released = false;
    return () async {
      if (released) return;
      released = true;
      final remaining = (_manualHolders[domain] ?? 1) - 1;
      if (remaining > 0) {
        _manualHolders[domain] = remaining;
      } else {
        _manualHolders.remove(domain);
        _manualTimers.remove(domain)?.cancel();
        try {
          await endManualAttempt(domain);
        } catch (error, stackTrace) {
          AppLogger.instance.auth(
            LogLevel.warn,
            '人工登录窗口释放失败，等待持久 TTL',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    };
  }

  Future<void> _persistManualHold(AuthRecoveryDomain domain) async {
    try {
      await beginManualAttempt(domain);
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '人工登录窗口持久化失败，保留前台互斥',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  // ── 资格 / ticket ────────────────────────────────────────────────

  Future<AuthRecoveryDecision> automaticEligibility(
    AuthRecoveryDomain domain, {
    required String account,
    DateTime? now,
  }) => _eligibility(domain, account: account, now: now);

  Future<bool> verifyTicketForCommit(
    AuthRecoveryTicket ticket, {
    DateTime? now,
  }) async {
    if (_manualHolders.containsKey(ticket.domain)) return false;
    final valid = await _store.verifyTicket(ticket, now: now);
    return valid && !_manualHolders.containsKey(ticket.domain);
  }

  /// 受约束的隔离会话提交：在**同一次状态锁内**重新校验 ticket，再做
  /// durable-epoch 条件提交，并把隔离 challenge 会话的 cookie 合并回 [target]。
  ///
  /// 这是**自动恢复路径唯一允许的登录提交点**（真实 challenge 提交调用它）：
  /// - 账号只取 `ticket.account`，[sessionDomain] 必须与 ticket 所属域一致，
  ///   不一致直接拒绝；
  /// - 提交在恢复状态锁 → 会话锁的固定顺序内完成，没有任何可由调用方注入的
  ///   回调/副作用，锁内不发网络；
  /// - ticket 不匹配（撤销 / 被新 ticket 取代 / 人工持有 / epoch 变化）或
  ///   durable epoch 不符时返回 null，且**不合并任何 cookie、不写 metadata**。
  ///
  /// 成功返回真实 [SessionCommitResult]（含新 epoch），调用方必须把它作为
  /// receipt 回传，禁止用 bool 代替「已提交」。
  Future<SessionCommitResult?> commitIsolatedSessionForTicket(
    AuthRecoveryTicket ticket, {
    required int expectedSessionEpoch,
    required CredentialSessionDomain sessionDomain,
    required IsolatedAuthSession session,
    required CookieJar target,
  }) async {
    if (_manualHolders.containsKey(ticket.domain)) return null;
    if (_sessionDomainFor(ticket.domain) != sessionDomain) return null;
    return _store.withVerifiedTicket<SessionCommitResult?>(
      ticket,
      action: () => _manualHolders.containsKey(ticket.domain)
          ? Future<SessionCommitResult?>.value()
          : AuthSessionPersistence.instance.commitWithIsolatedSession(
              sessionDomain,
              account: ticket.account,
              expectedEpoch: expectedSessionEpoch,
              session: session,
              target: target,
            ),
    );
  }

  CredentialSessionDomain _sessionDomainFor(AuthRecoveryDomain domain) =>
      switch (domain) {
        AuthRecoveryDomain.cas => CredentialSessionDomain.unified,
        AuthRecoveryDomain.academic => CredentialSessionDomain.academic,
      };

  /// 执行一次有界自动事务。
  ///
  /// [exchange] 接收持久 ticket 与**硬 deadline 取消 token**；网络请求应把
  /// 该 token 传给 Dio（协作取消），并驱动**真实 challenge 提交**（把
  /// [AuthRecoveryTicket] 传给 `submitCaptchaChallenge`）。自动恢复层**不再**
  /// 做第二次身份/metadata 提交：唯一提交点是真实 challenge 提交里的
  /// [commitIsolatedSessionForTicket]，它产出的 [SessionCommitResult] 由
  /// [receiptOf] 从交换结果中取出。
  ///
  /// 判定规则：**没有真实 receipt 绝不 `committed`**；receipt 存在时还会在
  /// 状态锁内复核 ticket 未被撤销、且 receipt 仍是当前 durable 身份
  /// （account + epoch），任一不成立都不得 report committed，也绝不 revoke
  /// 后来居上的新会话。
  ///
  /// 取消不合作的交换：到 [exchangeAbortAfter]（默认 deadline+30s）仍未结束
  /// 则返回 [AuthRecoveryDecision.aborted]；且同 isolate 内在该交换真正结束前
  /// 不会再开始第二次交换（[busy]）。running 覆盖整个事务直到 ticket 完成。
  ///
  /// timeout / 传输错误 / 无 receipt 按失败类型退避；明确凭据错误累计身份
  /// 失败。调用方主动取消只清除本次 ticket，不记失败或冷却。
  ///
  /// **新不变量（重要）**：自动登录仅前台单 isolate 发起，workmanager 不发起
  /// CAS/教务登录。因此这里不做任何跨 isolate 互斥，只保证同 isolate 非重入。
  /// 每个 [exchange] 仍**必须** cancellation-safe 且独立有界：把 token 贯穿到
  /// Dio/OCR，并返回 timeout/aborted 结果；自动恢复保持 opt-in，且只允许已验证
  /// 的 Dio/OCR 操作。
  ///
  /// [rethrowExchangeErrors] 为 true 时交换异常向上抛，否则归入
  /// [AuthRecoveryDecision.exchangeFailed] 并附带 [AuthAutomaticOutcome.error]。
  Future<AuthAutomaticOutcome<T>> runAutomatic<T>({
    required AuthRecoveryDomain domain,
    required String account,
    required Future<T> Function(AuthRecoveryTicket ticket, CancelToken token)
    exchange,
    required SessionCommitResult? Function(T value) receiptOf,
    AuthFailureKind Function(T value)? failureOf,
    CancelToken? callerCancelToken,
    Duration? recoveryCooldown,
    Duration exchangeDeadline = const Duration(seconds: 90),
    Duration? exchangeAbortAfter,
    bool rethrowExchangeErrors = false,
    DateTime? now,
  }) async {
    final effectiveAbortAfter =
        exchangeAbortAfter ?? exchangeDeadline + const Duration(seconds: 30);

    // 同 isolate 非重入：取消不合作的交换真正结束前不再开始第二次。
    if (_runningExchanges.contains(domain)) {
      return const AuthAutomaticOutcome(decision: AuthRecoveryDecision.busy);
    }
    _runningExchanges.add(domain);
    // running 必须覆盖整个事务（含 ticket 完成），且若交换在 deadline 后仍不
    // 结束，则一直保留到它真实结束，不能因事务体返回就提前重入。
    var runFinished = false;
    var exchangePending = false;
    void releaseRunningIfSettled() {
      if (runFinished && !exchangePending) {
        _runningExchanges.remove(domain);
      }
    }

    try {
      if (callerCancelToken?.isCancelled ?? false) {
        return const AuthAutomaticOutcome(
          decision: AuthRecoveryDecision.aborted,
        );
      }
      final decision = await _eligibility(domain, account: account, now: now);
      if (decision != AuthRecoveryDecision.proceed) {
        return AuthAutomaticOutcome<T>(decision: decision);
      }

      final ticket = await _store.beginAttempt(
        domain,
        account: account,
        now: now,
      );
      if (ticket == null) {
        return const AuthAutomaticOutcome(
          decision: AuthRecoveryDecision.disabled,
        );
      }

      // 交换前校验：不通过则不做任何交换，更不产生副作用。
      if (!await _store.verifyTicket(ticket, now: now)) {
        await _store.clearTicket(domain, ticketId: ticket.id);
        return AuthAutomaticOutcome<T>(
          decision: AuthRecoveryDecision.ticketRejected,
          ticket: ticket,
        );
      }

      Future<AuthAutomaticOutcome<T>> abortCaller() async {
        await _store.clearTicket(domain, ticketId: ticket.id);
        return AuthAutomaticOutcome<T>(
          decision: AuthRecoveryDecision.aborted,
          ticket: ticket,
        );
      }

      if (callerCancelToken?.isCancelled ?? false) return await abortCaller();

      final cancelToken = CancelToken();
      final handle = _ExchangeHandle(cancelToken);
      _activeExchanges[domain] = handle;
      // 调用方取消或被人工接管：都只清 ticket，不计失败、不冷却。
      bool abandoned() =>
          handle.preempted || (callerCancelToken?.isCancelled ?? false);
      if (callerCancelToken != null) {
        if (callerCancelToken.isCancelled) {
          cancelToken.cancel('automatic caller cancelled');
        } else {
          unawaited(
            callerCancelToken.whenCancel.then((_) {
              if (!cancelToken.isCancelled) {
                cancelToken.cancel('automatic caller cancelled');
              }
            }),
          );
        }
      }
      Timer? deadlineTimer;
      if (exchangeDeadline > Duration.zero) {
        deadlineTimer = Timer(exchangeDeadline, () {
          if (!cancelToken.isCancelled) {
            cancelToken.cancel('automatic exchange deadline exceeded');
          }
        });
      }

      exchangePending = true;
      final exchangeFuture = exchange(ticket, cancelToken);
      // 无论 runAutomatic 是否提前返回，running 标记都只在**真实交换结束**、
      // 且事务体也已结束时才移除；这样取消不合作的交换不会让第二次交换并发进入。
      unawaited(() async {
        try {
          await exchangeFuture;
        } catch (_) {
          // 错误由下方 await/timeout 分支处理。
        } finally {
          deadlineTimer?.cancel();
          if (identical(_activeExchanges[domain], handle)) {
            _activeExchanges.remove(domain);
          }
          exchangePending = false;
          releaseRunningIfSettled();
        }
      }());

      T value;
      try {
        value = await exchangeFuture.timeout(
          effectiveAbortAfter,
          onTimeout: () {
            if (!cancelToken.isCancelled) {
              cancelToken.cancel('automatic exchange exceeded abort window');
            }
            throw const _ExchangeAborted();
          },
        );
      } on _ExchangeAborted {
        if (abandoned()) return await abortCaller();
        await _store.completeAttempt(
          domain,
          ticketId: ticket.id,
          success: false,
          scope: AuthFailureScope.transient,
          failureKind: AuthFailureKind.timeout,
          now: now,
          cooldown: _failureCooldown(domain, recoveryCooldown),
        );
        return AuthAutomaticOutcome<T>(
          decision: AuthRecoveryDecision.aborted,
          ticket: ticket,
          error: const _ExchangeAborted(),
        );
      } catch (error) {
        if (abandoned()) return await abortCaller();
        await _store.completeAttempt(
          domain,
          ticketId: ticket.id,
          success: false,
          scope: AuthFailureScope.transient,
          failureKind: AuthFailureClassifier.fromTransport(error),
          now: now,
          cooldown: _failureCooldown(domain, recoveryCooldown),
        );
        if (rethrowExchangeErrors) rethrow;
        return AuthAutomaticOutcome<T>(
          decision: AuthRecoveryDecision.exchangeFailed,
          ticket: ticket,
          error: error,
        );
      } finally {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('automatic exchange finished');
        }
      }

      if (callerCancelToken?.isCancelled ?? false) return await abortCaller();

      // 唯一提交点是真实 challenge 提交（typed ticket commit）；这里只接受它
      // 产出的真实 receipt，绝不用 bool 代表「已提交」，也不再二次写 metadata。
      final receipt = receiptOf(value);
      // 被人工接管且没有真实提交：只清 ticket，不把「被取消」记成失败。
      if (receipt == null && handle.preempted) return await abortCaller();
      if (receipt == null) {
        if (!await _store.verifyTicket(ticket, now: now)) {
          await _store.clearTicket(domain, ticketId: ticket.id);
          return AuthAutomaticOutcome<T>(
            decision: AuthRecoveryDecision.ticketRejected,
            value: value,
            ticket: ticket,
          );
        }
        final kind = failureOf?.call(value) ?? AuthFailureKind.unknown;
        final identityFailure = kind == AuthFailureKind.invalidCredentials;
        final failures = (_transientFailures[domain] ?? 0) + 1;
        if (!identityFailure) _transientFailures[domain] = failures;
        await _store.completeAttempt(
          domain,
          ticketId: ticket.id,
          success: false,
          scope: identityFailure
              ? AuthFailureScope.identity
              : AuthFailureScope.transient,
          failureKind: kind,
          now: now,
          cooldown:
              recoveryCooldown ??
              AuthRecoveryStateStore.transientBackoffFor(failures),
        );
        return AuthAutomaticOutcome<T>(
          decision: AuthRecoveryDecision.exchangeFailed,
          value: value,
          ticket: ticket,
        );
      }

      // 最终校验：ticket 未被撤销/被新 ticket 取代，且 receipt 仍是当前
      // durable 身份。任一不成立都不得 report committed；也绝不 revoke 后来者。
      // 身份检查走会话锁内条件读（固定顺序：恢复状态锁 → 会话锁），
      // 不会在锁内做网络。
      final identityCurrent = await _store.withVerifiedTicket<bool>(
        ticket,
        now: now,
        action: () async {
          final current = await AuthSessionPersistence.instance
              .withCurrentSession<bool>(
                _sessionDomainFor(ticket.domain),
                account: receipt.account,
                expectedEpoch: receipt.epoch,
                action: () async => true,
              );
          return current ?? false;
        },
      );
      if (identityCurrent != true) {
        await _store.clearTicket(domain, ticketId: ticket.id);
        return AuthAutomaticOutcome<T>(
          decision: AuthRecoveryDecision.ticketRejected,
          value: value,
          ticket: ticket,
          receipt: receipt,
        );
      }

      await _store.completeAttempt(
        domain,
        ticketId: ticket.id,
        success: true,
        scope: AuthFailureScope.transient,
      );
      _transientFailures.remove(domain);
      return AuthAutomaticOutcome<T>(
        decision: AuthRecoveryDecision.committed,
        value: value,
        ticket: ticket,
        receipt: receipt,
      );
    } finally {
      runFinished = true;
      releaseRunningIfSettled();
    }
  }

  // ── 内部 ────────────────────────────────────────────────────────

  Future<AuthRecoveryDecision> _eligibility(
    AuthRecoveryDomain domain, {
    required String account,
    DateTime? now,
  }) async {
    if (_manualHolders.containsKey(domain)) {
      return AuthRecoveryDecision.manualHoldActive;
    }
    final record = await _store.read(domain);
    final effectiveNow = now ?? DateTime.now();
    if (record.revoked) return AuthRecoveryDecision.revoked;
    if (!record.optIn) return AuthRecoveryDecision.disabled;
    if (record.account != account) return AuthRecoveryDecision.accountMismatch;
    // 身份失败达到阈值：暂停自动登录，必须让用户手动登录（不得静默重试）。
    if (record.failureCount >=
        AuthRecoveryStateStore.identityFailurePauseThreshold) {
      return AuthRecoveryDecision.manualRequired;
    }
    if (record.cooldownActiveAt(effectiveNow)) {
      return AuthRecoveryDecision.cooldown;
    }
    if (record.manualHoldActiveAt(effectiveNow)) {
      return AuthRecoveryDecision.manualHoldActive;
    }
    return AuthRecoveryDecision.proceed;
  }

  Future<(String, String)?> _loadCredentials(AuthRecoveryDomain domain) async {
    final override = debugCredentialLoader;
    if (override != null) return override(domain);
    switch (domain) {
      case AuthRecoveryDomain.cas:
        return CredentialStore.instance.loadUnifiedAuthCredentials();
      case AuthRecoveryDomain.academic:
        return CredentialStore.instance.loadCredentials();
    }
  }
}
