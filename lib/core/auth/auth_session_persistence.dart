import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import 'auth_file_lock.dart';
import 'credential_store.dart';
import 'isolated_auth_session.dart';

/// 会话 envelope 的读写后端抽象：默认走 [CredentialStore]（安全存储），
/// 测试可注入可控后端验证「阻塞写 + 退出」等时序。
abstract class AuthSessionEnvelopeBackend {
  Future<CredentialSessionEnvelope> read(CredentialSessionDomain domain);
  Future<void> write(
    CredentialSessionDomain domain,
    CredentialSessionEnvelope envelope,
  );
}

class _CredentialStoreBackend implements AuthSessionEnvelopeBackend {
  const _CredentialStoreBackend();

  @override
  Future<CredentialSessionEnvelope> read(CredentialSessionDomain domain) =>
      CredentialStore.instance.readSessionEnvelope(domain);

  @override
  Future<void> write(
    CredentialSessionDomain domain,
    CredentialSessionEnvelope envelope,
  ) => CredentialStore.instance.writeSessionEnvelope(domain, envelope);
}

/// [AuthSessionPersistence.commit] 成功时返回的提交句柄：记录本次真正写入的
/// 账号与**新的持久 epoch**，供调用方在迟到/失效路径上做条件撤销，
/// 而不是无条件全局 revoke（那会杀掉后来居上的新会话）。
class SessionCommitResult {
  const SessionCommitResult({required this.account, required this.epoch});

  final String account;

  /// 提交成功后 envelope 的 epoch（= 提交时 expectedEpoch + 1）。
  final int epoch;
}

/// 同域持久会话提交的协调器。
///
/// 解决的核心竞态：登录成功先改内存身份、再异步写凭据，两条 key 分开写，
/// 期间 logout 会把旧身份写回。这里用**单 key envelope + epoch 条件提交**：
/// - [commit] 在同一把文件锁内「读 epoch → 相等才写 account+active(epoch+1)」，
///   epoch 已被 [revoke] 推进（logout）则拒绝写入，绝不复活旧身份；
/// - [revoke] 在同一把锁内写 inactive 并推进 epoch；
/// - 同 isolate 内再加一层 per-domain 串行链，保证 commit/revoke 不交错。
///
/// 文件锁只覆盖毫秒级本地读改写（安全存储写 + cookie 落盘），不在锁内做
/// 网络。CookieJar 的跨 isolate 文件竞争不在本类职责内。
class AuthSessionPersistence {
  AuthSessionPersistence._({
    AuthSessionEnvelopeBackend? backend,
    Future<Directory> Function()? directoryProvider,
  }) : _backend = backend ?? const _CredentialStoreBackend(),
       debugDirectoryProvider = directoryProvider;

  static final AuthSessionPersistence instance = AuthSessionPersistence._();

  @visibleForTesting
  static AuthSessionPersistence debugNew({
    required AuthSessionEnvelopeBackend backend,
    required Future<Directory> Function() directoryProvider,
  }) => AuthSessionPersistence._(
    backend: backend,
    directoryProvider: directoryProvider,
  );

  final AuthSessionEnvelopeBackend _backend;

  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;

  /// 测试用：强制关闭文件锁（仅保留同 isolate 串行链，避免 fake-async 下
  /// 真实文件 I/O 不完成导致挂起）。
  @visibleForTesting
  bool debugDisableFileLock = false;

  /// 测试用：强制启用文件锁（覆盖 FLUTTER_TEST 自动关闭），用于跨实例测试。
  @visibleForTesting
  bool debugForceFileLock = false;

  final Map<CredentialSessionDomain, Future<void>> _chains = {};

  bool get _skipFileLock =>
      !debugForceFileLock &&
      (debugDisableFileLock || Platform.environment['FLUTTER_TEST'] == 'true');

  @visibleForTesting
  void debugReset() {
    debugDirectoryProvider = null;
    debugDisableFileLock = false;
    debugForceFileLock = false;
    _chains.clear();
  }

  Future<CredentialSessionEnvelope> read(CredentialSessionDomain domain) =>
      _backend.read(domain);

  Future<int> readEpoch(CredentialSessionDomain domain) async =>
      (await _backend.read(domain)).epoch;

  /// 条件提交：仅当持久 epoch 仍等于 [expectedEpoch] 时写入并推进 epoch。
  ///
  /// 成功返回 [SessionCommitResult]（含新 epoch），epoch 不匹配返回 null。
  /// **没有**任意回调入口；需要把隔离会话 cookie 合并回共享 jar 时使用
  /// [commitWithIsolatedSession]。
  Future<SessionCommitResult?> commit(
    CredentialSessionDomain domain, {
    required String account,
    required int expectedEpoch,
  }) => _commitLocked(domain, account: account, expectedEpoch: expectedEpoch);

  /// 条件提交 + 在**同一把锁内**把隔离 challenge 会话的 cookie 合并回
  /// [target]（epoch 校验通过之后才合并，因此被拒绝的提交不改动任何 cookie）。
  ///
  /// 合并原语是固定的 [IsolatedAuthSession.commitTo]，公有 API 不暴露任何可
  /// 传入任意异步工作的回调——这是 API 形状约束，不是注释约定。
  Future<SessionCommitResult?> commitWithIsolatedSession(
    CredentialSessionDomain domain, {
    required String account,
    required int expectedEpoch,
    required IsolatedAuthSession session,
    required CookieJar target,
  }) => _commitLocked(
    domain,
    account: account,
    expectedEpoch: expectedEpoch,
    merge: () => session.commitTo(target),
  );

  Future<SessionCommitResult?> _commitLocked(
    CredentialSessionDomain domain, {
    required String account,
    required int expectedEpoch,
    Future<void> Function()? merge,
  }) {
    return _serialize<SessionCommitResult?>(domain, () async {
      return _withDomainFileLock<SessionCommitResult?>(domain, () async {
        final current = await _backend.read(domain);
        if (current.epoch != expectedEpoch) return null;
        if (merge != null) await merge();
        final committedEpoch = expectedEpoch + 1;
        await _backend.write(
          domain,
          CredentialSessionEnvelope(
            account: account,
            active: true,
            epoch: committedEpoch,
          ),
        );
        return SessionCommitResult(account: account, epoch: committedEpoch);
      });
    });
  }

  /// 条件撤销：仅当 envelope 仍**精确等于**本次提交写入的账号/epoch 时才
  /// 置 inactive 并推进 epoch。
  ///
  /// 用于迟到提交的失效收尾：若期间已有新登录提交（epoch 前进）或已登出
  /// （inactive / epoch 前进），本方法为 no-op，绝不误伤新会话。
  Future<bool> revokeIfCurrent(
    CredentialSessionDomain domain, {
    required String account,
    required int epoch,
  }) {
    return _serialize<bool>(domain, () async {
      return _withDomainFileLock<bool>(domain, () async {
        final current = await _backend.read(domain);
        if (!current.active) return false;
        if (current.account != account) return false;
        if (current.epoch != epoch) return false;
        await _backend.write(
          domain,
          CredentialSessionEnvelope(epoch: epoch + 1),
        );
        return true;
      });
    });
  }

  /// 立即持久撤销：写 inactive 并推进 epoch，使任何携带旧 epoch 的迟到
  /// 提交被 [commit] 拒绝。
  Future<void> revoke(CredentialSessionDomain domain) {
    return _serialize(domain, () async {
      await _withDomainFileLock(domain, () async {
        final current = await _backend.read(domain);
        await _backend.write(
          domain,
          CredentialSessionEnvelope(epoch: current.epoch + 1),
        );
      });
    });
  }

  Future<T> _withDomainFileLock<T>(
    CredentialSessionDomain domain,
    Future<T> Function() action,
  ) async {
    if (_skipFileLock) return action();
    final lock = await _lock(domain);
    return lock.withLock(action);
  }

  /// 在同域锁内、且当前会话仍是该账号该 epoch 时执行 [action]。
  ///
  /// 条件：envelope `active == true` 且 `account == account` 且
  /// `epoch == expectedEpoch`，否则返回 null 且**不执行** [action]。
  ///
  /// 与 [commit] 的关键区别：本方法**不写 envelope、不递增 epoch**，只读校验后
  /// 在锁内执行本地回调——供 cache lane 做「按当前身份保存/清理本地缓存」。
  /// [action] 必须是本地 cache 读写，**不得**反调 auth、不得发网络（避免在
  /// 锁内长时间阻塞）。
  Future<T?> withCurrentSession<T>(
    CredentialSessionDomain domain, {
    required String account,
    required int expectedEpoch,
    required Future<T> Function() action,
  }) {
    return _serialize<T?>(domain, () async {
      return _withDomainFileLock<T?>(domain, () async {
        final current = await _backend.read(domain);
        if (!current.active) return null;
        if (current.account != account) return null;
        if (current.epoch != expectedEpoch) return null;
        return await action();
      });
    });
  }

  /// 同 isolate 串行链：commit 与 revoke 不会交错执行。
  Future<T> _serialize<T>(
    CredentialSessionDomain domain,
    Future<T> Function() action,
  ) {
    final previous = _chains[domain] ?? Future<void>.value();
    final completer = Completer<void>();
    _chains[domain] = completer.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        completer.complete();
      }
    }();
  }

  Future<AuthFileLock> _lock(CredentialSessionDomain domain) async {
    final dir = await _resolveDir();
    final name = domain == CredentialSessionDomain.unified
        ? 'auth_session_unified.lock'
        : 'auth_session_academic.lock';
    return AuthFileLock(
      lockFile: File('${dir.path}${Platform.pathSeparator}$name'),
      acquireTimeout: const Duration(seconds: 10),
    );
  }

  Future<Directory> _resolveDir() async {
    final override = debugDirectoryProvider;
    if (override != null) return override();
    try {
      return await getApplicationSupportDirectory();
    } catch (error) {
      // 平台目录不可用（如测试环境未注册 path_provider）时回退临时目录，
      // 仅影响锁文件位置，不影响会话内容（存于 CredentialStore）。
      AppLogger.instance.auth(LogLevel.warn, '会话锁目录解析失败，回退临时目录', error: error);
      return Directory.systemTemp;
    }
  }
}
