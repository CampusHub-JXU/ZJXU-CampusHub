import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/background_auth_context.dart';
import 'package:jxu_campus_hub/core/auth/background_auth_run.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';

void main() {
  late Directory dir;
  late BackgroundSessionGate gate;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bg_auth_run_test');
    gate = BackgroundSessionGate.debugNew(directoryProvider: () async => dir);
  });

  tearDown(() async {
    gate.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<BackgroundAuthRunResult<T>> run<T>(
    Future<T> Function(BackgroundAuthRun run) body, {
    Duration budget = const Duration(seconds: 5),
    Duration grace = const Duration(seconds: 1),
    Set<AuthRecoveryDomain> pin = const {},
    BackgroundSessionPinReader? pinReader,
  }) => BackgroundAuthRun.execute<T>(
    gate: gate,
    body: body,
    budget: budget,
    hardStopGrace: grace,
    yieldPollInterval: const Duration(milliseconds: 20),
    pinDomains: pin,
    pinReader: pinReader,
  );

  Future<void> expectClaimReleased() async {
    final claim = await gate.tryClaim();
    expect(claim, isNotNull, reason: '申领应已释放');
    await gate.release(claim!);
  }

  test('foreground heartbeat fresh: no claim, body never runs', () async {
    await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
    var ran = false;
    final result = await run<bool>((_) async => ran = true);
    gate.stopHeartbeat();
    expect(result.claimed, isFalse);
    expect(result.value, isNull);
    expect(ran, isFalse);
  });

  test('claim held by another task: denied', () async {
    final held = await gate.tryClaim();
    expect(held, isNotNull);
    var ran = false;
    final result = await run<void>((_) async => ran = true);
    expect(result.claimed, isFalse);
    expect(ran, isFalse);
    // 对方的申领不被本次失败动到。
    expect(await gate.shouldYield(held!), isFalse);
  });

  test('normal completion returns the value and releases the claim', () async {
    final result = await run<int>((_) async => 42);
    expect(result.claimed, isTrue);
    expect(result.value, 42);
    expect(result.timedOut, isFalse);
    expect(result.yielded, isFalse);
    await expectClaimReleased();
  });

  test('foreground heartbeat appearing cancels the token (yield)', () async {
    final started = Completer<void>();
    final future = run<bool>((session) async {
      started.complete();
      await session.cancelToken.whenCancel;
      return session.yielded;
    });
    await started.future;
    await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
    final result = await future;
    gate.stopHeartbeat();
    expect(result.yielded, isTrue);
    expect(result.value, isTrue);
    expect(result.budgetExpired, isFalse);
    // 让位后申领仍被释放：前台离开后可再次申领。
    await gate.leaveForeground();
    await expectClaimReleased();
  });

  test('budget expiry cancels the token and releases the claim', () async {
    final result = await run<bool>((session) async {
      await session.cancelToken.whenCancel;
      return session.budgetExpired;
    }, budget: const Duration(milliseconds: 60));
    expect(result.budgetExpired, isTrue);
    expect(result.value, isTrue);
    expect(result.timedOut, isFalse);
    await expectClaimReleased();
  });

  test('a body hung past budget + grace is abandoned and released', () async {
    final never = Completer<int>();
    CancelTokenProbe? probe;
    final stopwatch = Stopwatch()..start();
    final result = await run<int>(
      (session) {
        probe = CancelTokenProbe(session);
        return never.future;
      },
      budget: const Duration(milliseconds: 50),
      grace: const Duration(milliseconds: 50),
    );
    stopwatch.stop();
    expect(result.claimed, isTrue);
    expect(result.timedOut, isTrue);
    expect(result.value, isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(probe!.cancelled, isTrue);
    expect(probe!.allowed, completion(isFalse));
    await expectClaimReleased();
    // 迟到的失败不会冒成未捕获异常。
    never.completeError(StateError('late'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('body error is rethrown after the claim is released', () async {
    await expectLater(
      run<void>((_) async => throw StateError('boom')),
      throwsStateError,
    );
    await expectClaimReleased();
  });

  test(
    'installs BackgroundAuthContext and pins claim-time epoch/account',
    () async {
      BackgroundAuthContext? seen;
      final order = <String>[];
      final result = await run<void>(
        (session) async {
          order.add('body');
          seen = BackgroundAuthContext.current;
          expect(identical(seen, session.context), isTrue);
          expect(seen!.pinnedEpoch(CredentialSessionDomain.unified), 5);
          expect(seen!.pinnedEpoch(CredentialSessionDomain.academic), 3);
          expect(seen!.expectedAccounts['cas'], 'cas-user');
          expect(seen!.expectedAccounts['academic'], isNull);
        },
        pin: const {AuthRecoveryDomain.cas, AuthRecoveryDomain.academic},
        pinReader: (domain) async {
          order.add('pin:${domain.wireName}');
          return domain == AuthRecoveryDomain.cas
              ? (epoch: 5, account: 'cas-user')
              : (epoch: 3, account: null);
        },
      );
      expect(result.claimed, isTrue);
      expect(seen, isNotNull);
      // 钉住发生在 body 之前。
      expect(order.last, 'body');
      expect(BackgroundAuthContext.current, isNull);
    },
  );

  test('recordChange writes kind/account/epoch on release', () async {
    await run<void>((session) async {
      session.recordChange(
        BackgroundSessionChangeKind.revoked,
        account: '2020001',
        readEpoch: () async => 8,
      );
    });
    final change = await gate.enterForeground(waitForClaim: Duration.zero);
    gate.stopHeartbeat();
    expect(change?.kind, BackgroundSessionChangeKind.revoked);
    expect(change?.account, '2020001');
    expect(change?.epoch, 8);
  });

  test(
    'a throwing epoch reader still releases (change without epoch)',
    () async {
      await run<void>((session) async {
        session.recordChange(
          BackgroundSessionChangeKind.revoked,
          account: '2020001',
          readEpoch: () async => throw StateError('io'),
        );
      });
      final change = await gate.enterForeground(waitForClaim: Duration.zero);
      gate.stopHeartbeat();
      expect(change?.kind, BackgroundSessionChangeKind.revoked);
      expect(change?.epoch, isNull);
      await gate.leaveForeground();
      await expectClaimReleased();
    },
  );
}

/// 在 body 里抓取令牌 / allowed 的探针，供放弃等待后检查。
class CancelTokenProbe {
  CancelTokenProbe(BackgroundAuthRun session) : _session = session;
  final BackgroundAuthRun _session;
  bool get cancelled => _session.cancelToken.isCancelled;
  Future<bool> get allowed => _session.context.allowed();
}
