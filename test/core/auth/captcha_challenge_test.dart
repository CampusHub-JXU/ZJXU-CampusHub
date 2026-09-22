import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/captcha_challenge.dart';

Uint8List _bytes(int seed) =>
    Uint8List.fromList(List<int>.generate(8, (i) => (seed + i) & 0xFF));

void main() {
  group('CaptchaChallengeStore single-submit semantics', () {
    test('only the current challenge can be consumed once', () {
      final store = CaptchaChallengeStore<String>();
      final challenge = store.arm(
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 3,
        bytes: _bytes(1),
        context: 'ctx-1',
      );

      final attempt = store.consume(challenge.id, accountRevision: 3);
      expect(attempt, isNotNull);
      expect(attempt!.context, 'ctx-1');
      expect(store.hasChallenge, isFalse);

      final second = store.consume(challenge.id, accountRevision: 3);
      expect(second, isNull);
    });

    test(
      're-arming replaces the previous challenge and advances generation',
      () {
        final store = CaptchaChallengeStore<String>();
        final first = store.arm(
          domain: CaptchaChallengeDomain.zhengfang,
          accountRevision: 1,
          bytes: _bytes(1),
          context: 'old',
        );
        final firstAttempt = store.consume(first.id, accountRevision: 1)!;

        final second = store.arm(
          domain: CaptchaChallengeDomain.zhengfang,
          accountRevision: 1,
          bytes: _bytes(2),
          context: 'new',
        );
        expect(store.consume(first.id, accountRevision: 1), isNull);
        expect(store.isAttemptCurrent(firstAttempt.generation), isFalse);
        expect(store.consume(second.id, accountRevision: 1)!.context, 'new');
      },
    );

    test('stale owner invalidation preserves the newer challenge', () {
      final store = CaptchaChallengeStore<String>();
      CaptchaChallenge arm(String context) => store.arm(
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
        bytes: _bytes(1),
        context: context,
      );
      final old = arm('old');
      final current = arm('current');
      store.invalidate(challengeId: old.id);
      expect(store.consume(current.id, accountRevision: 1)?.context, 'current');

      final owned = arm('owned');
      store.invalidate(challengeId: owned.id);
      expect(store.consume(owned.id, accountRevision: 1), isNull);
    });

    test('expired challenge cannot be consumed', () {
      final store = CaptchaChallengeStore<String>(
        defaultTtl: const Duration(seconds: 30),
      );
      final createdAt = DateTime(2026, 1, 1, 12, 0);
      final challenge = store.arm(
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
        bytes: _bytes(1),
        context: 'ctx',
        now: createdAt,
      );
      expect(
        store.consume(
          challenge.id,
          accountRevision: 1,
          now: createdAt.add(const Duration(seconds: 31)),
        ),
        isNull,
      );
      expect(store.hasChallenge, isFalse);
    });

    test('account revision mismatch invalidates the challenge', () {
      final store = CaptchaChallengeStore<String>();
      final challenge = store.arm(
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 5,
        bytes: _bytes(1),
        context: 'ctx',
      );
      expect(store.consume(challenge.id, accountRevision: 6), isNull);
      expect(store.hasChallenge, isFalse);
    });

    test('invalidate loses the in-flight attempt generation', () {
      final store = CaptchaChallengeStore<String>();
      final challenge = store.arm(
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
        bytes: _bytes(1),
        context: 'ctx',
      );
      final attempt = store.consume(challenge.id, accountRevision: 1)!;
      expect(store.isAttemptCurrent(attempt.generation), isTrue);

      store.invalidate();
      expect(store.isAttemptCurrent(attempt.generation), isFalse);
    });

    test('challenge redacts secrets from toString', () {
      final store = CaptchaChallengeStore<String>();
      final challenge = store.arm(
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
        bytes: _bytes(7),
        context: 'lt-secret-value',
      );
      expect(challenge.toString(), contains('cas'));
      expect(challenge.toString(), isNot(contains('lt-secret-value')));
      expect(challenge.toString(), isNot(contains('secret')));
    });
  });
}
