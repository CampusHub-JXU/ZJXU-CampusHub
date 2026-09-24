import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_token_binding.dart';

import '../../helpers/gated_secure_storage.dart';
import '../../helpers/test_setup.dart';

/// 直接针对 [ChangxingTokenBinding] 的落盘串行化 / fail-closed 契约测试：
/// 通过 [GatedSecureStoragePlatform] 把 secure storage 的 write / delete 挂起，
/// 确定性地复现「旧会话的落盘操作晚到」竞态。
void main() {
  const v2Key = ChangxingTokenBinding.storageKeyV2;

  late GatedSecureStoragePlatform storage;
  late ChangxingTokenBinding binding;

  setUp(() async {
    await resetTestEnvironment();
    storage = GatedSecureStoragePlatform()..install();
    binding = ChangxingTokenBinding();
  });

  int revision() => UnifiedAuthService.instance.sessionRevision;

  void signIn(String account) {
    UnifiedAuthService.instance.debugSetSession(active: true, account: account);
    UnifiedAuthService.instance.notifyListeners();
  }

  void signOut() {
    UnifiedAuthService.instance.debugSetSession(active: false, account: null);
    UnifiedAuthService.instance.notifyListeners();
  }

  Map<String, dynamic> envelopeOnDisk() =>
      jsonDecode(storage.data[v2Key]!) as Map<String, dynamic>;

  /// 有限次协作式让出事件循环：用于 pre-fix 实现会「立即读盘并挂起」、
  /// 修复后实现会被串行队列挡住因而永不读盘的场景，让出后即可断言差异，
  /// 不依赖精确时序（重复让出只是一个上限）。
  Future<void> pumpEventLoop([int turns = 32]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('Changxing token binding storage serialization', () {
    test(
      'in-flight A save cannot overwrite the persisted B envelope',
      () async {
        signIn('A');
        final revisionA = revision();

        storage.operationLog.clear();
        final heldA = storage.holdNext(SecureStorageOperation.write, v2Key);
        final saveA = binding.saveIfCurrent(
          token: 'token-a',
          owner: 'A',
          revision: revisionA,
        );
        await heldA.started.future;

        // A → B：身份切换必须立刻作废 A 的绑定。
        signOut();
        signIn('B');
        final revisionB = revision();
        expect(binding.currentToken, isNull);

        final saveB = binding.saveIfCurrent(
          token: 'token-b',
          owner: 'B',
          revision: revisionB,
        );

        // 串行化：B 的写入必须排在 A 的临界区之后，不能与 A 的写入交错。
        expect(storage.operationLog, ['write:$v2Key']);

        heldA.release();
        expect(await saveA, isFalse);
        expect(await saveB, isTrue);

        // B 赢：落盘 envelope 与内存绑定都属于 B，A 的 token 在 B 下不可读。
        expect(envelopeOnDisk(), {'owner': 'B', 'token': 'token-b'});
        expect(binding.debugBoundOwner, 'B');
        expect(binding.debugBoundRevision, revisionB);
        expect(binding.currentToken, 'token-b');
      },
    );

    test('same-account relogin: the newer revision save wins and the old revision never binds', () async {
      signIn('A');
      final revisionV1 = revision();
      final held = storage.holdNext(SecureStorageOperation.write, v2Key);
      final saveV1 = binding.saveIfCurrent(
        token: 'token-v1',
        owner: 'A',
        revision: revisionV1,
      );
      await held.started.future;

      // 同账号重登：登出 + 再登录，revision 推进。
      signOut();
      signIn('A');
      final revisionV2 = revision();
      expect(revisionV2, isNot(revisionV1));

      final saveV2 = binding.saveIfCurrent(
        token: 'token-v2',
        owner: 'A',
        revision: revisionV2,
      );

      held.release();
      expect(await saveV1, isFalse);
      expect(await saveV2, isTrue);

      expect(envelopeOnDisk(), {'owner': 'A', 'token': 'token-v2'});
      expect(binding.debugBoundRevision, revisionV2);
      expect(binding.currentToken, 'token-v2');
    });

    test('a stale 500001 clear queued after the B save no-ops and keeps the B envelope', () async {
      signIn('A');
      final revisionA = revision();
      expect(
        await binding.saveIfCurrent(
          token: 'token-a',
          owner: 'A',
          revision: revisionA,
        ),
        isTrue,
      );

      signOut();
      signIn('B');
      final revisionB = revision();

      storage.operationLog.clear();
      final heldB = storage.holdNext(SecureStorageOperation.write, v2Key);
      final saveB = binding.saveIfCurrent(
        token: 'token-b',
        owner: 'B',
        revision: revisionB,
      );
      await heldB.started.future;
      expect(storage.operationLog, ['write:$v2Key']);

      // A 的迟到 500001 清理排在 B 的写入之后：执行时必须 no-op。
      final staleClear = binding.clearIfCurrent('A', revisionA);
      expect(storage.operationLog, ['write:$v2Key']);

      heldB.release();
      expect(await saveB, isTrue);
      await staleClear;

      expect(envelopeOnDisk(), {'owner': 'B', 'token': 'token-b'});
      expect(binding.currentToken, 'token-b');
      expect(storage.operationLog, isNot(contains('delete:$v2Key')));
    });

    test('explicit logout queued mid-flight cannot remove the B envelope saved later', () async {
      signIn('A');
      final revisionA = revision();
      expect(
        await binding.saveIfCurrent(
          token: 'token-a',
          owner: 'A',
          revision: revisionA,
        ),
        isTrue,
      );

      // 用一次在途的 A 保存占住串行队列：logout 只能排队等待。
      final heldSave = storage.holdNext(SecureStorageOperation.write, v2Key);
      final inFlightSave = binding.saveIfCurrent(
        token: 'token-a-2',
        owner: 'A',
        revision: revisionA,
      );
      await heldSave.started.future;

      final logout = binding.clear(); // 调用时身份仍是 A

      signOut();
      signIn('B');
      final revisionB = revision();
      final saveB = binding.saveIfCurrent(
        token: 'token-b',
        owner: 'B',
        revision: revisionB,
      );

      heldSave.release();
      expect(await inFlightSave, isFalse);
      await logout;
      expect(await saveB, isTrue);

      expect(envelopeOnDisk(), {'owner': 'B', 'token': 'token-b'});
      expect(binding.debugBoundOwner, 'B');
      expect(binding.currentToken, 'token-b');
    });

    test(
      'clear still removes the envelope when the identity is unchanged',
      () async {
        signIn('A');
        final revisionA = revision();
        expect(
          await binding.saveIfCurrent(
            token: 'token-a',
            owner: 'A',
            revision: revisionA,
          ),
          isTrue,
        );

        await binding.clear();

        expect(storage.data[v2Key], isNull);
        expect(binding.hasToken, isFalse);
        expect(binding.debugBoundOwner, isNull);
      },
    );

    test(
      'stale restore read cannot overwrite a newer same-session token save',
      () async {
        signIn('A');
        final revisionA = revision();
        // 盘上已有 A 的旧 token，绑定尚未恢复。
        storage.data[v2Key] = jsonEncode({'owner': 'A', 'token': 'token-old'});

        // 读盘在返回前被挂起：模拟慢读。
        final heldRead = storage.holdNext(SecureStorageOperation.read, v2Key);
        final restoreFuture = binding.restore();
        await heldRead.started.future;
        expect(binding.currentToken, isNull);

        // 同账号同 revision 的 token 刷新：新的 CAS 保存。
        final saveFuture = binding.saveIfCurrent(
          token: 'token-new',
          owner: 'A',
          revision: revisionA,
        );

        // 让出事件循环：pre-fix 的 save 会在挂起的读期间完成并绑定新 token；
        // 修复后 save 被串行队列挡住，读盘未完成前不会到达平台层。
        await pumpEventLoop();
        expect(
          storage.operationLog
              .where((entry) => entry.startsWith('write:'))
              .toList(),
          isEmpty,
        );

        heldRead.release();
        await restoreFuture;
        await saveFuture;

        // 新 token 必须在内存与落盘都是最终值，旧读盘结果不得回写内存。
        expect(binding.debugBoundOwner, 'A');
        expect(binding.debugBoundRevision, revisionA);
        expect(binding.currentToken, 'token-new');
        expect(envelopeOnDisk(), {'owner': 'A', 'token': 'token-new'});
      },
    );

    test('restore queued behind an in-flight save reuses the newer binding without reading stale disk', () async {
      signIn('A');
      final revisionA = revision();
      storage.data[v2Key] = jsonEncode({'owner': 'A', 'token': 'token-old'});

      // 先占住队列：一次在途的 save（写盘挂起）。
      final heldWrite = storage.holdNext(SecureStorageOperation.write, v2Key);
      final saveFuture = binding.saveIfCurrent(
        token: 'token-new',
        owner: 'A',
        revision: revisionA,
      );
      await heldWrite.started.future;

      // restore 排在 save 之后。
      final heldRead = storage.holdNext(SecureStorageOperation.read, v2Key);
      final restoreFuture = binding.restore();

      heldWrite.release();
      // 修复后：restore 等 save 完成后由 `_restored` 复核直接返回，不回读；
      // pre-fix：restore 立即读盘并命中 heldRead（返回旧值）。
      await pumpEventLoop();
      final restoreReadStarted = heldRead.started.isCompleted;
      // 不让 pre-fix 的挂起读永久阻塞：修复后这里是不会命中的 no-op。
      heldRead.release();

      await saveFuture;
      await restoreFuture;

      expect(restoreReadStarted, isFalse);
      expect(storage.operationLog, isNot(contains('read:$v2Key')));
      expect(binding.debugBoundOwner, 'A');
      expect(binding.currentToken, 'token-new');
      expect(envelopeOnDisk(), {'owner': 'A', 'token': 'token-new'});
    });
  });

  group('Changxing stored envelope parsing fails closed', () {
    test('non-string owner is refused instead of coerced', () async {
      signIn('20260001');
      storage.data[v2Key] = '{"owner":20260001,"token":{"raw":"secret"}}';

      await binding.restore();

      expect(binding.hasToken, isFalse);
      expect(binding.debugBoundOwner, isNull);
      expect(binding.currentToken, isNull);
    });

    test('non-string token is refused instead of coerced', () async {
      signIn('A');
      storage.data[v2Key] = '{"owner":"A","token":12345}';

      await binding.restore();

      expect(binding.hasToken, isFalse);
      expect(binding.debugBoundOwner, isNull);
    });

    test(
      'valid string envelope still restores for the matching owner',
      () async {
        signIn('A');
        storage.data[v2Key] = jsonEncode({'owner': 'A', 'token': 'token-a'});

        await binding.restore();

        expect(binding.currentToken, 'token-a');
        expect(binding.debugBoundOwner, 'A');
      },
    );
  });
}
