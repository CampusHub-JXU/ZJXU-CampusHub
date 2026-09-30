import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/background_cas_recovery.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';

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
    Future<AutomaticLoginAttemptResult> Function(String, CancelToken)? attempt,
  }) => BackgroundCasRecovery.debugNew(
    gate: gate,
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

  test('no account: not eligible, no login', () async {
    final result = await build(account: null).recover();
    expect(result, BackgroundRecoveryResult.notEligible);
    expect(attempts, 0);
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
}
