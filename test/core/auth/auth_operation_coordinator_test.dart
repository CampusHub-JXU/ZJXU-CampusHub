import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/isolated_auth_session.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('auth_op_coordinator_test_');

/// 通过协调器的 typed ticket commit 走一次真实的隔离会话提交，返回 receipt。
/// 这是自动恢复路径唯一允许的登录提交点；测试用它模拟真实 challenge 提交。
Future<SessionCommitResult?> _typedCommit(
  AuthOperationCoordinator coordinator,
  AuthRecoveryTicket ticket, {
  required CredentialSessionDomain domain,
  required int expectedEpoch,
}) async {
  final session = await IsolatedAuthSession.create(
    sourceJar: CookieJar(),
    seedUris: [Uri.parse('https://newca.zjxu.edu.cn/')],
    template: Dio(),
  );
  return coordinator.commitIsolatedSessionForTicket(
    ticket,
    expectedSessionEpoch: expectedEpoch,
    sessionDomain: domain,
    session: session,
    target: CookieJar(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late AuthRecoveryStateStore store;
  late AuthOperationCoordinator coordinator;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
    dir = await _tempDir();
    store = AuthRecoveryStateStore.debugNew(directoryProvider: () async => dir);
    coordinator = AuthOperationCoordinator.debugNew(
      store: store,
      directoryProvider: () async => dir,
    );
  });

  tearDown(() async {
    AuthSessionPersistence.instance.debugReset();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> enable() =>
      store.enable(AuthRecoveryDomain.cas, account: 'A', credentialRevision: 0);

  Future<SessionCommitResult?> commitViaExchange(
    AuthRecoveryTicket ticket,
  ) async {
    final epoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );
    return _typedCommit(
      coordinator,
      ticket,
      domain: CredentialSessionDomain.unified,
      expectedEpoch: epoch,
    );
  }

  test('enable requires saved credentials for the matching domain', () async {
    coordinator.debugCredentialLoader = (_) async => null;
    expect(
      await coordinator.enableAutomaticRecovery(AuthRecoveryDomain.cas),
      AuthRecoveryEnableResult.credentialsMissing,
    );

    coordinator.debugCredentialLoader = (_) async => ('A', 'pw');
    expect(
      await coordinator.enableAutomaticRecovery(
        AuthRecoveryDomain.cas,
        expectedAccount: 'B',
      ),
      AuthRecoveryEnableResult.accountMismatch,
    );
    expect(
      await coordinator.enableAutomaticRecovery(AuthRecoveryDomain.cas),
      AuthRecoveryEnableResult.enabled,
    );
    expect((await store.read(AuthRecoveryDomain.cas)).optIn, isTrue);
  });

  test('eligibility reflects disabled/revoked/manual hold', () async {
    expect(
      await coordinator.automaticEligibility(
        AuthRecoveryDomain.cas,
        account: 'A',
      ),
      AuthRecoveryDecision.disabled,
    );

    await enable();
    expect(
      await coordinator.automaticEligibility(
        AuthRecoveryDomain.cas,
        account: 'A',
      ),
      AuthRecoveryDecision.proceed,
    );

    await coordinator.beginManualAttempt(AuthRecoveryDomain.cas);
    expect(
      await coordinator.automaticEligibility(
        AuthRecoveryDomain.cas,
        account: 'A',
      ),
      AuthRecoveryDecision.manualHoldActive,
    );
    await coordinator.endManualAttempt(AuthRecoveryDomain.cas);

    await coordinator.recordLogout(
      AuthRecoveryDomain.cas,
      kind: AuthLogoutKind.explicitUserLogout,
    );
    expect(
      await coordinator.automaticEligibility(
        AuthRecoveryDomain.cas,
        account: 'A',
      ),
      AuthRecoveryDecision.revoked,
    );
  });

  test('skips when disabled without calling exchange', () async {
    var exchangeCalls = 0;
    final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: (_, _) async {
        exchangeCalls++;
        return null;
      },
      receiptOf: (value) => value,
    );
    expect(outcome.decision, AuthRecoveryDecision.disabled);
    expect(outcome.didCommit, isFalse);
    expect(exchangeCalls, 0);
  });

  test(
    'commits only for a real receipt produced inside the exchange',
    () async {
      await enable();

      AuthRecoveryTicket? seenTicket;
      var verifiedBeforeExchange = false;
      final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
        domain: AuthRecoveryDomain.cas,
        account: 'A',
        exchange: (ticket, token) async {
          seenTicket = ticket;
          expect(token.isCancelled, isFalse);
          verifiedBeforeExchange = await coordinator.verifyTicketForCommit(
            ticket,
          );
          return commitViaExchange(ticket);
        },
        receiptOf: (value) => value,
      );

      expect(outcome.decision, AuthRecoveryDecision.committed);
      expect(outcome.didCommit, isTrue);
      expect(outcome.receipt, isNotNull);
      expect(outcome.receipt!.account, 'A');
      expect(seenTicket, isNotNull);
      expect(verifiedBeforeExchange, isTrue);
      expect(
        (await CredentialStore.instance.readSessionEnvelope(
          CredentialSessionDomain.unified,
        )).active,
        isTrue,
      );
      final record = await store.read(AuthRecoveryDomain.cas);
      expect(record.activeAttempt, isNull);
      expect(record.manualHoldUntil, isNull);
    },
  );

  test('revocation mid-exchange rejects the commit', () async {
    await enable();

    final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: (ticket, token) async {
        await coordinator.recordLogout(
          AuthRecoveryDomain.cas,
          kind: AuthLogoutKind.explicitUserLogout,
        );
        // typed commit 在状态锁内重新校验 ticket：撤销后返回 null（无 receipt）。
        return commitViaExchange(ticket);
      },
      receiptOf: (value) => value,
    );

    expect(outcome.decision, AuthRecoveryDecision.ticketRejected);
    expect(outcome.didCommit, isFalse);
    expect(outcome.receipt, isNull);
    expect(
      (await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      )).active,
      isFalse,
      reason: '被撤销的 ticket 不得写入会话',
    );
    expect((await store.read(AuthRecoveryDomain.cas)).activeAttempt, isNull);
  });

  test('unsuccessful exchange is a separate exchangeFailed outcome', () async {
    await enable();
    final epochBefore = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );
    final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: (_, _) async => null,
      receiptOf: (value) => value,
    );
    expect(outcome.decision, AuthRecoveryDecision.exchangeFailed);
    expect(outcome.didCommit, isFalse);
    expect(outcome.value, isNull);
    expect(
      (await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      )).active,
      isFalse,
    );
    expect(
      await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      ),
      epochBefore,
      reason: 'runAutomatic 不得自己二次提交 metadata',
    );
    expect((await store.read(AuthRecoveryDomain.cas)).failureCount, 0);
    expect(
      (await store.read(AuthRecoveryDomain.cas)).cooldownUntil,
      isNotNull,
      reason: '瞬时/未知失败只退避，不计身份失败',
    );
  });

  test(
    'exchange throw becomes exchangeFailed unless rethrow requested',
    () async {
      await enable();
      final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
        domain: AuthRecoveryDomain.cas,
        account: 'A',
        exchange: (_, _) async => throw StateError('boom'),
        receiptOf: (value) => value,
      );
      expect(outcome.decision, AuthRecoveryDecision.exchangeFailed);
      expect(outcome.error, isA<StateError>());
      expect((await store.read(AuthRecoveryDomain.cas)).activeAttempt, isNull);

      await expectLater(
        coordinator.runAutomatic<SessionCommitResult?>(
          domain: AuthRecoveryDomain.cas,
          account: 'A',
          exchange: (_, _) async => throw StateError('boom'),
          receiptOf: (value) => value,
          rethrowExchangeErrors: true,
          now: DateTime.now().add(const Duration(minutes: 6)),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('a concurrent run in the same isolate is busy', () async {
    await enable();
    final gate = Completer<void>();
    final started = Completer<void>();
    var exchangeStarts = 0;
    Future<SessionCommitResult?> heldExchange(
      AuthRecoveryTicket ticket,
      CancelToken token,
    ) async {
      exchangeStarts++;
      if (!started.isCompleted) started.complete();
      await gate.future;
      return commitViaExchange(ticket);
    }

    final firstFuture = coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: heldExchange,
      receiptOf: (value) => value,
      exchangeDeadline: const Duration(seconds: 5),
    );
    await started.future;

    final second = await coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: (_, _) async => null,
      receiptOf: (value) => value,
    );
    expect(second.decision, AuthRecoveryDecision.busy);
    expect(exchangeStarts, 1, reason: '同 isolate 不得并发第二次交换');

    gate.complete();
    final first = await firstFuture;
    expect(first.decision, AuthRecoveryDecision.committed);
  });

  test('exchange deadline cancels the token and fails the exchange', () async {
    await enable();
    final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: (ticket, token) {
        final completer = Completer<SessionCommitResult?>();
        token.whenCancel.then((_) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('cancelled'));
          }
        });
        return completer.future;
      },
      receiptOf: (value) => value,
      exchangeDeadline: const Duration(milliseconds: 30),
    );
    expect(outcome.decision, AuthRecoveryDecision.exchangeFailed);
    expect(outcome.error, isA<StateError>());
  });

  test(
    'commitIsolatedSessionForTicket re-verifies and commits conditionally',
    () async {
      await enable();
      final ticket = await store.beginAttempt(
        AuthRecoveryDomain.cas,
        account: 'A',
      );
      expect(ticket, isNotNull);
      final sessionEpoch = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );

      final result = await _typedCommit(
        coordinator,
        ticket!,
        domain: CredentialSessionDomain.unified,
        expectedEpoch: sessionEpoch,
      );
      expect(result, isNotNull);
      expect(result!.account, 'A');
      expect(result.epoch, sessionEpoch + 1);
      final envelope = await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      );
      expect(envelope.active, isTrue);
      expect(envelope.account, 'A');

      // 域与 ticket 不一致：拒绝，且不改写会话。
      final epochBeforeMismatch = await AuthSessionPersistence.instance
          .readEpoch(CredentialSessionDomain.unified);
      final mismatched = await _typedCommit(
        coordinator,
        ticket,
        domain: CredentialSessionDomain.academic,
        expectedEpoch: epochBeforeMismatch,
      );
      expect(mismatched, isNull);
      expect(
        await AuthSessionPersistence.instance.readEpoch(
          CredentialSessionDomain.unified,
        ),
        epochBeforeMismatch,
      );

      // 撤销恢复后 ticket 失效：再次提交必须拒绝且不改写会话。
      await store.recordLogout(
        AuthRecoveryDomain.cas,
        kind: AuthLogoutKind.explicitUserLogout,
      );
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );
      final rejected = await _typedCommit(
        coordinator,
        ticket,
        domain: CredentialSessionDomain.unified,
        expectedEpoch: epochBefore,
      );
      expect(rejected, isNull);
      expect(
        await AuthSessionPersistence.instance.readEpoch(
          CredentialSessionDomain.unified,
        ),
        epochBefore,
      );
    },
  );

  test('runAutomatic never writes metadata itself without a receipt', () async {
    await enable();
    final epochBefore = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );
    final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
      domain: AuthRecoveryDomain.cas,
      account: 'A',
      exchange: (_, _) async => null,
      receiptOf: (value) => value,
    );
    expect(outcome.decision, AuthRecoveryDecision.exchangeFailed);
    expect(outcome.didCommit, isFalse);
    expect(
      await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      ),
      epochBefore,
    );
  });

  test('terminal completion does not clear a superseding ticket', () async {
    await enable();
    final stale = await store.beginAttempt(
      AuthRecoveryDomain.cas,
      account: 'A',
    );
    // 模拟 lease 过期接管：更新的 ticket 取代旧 ticket。
    final fresh = await store.beginAttempt(
      AuthRecoveryDomain.cas,
      account: 'A',
    );
    expect(stale, isNotNull);
    expect(fresh, isNotNull);
    expect(fresh!.id, isNot(stale!.id));

    await store.completeAttempt(
      AuthRecoveryDomain.cas,
      ticketId: stale.id,
      success: true,
      scope: AuthFailureScope.transient,
    );

    final record = await store.read(AuthRecoveryDomain.cas);
    expect(record.activeAttempt?.id, fresh.id);
    expect(record.optIn, isTrue);
  });

  test(
    'cancel-ignoring exchange aborts at abort window and blocks re-entry',
    () async {
      await enable();
      final gate = Completer<void>();
      var exchangeStarts = 0;
      Future<SessionCommitResult?> slowExchange(
        AuthRecoveryTicket ticket,
        CancelToken token,
      ) async {
        exchangeStarts++;
        await gate.future; // 故意忽略取消 token
        return null;
      }

      final first = await coordinator.runAutomatic<SessionCommitResult?>(
        domain: AuthRecoveryDomain.cas,
        account: 'A',
        exchange: slowExchange,
        receiptOf: (value) => value,
        exchangeDeadline: const Duration(milliseconds: 10),
        exchangeAbortAfter: const Duration(milliseconds: 50),
      );
      expect(first.decision, AuthRecoveryDecision.aborted);

      // abort 窗口已过，但交换仍在运行：同 isolate 不得并发第二次。
      final second = await coordinator.runAutomatic<SessionCommitResult?>(
        domain: AuthRecoveryDomain.cas,
        account: 'A',
        exchange: slowExchange,
        receiptOf: (value) => value,
        exchangeDeadline: const Duration(milliseconds: 10),
        exchangeAbortAfter: const Duration(milliseconds: 50),
      );
      expect(second.decision, AuthRecoveryDecision.busy);
      expect(exchangeStarts, 1, reason: '取消不合作的交换仍在运行，不得开始第二次交换');

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final third = await coordinator.runAutomatic<SessionCommitResult?>(
        domain: AuthRecoveryDomain.cas,
        account: 'A',
        exchange: (ticket, _) => commitViaExchange(ticket),
        receiptOf: (value) => value,
        now: DateTime.now().add(const Duration(minutes: 6)),
      );
      expect(third.decision, AuthRecoveryDecision.committed);
      expect(exchangeStarts, 1);
    },
  );

  test(
    'repeated transient failures only back off and never require manual login',
    () async {
      await enable();
      // OCR 认错 / 验证码被拒连续 3 次：只退避，不转 manualRequired。
      for (var i = 0; i < 3; i++) {
        await coordinator.recordTransientFailure(
          AuthRecoveryDomain.cas,
          kind: AuthFailureKind.captchaRejected,
        );
      }
      final record = await store.read(AuthRecoveryDomain.cas);
      expect(record.failureCount, 0, reason: 'OCR 认错 ≠ 身份错');
      expect(
        await coordinator.automaticEligibility(
          AuthRecoveryDomain.cas,
          account: 'A',
          now: DateTime.now().add(const Duration(minutes: 6)),
        ),
        AuthRecoveryDecision.proceed,
        reason: '退避结束后仍可自动登录',
      );
    },
  );

  test(
    'identity failures pause automatic recovery as manualRequired',
    () async {
      await enable();
      for (var i = 0; i < 3; i++) {
        await coordinator.recordIdentityFailure(
          AuthRecoveryDomain.cas,
          kind: AuthFailureKind.invalidCredentials,
        );
      }
      expect(
        await coordinator.automaticEligibility(
          AuthRecoveryDomain.cas,
          account: 'A',
          now: DateTime.now().add(const Duration(hours: 1)),
        ),
        AuthRecoveryDecision.manualRequired,
        reason: '明确凭据错误达阈值后必须提示手动登录，不得静默重试',
      );

      final outcome = await coordinator.runAutomatic<SessionCommitResult?>(
        domain: AuthRecoveryDomain.cas,
        account: 'A',
        exchange: (_, _) async => throw StateError('must not run'),
        receiptOf: (value) => value,
      );
      expect(outcome.decision, AuthRecoveryDecision.manualRequired);
    },
  );

  test('manual success re-arms automatic recovery', () async {
    await enable();
    for (var i = 0; i < 3; i++) {
      await coordinator.recordIdentityFailure(
        AuthRecoveryDomain.cas,
        kind: AuthFailureKind.invalidCredentials,
      );
    }
    expect(
      await coordinator.automaticEligibility(
        AuthRecoveryDomain.cas,
        account: 'A',
      ),
      AuthRecoveryDecision.manualRequired,
    );

    await coordinator.recordSuccess(AuthRecoveryDomain.cas);
    expect(
      await coordinator.automaticEligibility(
        AuthRecoveryDomain.cas,
        account: 'A',
      ),
      AuthRecoveryDecision.proceed,
    );
  });
}
