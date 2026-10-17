import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/background_auth_context.dart';
import 'package:jxu_campus_hub/core/auth/background_cas_recovery.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';

const _committed = AutomaticLoginAttemptResult(
  outcome: AutomaticLoginOutcome.committed,
  receipt: SessionCommitResult(account: '2020001', epoch: 2),
);

void main() {
  late Directory dir;
  late BackgroundSessionGate gate;
  late int attempts;
  late int validations;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bg_recovery_test');
    gate = BackgroundSessionGate.debugNew(directoryProvider: () async => dir);
    attempts = 0;
    validations = 0;
  });

  tearDown(() async {
    gate.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  BackgroundCasRecovery build({
    AuthRecoveryDecision decision = AuthRecoveryDecision.proceed,
    String? account = '2020001',
    bool loggedIn = false,
    bool? validated = false,
    Duration overallBudget = const Duration(seconds: 75),
    Duration hardStopGrace = const Duration(seconds: 8),
    int? epoch = 7,
    Future<AutomaticLoginAttemptResult> Function(String, CancelToken)? attempt,
  }) => BackgroundCasRecovery.debugNew(
    gate: gate,
    readEpoch: () async => epoch,
    pinReader: (_) async => (epoch: epoch ?? 0, account: account),
    hardStopGrace: hardStopGrace,
    eligibility: (_) async => decision,
    credentialAccount: () async => account,
    restoreSession: () async {},
    isLoggedIn: () => loggedIn,
    currentAccount: () => loggedIn ? account : null,
    validateSession: () async {
      validations++;
      return validated;
    },
    overallBudget: overallBudget,
    attempt:
        attempt ??
        (a, t) async {
          attempts++;
          return _committed;
        },
  );

  test('foreground active: does nothing', () async {
    await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
    final result = await build().recover();
    expect(result, BackgroundRecoveryResult.foregroundActive);
    expect(attempts, 0);
  });

  test('no account (never logged in): no identity, no login', () async {
    final result = await build(account: null).recover();
    expect(result, BackgroundRecoveryResult.noIdentity);
    expect(attempts, 0);
  });

  test('explicit user logout (revoked): no identity, no login', () async {
    final result = await build(decision: AuthRecoveryDecision.revoked)
        .recover();
    expect(result, BackgroundRecoveryResult.noIdentity);
    expect(attempts, 0);
  });

  test('opt-in off and no active identity: no identity', () async {
    final result = await build(
      decision: AuthRecoveryDecision.disabled,
      loggedIn: false,
    ).recover();
    expect(result, BackgroundRecoveryResult.noIdentity);
  });

  test('paused auto recovery without active identity still counts', () async {
    final result = await build(
      decision: AuthRecoveryDecision.manualRequired,
      loggedIn: false,
    ).recover();
    expect(result, BackgroundRecoveryResult.notEligible);
  });

  test('ineligible decision: not eligible, identity untouched', () async {
    final result = await build(
      decision: AuthRecoveryDecision.disabled,
      loggedIn: true,
    ).recover();
    expect(result, BackgroundRecoveryResult.notEligible);
    expect(validations, 0);
    expect(attempts, 0);
  });

  test('logged in and server session still valid: undetermined', () async {
    final result = await build(loggedIn: true, validated: true).recover();
    expect(result, BackgroundRecoveryResult.undetermined);
    expect(attempts, 0);
  });

  test('logged in and probe unknown: undetermined', () async {
    final result = await build(loggedIn: true, validated: null).recover();
    expect(result, BackgroundRecoveryResult.undetermined);
    expect(attempts, 0);
  });

  test('expired identity + committed login: recovered and recorded', () async {
    final result = await build(loggedIn: true, validated: false).recover();
    expect(result, BackgroundRecoveryResult.recovered);
    expect(attempts, 1);
    final change = await gate.enterForeground(waitForClaim: Duration.zero);
    gate.stopHeartbeat();
    expect(change?.kind, BackgroundSessionChangeKind.committed);
  });

  test('committed without receipt is not trusted', () async {
    final result = await build(
      attempt: (a, t) async => const AutomaticLoginAttemptResult(
        outcome: AutomaticLoginOutcome.committed,
      ),
    ).recover();
    expect(result, BackgroundRecoveryResult.failed);
  });

  test('failed login after revoke leaves a revoked change', () async {
    final result = await build(
      loggedIn: true,
      validated: false,
      attempt: (a, t) async => const AutomaticLoginAttemptResult(
        outcome: AutomaticLoginOutcome.failed,
      ),
    ).recover();
    expect(result, BackgroundRecoveryResult.failed);
    final change = await gate.enterForeground(waitForClaim: Duration.zero);
    gate.stopHeartbeat();
    expect(change?.kind, BackgroundSessionChangeKind.revoked);
    // 记录带上被撤销的账号与撤销后的持久 epoch，前台据此判断是否已被新登录取代。
    expect(change?.account, '2020001');
    expect(change?.epoch, 7);
  });

  test('revoked change without a readable epoch never applies', () async {
    await build(
      loggedIn: true,
      validated: false,
      epoch: null,
      attempt: (a, t) async => const AutomaticLoginAttemptResult(
        outcome: AutomaticLoginOutcome.failed,
      ),
    ).recover();
    final change = await gate.enterForeground(waitForClaim: Duration.zero);
    gate.stopHeartbeat();
    expect(change?.kind, BackgroundSessionChangeKind.revoked);
    expect(
      change!.revokedStillApplies(currentAccount: '2020001', currentEpoch: 7),
      isFalse,
    );
  });

  test('foreground returning mid-login cancels the attempt', () async {
    late CancelToken seen;
    final started = Completer<void>();
    final future = build(
      attempt: (a, t) async {
        seen = t;
        started.complete();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return AutomaticLoginAttemptResult(
          outcome: t.isCancelled
              ? AutomaticLoginOutcome.failed
              : AutomaticLoginOutcome.committed,
        );
      },
    ).recover();
    await started.future;
    await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
    final result = await future;
    gate.stopHeartbeat();
    expect(seen.isCancelled, isTrue);
    expect(result, BackgroundRecoveryResult.failed);
  });

  test('overall budget cancels a stuck attempt', () async {
    late CancelToken seen;
    await build(
      overallBudget: const Duration(milliseconds: 100),
      attempt: (a, t) async {
        seen = t;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return const AutomaticLoginAttemptResult(
          outcome: AutomaticLoginOutcome.failed,
        );
      },
    ).recover();
    expect(seen.isCancelled, isTrue);
  });

  test(
    'notice path runs inside a BackgroundAuthContext pinned at claim time',
    () async {
      BackgroundAuthContext? seen;
      int? pinnedEpoch;
      String? pinnedAccount;
      final result = await build(
        loggedIn: true,
        validated: false,
        epoch: 5,
        attempt: (a, t) async {
          seen = BackgroundAuthContext.current;
          pinnedEpoch = seen?.pinnedEpoch(CredentialSessionDomain.unified);
          pinnedAccount = seen?.expectedAccounts['cas'];
          expect(identical(seen?.cancelToken, t), isTrue);
          return _committed;
        },
      ).recover();
      expect(result, BackgroundRecoveryResult.recovered);
      expect(seen, isNotNull);
      expect(pinnedEpoch, 5);
      expect(pinnedAccount, '2020001');
    },
  );

  test(
    'a session re-logged-in after the claim is not recorded as revoked',
    () async {
      // 本轮钉住 epoch 7；前台随后重新登录把磁盘 epoch 推进到 9：
      // revoked 记录不得带上 9（否则前台会把新会话当成「被撤销的那个」）。
      var diskEpoch = 7;
      final recovery = BackgroundCasRecovery.debugNew(
        gate: gate,
        readEpoch: () async => diskEpoch,
        pinReader: (_) async => (epoch: 7, account: '2020001'),
        eligibility: (_) async => AuthRecoveryDecision.proceed,
        credentialAccount: () async => '2020001',
        restoreSession: () async {},
        isLoggedIn: () => true,
        currentAccount: () => '2020001',
        validateSession: () async => false,
        attempt: (a, t) async {
          diskEpoch = 9;
          return const AutomaticLoginAttemptResult(
            outcome: AutomaticLoginOutcome.failed,
          );
        },
      );
      await recovery.recover();
      final change = await gate.enterForeground(waitForClaim: Duration.zero);
      gate.stopHeartbeat();
      expect(change?.kind, BackgroundSessionChangeKind.revoked);
      expect(change?.epoch, isNull);
      expect(
        change!.revokedStillApplies(currentAccount: '2020001', currentEpoch: 9),
        isFalse,
      );
    },
  );

  test(
    'an attempt that ignores cancellation is abandoned and released',
    () async {
      final never = Completer<AutomaticLoginAttemptResult>();
      final stopwatch = Stopwatch()..start();
      final result = await build(
        loggedIn: true,
        validated: false,
        overallBudget: const Duration(milliseconds: 50),
        hardStopGrace: const Duration(milliseconds: 50),
        attempt: (a, t) => never.future,
      ).recover();
      stopwatch.stop();
      expect(result, BackgroundRecoveryResult.failed);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      // 申领已释放，且留下 revoked 记录。
      final claim = await gate.tryClaim();
      expect(claim, isNotNull);
      await gate.release(claim!);
      final change = await gate.enterForeground(waitForClaim: Duration.zero);
      gate.stopHeartbeat();
      expect(change?.kind, BackgroundSessionChangeKind.revoked);
    },
  );
}
