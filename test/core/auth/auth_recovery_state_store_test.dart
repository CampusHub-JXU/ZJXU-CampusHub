import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('auth_recovery_store_test_');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late AuthRecoveryStateStore store;

  setUp(() async {
    dir = await _tempDir();
    store = AuthRecoveryStateStore.debugNew(directoryProvider: () async => dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('opt-in defaults to false for both domains', () async {
    expect((await store.read(AuthRecoveryDomain.cas)).optIn, isFalse);
    expect((await store.read(AuthRecoveryDomain.academic)).optIn, isFalse);
  });

  test('enable is bound to account; wrong account is not eligible', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    expect(
      await store.isAutomaticEligible(AuthRecoveryDomain.cas, account: 'A'),
      isTrue,
    );
    expect(
      await store.isAutomaticEligible(AuthRecoveryDomain.cas, account: 'B'),
      isFalse,
    );
  });

  test(
    'explicit logout revokes and bumps epoch; business expiry does not',
    () async {
      await store.enable(
        AuthRecoveryDomain.academic,
        account: 'A',
        credentialRevision: 2,
      );
      final before = await store.read(AuthRecoveryDomain.academic);

      await store.recordLogout(
        AuthRecoveryDomain.academic,
        kind: AuthLogoutKind.businessExpiry,
      );
      final afterBusiness = await store.read(AuthRecoveryDomain.academic);
      expect(afterBusiness.optIn, isTrue);
      expect(afterBusiness.revoked, isFalse);
      expect(afterBusiness.epoch, before.epoch);
      expect(afterBusiness.lastFailure, isNotNull);
      expect(afterBusiness.failureCount, 0, reason: '会话过期不是身份失败，不得计入暂停阈值');

      await store.recordLogout(
        AuthRecoveryDomain.academic,
        kind: AuthLogoutKind.explicitUserLogout,
      );
      final afterExplicit = await store.read(AuthRecoveryDomain.academic);
      expect(afterExplicit.optIn, isFalse);
      expect(afterExplicit.revoked, isTrue);
      expect(afterExplicit.epoch, before.epoch + 1);
      expect(afterExplicit.account, isNull);
      expect(
        await store.isAutomaticEligible(
          AuthRecoveryDomain.academic,
          account: 'A',
        ),
        isFalse,
      );
    },
  );

  test('cooldown blocks automatic eligibility', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    final now = DateTime(2026, 1, 1, 12, 0);
    await store.recordTransientFailure(
      AuthRecoveryDomain.cas,
      kind: AuthFailureKind.networkUnavailable,
      now: now,
      cooldown: const Duration(minutes: 30),
    );
    expect(
      await store.isAutomaticEligible(
        AuthRecoveryDomain.cas,
        account: 'A',
        now: now.add(const Duration(minutes: 5)),
      ),
      isFalse,
    );
    expect(
      await store.isAutomaticEligible(
        AuthRecoveryDomain.cas,
        account: 'A',
        now: now.add(const Duration(minutes: 31)),
      ),
      isTrue,
    );
  });

  test(
    'credentials change advances revision and revokes old permission',
    () async {
      await store.enable(
        AuthRecoveryDomain.cas,
        account: 'A',
        credentialRevision: 0,
      );
      final before = await store.read(AuthRecoveryDomain.cas);
      final after = await store.onCredentialsChanged(AuthRecoveryDomain.cas);
      expect(after.credentialRevision, before.credentialRevision + 1);
      expect(after.epoch, before.epoch + 1);
      expect(after.optIn, isFalse);
      expect(after.account, isNull);
    },
  );

  test(
    'manual hold is persisted, extended and cleared without token',
    () async {
      final now = DateTime(2026, 1, 1, 12, 0);
      await store.beginManualHold(
        AuthRecoveryDomain.academic,
        ttl: const Duration(minutes: 2),
        now: now,
      );
      expect(
        await store.isManualHoldActive(
          AuthRecoveryDomain.academic,
          now: now.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );

      // 更早的截止时间不会缩短已有窗口。
      await store.beginManualHold(
        AuthRecoveryDomain.academic,
        ttl: const Duration(seconds: 10),
        now: now.add(const Duration(seconds: 30)),
      );
      final record = await store.read(AuthRecoveryDomain.academic);
      expect(record.manualHoldUntil, now.add(const Duration(minutes: 2)));

      await store.endManualHold(AuthRecoveryDomain.academic);
      expect(
        await store.isManualHoldActive(AuthRecoveryDomain.academic, now: now),
        isFalse,
      );
    },
  );

  test('active manual hold blocks automatic eligibility', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    await store.beginManualHold(AuthRecoveryDomain.cas);
    expect(
      await store.isAutomaticEligible(AuthRecoveryDomain.cas, account: 'A'),
      isFalse,
    );
    await store.endManualHold(AuthRecoveryDomain.cas);
    expect(
      await store.isAutomaticEligible(AuthRecoveryDomain.cas, account: 'A'),
      isTrue,
    );
  });

  test(
    'ticket verifies then is rejected after revocation/lease/expiry',
    () async {
      final now = DateTime(2026, 1, 1, 12, 0);
      await store.enable(
        AuthRecoveryDomain.cas,
        account: 'A',
        credentialRevision: 0,
      );
      final ticket = await store.beginAttempt(
        AuthRecoveryDomain.cas,
        account: 'A',
        ttl: const Duration(minutes: 2),
        now: now,
      );
      expect(ticket, isNotNull);
      expect(await store.verifyTicket(ticket!, now: now), isTrue);

      await store.beginManualHold(AuthRecoveryDomain.cas, now: now);
      expect(await store.verifyTicket(ticket, now: now), isFalse);
      await store.endManualHold(AuthRecoveryDomain.cas);

      await store.recordLogout(
        AuthRecoveryDomain.cas,
        kind: AuthLogoutKind.explicitUserLogout,
      );
      expect(await store.verifyTicket(ticket, now: now), isFalse);
    },
  );

  test('expired ticket is rejected', () async {
    final now = DateTime(2026, 1, 1, 12, 0);
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    final ticket = await store.beginAttempt(
      AuthRecoveryDomain.cas,
      account: 'A',
      ttl: const Duration(seconds: 30),
      now: now,
    );
    expect(
      await store.verifyTicket(
        ticket!,
        now: now.add(const Duration(seconds: 31)),
      ),
      isFalse,
    );
  });

  test(
    'corrupt or unsupported state fails closed instead of throwing',
    () async {
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        '${AuthRecoveryStateStore.stateFileName}',
      );
      await file.writeAsString('{not-json');
      final record = await store.read(AuthRecoveryDomain.cas);
      expect(record.optIn, isFalse);
      expect(record.account, isNull);

      await file.writeAsString(jsonEncode({'v': 99, 'domains': {}}));
      expect((await store.read(AuthRecoveryDomain.cas)).optIn, isFalse);
    },
  );

  test('persisted JSON never contains password material', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      '${AuthRecoveryStateStore.stateFileName}',
    );
    final raw = await file.readAsString();
    expect(raw.contains('password'), isFalse);
    expect(raw.contains('secret'), isFalse);
  });

  test(
    'two store instances serialize and increment without lost updates',
    () async {
      final other = AuthRecoveryStateStore.debugNew(
        directoryProvider: () async => dir,
      );
      await Future.wait([
        for (var i = 0; i < 10; i++)
          (i.isEven ? store : other).onCredentialsChanged(
            AuthRecoveryDomain.cas,
          ),
      ]);
      final record = await store.read(AuthRecoveryDomain.cas);
      expect(record.credentialRevision, 10);
    },
  );

  test('lock file is released after a read', () async {
    await store.read(AuthRecoveryDomain.cas);
    final lock = File(
      '${dir.path}${Platform.pathSeparator}'
      '${AuthRecoveryStateStore.lockFileName}',
    );
    expect(await lock.exists(), isFalse);
  });

  test(
    'transient failures only cool down and never count as identity',
    () async {
      await store.enable(
        AuthRecoveryDomain.cas,
        account: 'A',
        credentialRevision: 0,
      );
      final t0 = DateTime(2026, 1, 1, 12, 0);
      // OCR 认错 / 验证码被拒：连续三次都只退避，不转「需手动」。
      for (var i = 0; i < 3; i++) {
        await store.recordTransientFailure(
          AuthRecoveryDomain.cas,
          kind: AuthFailureKind.captchaRejected,
          now: t0.add(Duration(minutes: i)),
          cooldown: AuthRecoveryStateStore.transientBackoffFor(i + 1),
        );
      }
      final record = await store.read(AuthRecoveryDomain.cas);
      expect(record.failureCount, 0, reason: 'OCR 认错 ≠ 身份错');
      expect(
        await store.isAutomaticEligible(
          AuthRecoveryDomain.cas,
          account: 'A',
          now: t0.add(const Duration(minutes: 10)),
        ),
        isTrue,
        reason: '退避结束后仍可自动登录，不需要手动',
      );
    },
  );

  test('transient backoff ladder is 1/2/5 minutes', () {
    expect(
      AuthRecoveryStateStore.transientBackoffFor(1),
      const Duration(minutes: 1),
    );
    expect(
      AuthRecoveryStateStore.transientBackoffFor(2),
      const Duration(minutes: 2),
    );
    expect(
      AuthRecoveryStateStore.transientBackoffFor(3),
      const Duration(minutes: 5),
    );
    expect(
      AuthRecoveryStateStore.transientBackoffFor(9),
      const Duration(minutes: 5),
    );
  });

  test('identity failures accumulate and pause automatic recovery', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    final t0 = DateTime(2026, 1, 1, 12, 0);
    for (var i = 0; i < 2; i++) {
      await store.recordIdentityFailure(
        AuthRecoveryDomain.cas,
        kind: AuthFailureKind.invalidCredentials,
        now: t0.add(Duration(minutes: i)),
      );
    }
    expect(
      await store.isAutomaticEligible(
        AuthRecoveryDomain.cas,
        account: 'A',
        now: t0.add(const Duration(hours: 1)),
      ),
      isTrue,
      reason: '未达阈值仍可自动重试',
    );
    await store.recordIdentityFailure(
      AuthRecoveryDomain.cas,
      kind: AuthFailureKind.invalidCredentials,
      now: t0.add(const Duration(minutes: 3)),
    );
    final record = await store.read(AuthRecoveryDomain.cas);
    expect(record.failureCount, 3);
    expect(
      await store.isAutomaticEligible(
        AuthRecoveryDomain.cas,
        account: 'A',
        now: t0.add(const Duration(hours: 1)),
      ),
      isFalse,
      reason: '达阈值后暂停，即使冷却早已结束',
    );
    expect(
      await store.beginAttempt(AuthRecoveryDomain.cas, account: 'A'),
      isNull,
      reason: '暂停状态不得签发 ticket',
    );
  });

  test('successful manual login re-arms automatic recovery', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    for (var i = 0; i < 3; i++) {
      await store.recordIdentityFailure(
        AuthRecoveryDomain.cas,
        kind: AuthFailureKind.invalidCredentials,
        now: DateTime(2026, 1, 1, 12, i),
      );
    }
    expect(
      await store.isAutomaticEligible(AuthRecoveryDomain.cas, account: 'A'),
      isFalse,
    );
    await store.recordSuccess(AuthRecoveryDomain.cas);
    expect(
      await store.isAutomaticEligible(AuthRecoveryDomain.cas, account: 'A'),
      isTrue,
    );
  });

  test('completeAttempt counts identity failures only', () async {
    await store.enable(
      AuthRecoveryDomain.cas,
      account: 'A',
      credentialRevision: 0,
    );
    final t0 = DateTime(2026, 1, 1, 12, 0);
    final transient = await store.beginAttempt(
      AuthRecoveryDomain.cas,
      account: 'A',
      now: t0,
    );
    await store.completeAttempt(
      AuthRecoveryDomain.cas,
      ticketId: transient!.id,
      success: false,
      scope: AuthFailureScope.transient,
      failureKind: AuthFailureKind.timeout,
      now: t0,
    );
    expect((await store.read(AuthRecoveryDomain.cas)).failureCount, 0);

    final t2 = t0.add(const Duration(minutes: 1));
    final identity = await store.beginAttempt(
      AuthRecoveryDomain.cas,
      account: 'A',
      now: t2,
    );
    await store.completeAttempt(
      AuthRecoveryDomain.cas,
      ticketId: identity!.id,
      success: false,
      scope: AuthFailureScope.identity,
      failureKind: AuthFailureKind.invalidCredentials,
      now: t2,
    );
    expect((await store.read(AuthRecoveryDomain.cas)).failureCount, 1);
  });

  test(
    'legacy JSON with manualLease/exchangeLease migrates without crashing',
    () async {
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        '${AuthRecoveryStateStore.stateFileName}',
      );
      final holdUntil = DateTime(2026, 1, 1, 12, 30);
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'v': 1,
          'domains': <String, dynamic>{
            'cas': <String, dynamic>{
              'optIn': true,
              'account': 'A',
              'credentialRevision': 0,
              'epoch': 0,
              'revoked': false,
              'cooldownUntil': null,
              'lastFailure': 'captchaRejected',
              'lastFailureAt': null,
              'failureCount': 3,
              'manualLease': <String, dynamic>{
                'token': 'lease-old',
                'acquiredAt': DateTime(2026, 1, 1, 12, 0).toIso8601String(),
                'expiresAt': holdUntil.toIso8601String(),
              },
              'activeAttempt': null,
              'exchangeLease': <String, dynamic>{
                'token': 'exchange-old',
                'acquiredAt': DateTime(2026, 1, 1, 12, 0).toIso8601String(),
                'expiresAt': DateTime(2026, 1, 1, 12, 2).toIso8601String(),
              },
            },
          },
        }),
      );

      final record = await store.read(AuthRecoveryDomain.cas);
      expect(record.optIn, isTrue);
      expect(record.account, 'A');
      expect(record.failureCount, 0, reason: '旧 failureCount 语义不同，不得误判为身份失败');
      expect(
        record.manualHoldUntil,
        holdUntil,
        reason: '旧 manualLease.expiresAt 迁移为 manualHoldUntil',
      );
      expect(record.manualHoldActiveAt(DateTime(2026, 1, 1, 12, 10)), isTrue);
      expect(record.manualHoldActiveAt(DateTime(2026, 1, 1, 13, 0)), isFalse);

      // 迁移读一次、不写回：一次写入后旧键消失。
      await store.endManualHold(AuthRecoveryDomain.cas);
      final raw = await file.readAsString();
      expect(raw.contains('manualLease'), isFalse);
      expect(raw.contains('exchangeLease'), isFalse);
      expect(raw.contains('manualHoldUntil'), isTrue);
    },
  );
}
