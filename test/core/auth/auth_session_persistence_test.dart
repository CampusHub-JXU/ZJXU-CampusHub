import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/isolated_auth_session.dart';

class _MemoryBackend implements AuthSessionEnvelopeBackend {
  final Map<CredentialSessionDomain, CredentialSessionEnvelope> data = {};
  Future<void> Function(
    CredentialSessionDomain domain,
    CredentialSessionEnvelope envelope,
  )?
  beforeWrite;
  Future<void> Function(CredentialSessionDomain domain)? beforeRead;

  int writeCount = 0;

  @override
  Future<CredentialSessionEnvelope> read(CredentialSessionDomain domain) async {
    await beforeRead?.call(domain);
    return data[domain] ?? const CredentialSessionEnvelope();
  }

  @override
  Future<void> write(
    CredentialSessionDomain domain,
    CredentialSessionEnvelope envelope,
  ) async {
    await beforeWrite?.call(domain, envelope);
    writeCount++;
    data[domain] = envelope;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _MemoryBackend backend;
  late AuthSessionPersistence persistence;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auth_session_persist_test_');
    backend = _MemoryBackend();
    persistence = AuthSessionPersistence.debugNew(
      backend: backend,
      directoryProvider: () async => dir,
    )..debugForceFileLock = true;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('commit with matching epoch writes the active session', () async {
    final committed = await persistence.commit(
      CredentialSessionDomain.unified,
      account: 'A',
      expectedEpoch: 0,
    );
    expect(committed, isNotNull);
    final envelope = backend.data[CredentialSessionDomain.unified]!;
    expect(envelope.active, isTrue);
    expect(envelope.account, 'A');
    expect(envelope.epoch, 1);
  });

  test('commit with stale epoch is rejected without writing', () async {
    await persistence.revoke(CredentialSessionDomain.unified);
    final writesBefore = backend.writeCount;
    final committed = await persistence.commit(
      CredentialSessionDomain.unified,
      account: 'A',
      expectedEpoch: 0,
    );
    expect(committed, isNull);
    expect(backend.writeCount, writesBefore);
    expect(
      (await persistence.read(CredentialSessionDomain.unified)).active,
      isFalse,
    );
  });

  test(
    'logout (revoke) wins over a later commit carrying the old epoch',
    () async {
      final committedBefore = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      );
      expect(committedBefore, isNotNull);
      await persistence.revoke(CredentialSessionDomain.unified);
      // 旧登录用 epoch 0 提交（它启动时读到的值），必须被拒绝。
      final late = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      );
      expect(late, isNull);
      expect(
        (await persistence.read(CredentialSessionDomain.unified)).active,
        isFalse,
      );
    },
  );

  test('logout then relogin yields a new active epoch', () async {
    await persistence.commit(
      CredentialSessionDomain.unified,
      account: 'A',
      expectedEpoch: 0,
    );
    await persistence.revoke(CredentialSessionDomain.unified);
    final epochAfterLogout = await persistence.readEpoch(
      CredentialSessionDomain.unified,
    );
    final relogin = await persistence.commit(
      CredentialSessionDomain.unified,
      account: 'A',
      expectedEpoch: epochAfterLogout,
    );
    expect(relogin, isNotNull);
    final envelope = await persistence.read(CredentialSessionDomain.unified);
    expect(envelope.active, isTrue);
    expect(envelope.epoch, epochAfterLogout + 1);
  });

  test(
    'blocked persistent write + logout cannot resurrect the session',
    () async {
      final other = AuthSessionPersistence.debugNew(
        backend: backend,
        directoryProvider: () async => dir,
      );
      final gate = Completer<void>();
      backend.beforeWrite = (_, _) => gate.future;

      final commitFuture = persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      );
      // 让 commit 先取到锁并在写盘处阻塞。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final revokeFuture = other.revoke(CredentialSessionDomain.unified);

      gate.complete();
      await commitFuture;
      await revokeFuture;

      final envelope = await persistence.read(CredentialSessionDomain.unified);
      expect(envelope.active, isFalse);
    },
  );

  test('two instances on the same directory serialize commit/revoke', () async {
    final other = AuthSessionPersistence.debugNew(
      backend: backend,
      directoryProvider: () async => dir,
    )..debugForceFileLock = true;
    // 并发：commit(epoch0) 与 revoke 竞争；最终必须 inactive。
    final results = await Future.wait([
      persistence.commit(
        CredentialSessionDomain.academic,
        account: 'A',
        expectedEpoch: 0,
      ),
      other.revoke(CredentialSessionDomain.academic),
    ]);
    final envelope = await persistence.read(CredentialSessionDomain.academic);
    expect(envelope.active, isFalse);
    expect(envelope.epoch, greaterThanOrEqualTo(1));
    // commit 可能成功也可能因 revoke 先到而被拒；两种都不得留下 active。
    expect(results.length, 2);
  });

  test('domains are independent', () async {
    await persistence.commit(
      CredentialSessionDomain.unified,
      account: 'U',
      expectedEpoch: 0,
    );
    await persistence.revoke(CredentialSessionDomain.academic);
    expect(
      (await persistence.read(CredentialSessionDomain.unified)).active,
      isTrue,
    );
    expect(
      (await persistence.read(CredentialSessionDomain.academic)).active,
      isFalse,
    );
  });

  test(
    'withCurrentSession runs action for the matching active identity',
    () async {
      await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      ); // epoch 1, active A
      final writesBefore = backend.writeCount;

      final result = await persistence.withCurrentSession<String>(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 1,
        action: () async => 'cache-ok',
      );

      expect(result, 'cache-ok');
      // 不写 envelope、不推进身份 epoch。
      expect(backend.writeCount, writesBefore);
      final envelope = await persistence.read(CredentialSessionDomain.unified);
      expect(envelope.epoch, 1);
      expect(envelope.active, isTrue);
    },
  );

  test(
    'withCurrentSession returns null and skips action on mismatch',
    () async {
      await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      ); // epoch 1
      var calls = 0;
      Future<String> action() async {
        calls++;
        return 'x';
      }

      // owner 不符
      expect(
        await persistence.withCurrentSession<String>(
          CredentialSessionDomain.unified,
          account: 'B',
          expectedEpoch: 1,
          action: action,
        ),
        isNull,
      );
      // epoch 不符
      expect(
        await persistence.withCurrentSession<String>(
          CredentialSessionDomain.unified,
          account: 'A',
          expectedEpoch: 0,
          action: action,
        ),
        isNull,
      );
      // 已撤销（inactive）
      await persistence.revoke(CredentialSessionDomain.unified);
      expect(
        await persistence.withCurrentSession<String>(
          CredentialSessionDomain.unified,
          account: 'A',
          expectedEpoch: 2,
          action: action,
        ),
        isNull,
      );
      expect(calls, 0);
    },
  );

  group('revokeIfCurrent', () {
    test('revokes a session that is still exactly the committed one', () async {
      final result = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      );
      expect(result, isNotNull);

      final revoked = await persistence.revokeIfCurrent(
        CredentialSessionDomain.unified,
        account: result!.account,
        epoch: result.epoch,
      );
      expect(revoked, isTrue);
      final envelope = await persistence.read(CredentialSessionDomain.unified);
      expect(envelope.active, isFalse);
      expect(envelope.epoch, result.epoch + 1);
    });

    test('is a no-op after a newer commit of the same account', () async {
      final stale = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      ); // epoch 1
      // 同账号重新登录胜出。
      final newer = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 1,
      ); // epoch 2
      expect(newer, isNotNull);

      final revoked = await persistence.revokeIfCurrent(
        CredentialSessionDomain.unified,
        account: stale!.account,
        epoch: stale.epoch,
      );
      expect(revoked, isFalse);
      final envelope = await persistence.read(CredentialSessionDomain.unified);
      expect(envelope.active, isTrue);
      expect(envelope.account, 'A');
      expect(envelope.epoch, 2);
    });

    test('is a no-op after a different-account login wins', () async {
      final stale = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      );
      await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'B',
        expectedEpoch: 1,
      );

      final revoked = await persistence.revokeIfCurrent(
        CredentialSessionDomain.unified,
        account: stale!.account,
        epoch: stale.epoch,
      );
      expect(revoked, isFalse);
      final envelope = await persistence.read(CredentialSessionDomain.unified);
      expect(envelope.active, isTrue);
      expect(envelope.account, 'B');
    });

    test('is a no-op when the session was already logged out', () async {
      final stale = await persistence.commit(
        CredentialSessionDomain.unified,
        account: 'A',
        expectedEpoch: 0,
      );
      await persistence.revoke(CredentialSessionDomain.unified);

      final revoked = await persistence.revokeIfCurrent(
        CredentialSessionDomain.unified,
        account: stale!.account,
        epoch: stale.epoch,
      );
      expect(revoked, isFalse);
      expect(
        (await persistence.read(CredentialSessionDomain.unified)).active,
        isFalse,
      );
    });

    test(
      'blocked durable read: a concurrent B commit wins and revoke is a no-op',
      () async {
        final stale = await persistence.commit(
          CredentialSessionDomain.academic,
          account: 'A',
          expectedEpoch: 0,
        ); // A/epoch1
        expect(stale, isNotNull);

        final other = AuthSessionPersistence.debugNew(
          backend: backend,
          directoryProvider: () async => dir,
        );
        final gate = Completer<void>();
        var gated = false;
        backend.beforeRead = (domain) async {
          if (!gated) {
            gated = true;
            await gate.future;
          }
        };

        // 撤销先进入并阻塞在「读 durable envelope」。
        final revokeFuture = persistence.revokeIfCurrent(
          CredentialSessionDomain.academic,
          account: stale!.account,
          epoch: stale.epoch,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // 读盘阻塞期间，B 的提交胜出（更新 epoch）。
        final bCommitted = await other.commit(
          CredentialSessionDomain.academic,
          account: 'B',
          expectedEpoch: stale.epoch,
        );
        expect(bCommitted, isNotNull);

        gate.complete();
        expect(await revokeFuture, isFalse, reason: '读到 B 后必须拒绝撤销');

        final envelope = await persistence.read(
          CredentialSessionDomain.academic,
        );
        expect(envelope.active, isTrue, reason: 'B 的 disk envelope 必须保留');
        expect(envelope.account, 'B');
      },
    );
  });

  group(
    'commitWithIsolatedSession (typed merge, no callback escape hatch)',
    () {
      test(
        'merge runs under the same domain lock and cannot be interleaved',
        () async {
          final uri = Uri.parse('https://newca.zjxu.edu.cn/cas/login');
          final sourceJar = CookieJar();
          await sourceJar.saveFromResponse(uri, [
            Cookie('ISO', '1')..path = '/',
          ]);
          final session = await IsolatedAuthSession.create(
            sourceJar: sourceJar,
            seedUris: [uri],
            template: Dio(),
          );
          final target = _GatedJar();

          // 只有 commitWithIsolatedSession 这一种带合并的提交；没有可传任意
          // 异步工作的回调参数（API 形状约束）。
          final commitFuture = persistence.commitWithIsolatedSession(
            CredentialSessionDomain.unified,
            account: 'A',
            expectedEpoch: 0,
            session: session,
            target: target.jar,
          );
          await target.entered.future; // 合并已进入临界区，锁被持有

          final other = AuthSessionPersistence.debugNew(
            backend: backend,
            directoryProvider: () async => dir,
          )..debugForceFileLock = true;
          var revokeDone = false;
          final revokeFuture = other
              .revoke(CredentialSessionDomain.unified)
              .then((_) => revokeDone = true);

          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(
            revokeDone,
            isFalse,
            reason: '合并持锁期间 revoke 不得插入（锁内的合并是原子提交的一部分）',
          );

          target.gate.complete();
          final committed = await commitFuture;
          expect(committed, isNotNull);
          await revokeFuture;

          // revoke 在合并提交之后执行，最终为登出态。
          expect(
            (await persistence.read(CredentialSessionDomain.unified)).active,
            isFalse,
          );
          final merged = await target.jar.loadForRequest(uri);
          expect(merged.map((cookie) => cookie.name), contains('ISO'));
        },
      );

      test('rejected epoch does not run the merge', () async {
        final uri = Uri.parse('https://newca.zjxu.edu.cn/cas/login');
        final sourceJar = CookieJar();
        await sourceJar.saveFromResponse(uri, [Cookie('ISO', '1')..path = '/']);
        final session = await IsolatedAuthSession.create(
          sourceJar: sourceJar,
          seedUris: [uri],
          template: Dio(),
        );
        final target = _GatedJar();
        await persistence.revoke(CredentialSessionDomain.unified);

        final committed = await persistence.commitWithIsolatedSession(
          CredentialSessionDomain.unified,
          account: 'A',
          expectedEpoch: 0,
          session: session,
          target: target.jar,
        );
        expect(committed, isNull);
        expect(target.entered.isCompleted, isFalse);
      });
    },
  );
}

/// 合并入口可控的 CookieJar：用于证明合并发生在提交锁内。
class _GatedJar {
  final _GatedStorage storage = _GatedStorage();

  late final PersistCookieJar jar = PersistCookieJar(
    storage: storage,
    persistSession: true,
  );

  Completer<void> get entered => storage.entered;
  Completer<void> get gate => storage.gate;
}

class _GatedStorage extends Storage {
  final Map<String, String> values = <String, String>{};
  final Completer<void> entered = Completer<void>();
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll(List<String> keys) async {
    for (final key in keys) {
      values.remove(key);
    }
  }
}
