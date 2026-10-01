import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_session_persistence.dart';
import '../auth/credential_store.dart';
import '../auth/zhengfang_auth.dart';
import '../system_surface/campus_data_change_bus.dart';
import 'private_cache_store.dart';

/// 一次 [PrivateOwnerCache.load] 抓取开始时固定的教务身份与持久纪元。
class PrivateCacheRun {
  const PrivateCacheRun._({
    required this.owner,
    required this.revision,
    required this.durableEpoch,
    required this._ensureCurrent,
  });

  /// 发起抓取时已验证的教务账号。
  final String owner;

  /// 发起抓取时的进程内身份修订号。
  final int revision;

  /// 发起抓取时的持久身份纪元。
  final int durableEpoch;

  final void Function() _ensureCurrent;

  /// 内存身份（修订号 + 账号）仍与发起时一致；否则抛调用方提供的
  /// 「登录状态已变化」异常。应在网络请求发出前调用。
  void ensureCurrent() => _ensureCurrent();
}

/// 抓取回调的产出：数据 + 响应对应的身份 receipt（修订号与持久纪元）。
class PrivateCacheFetched<T> {
  const PrivateCacheFetched({
    required this.value,
    required this.revision,
    required this.durableEpoch,
  });

  final T value;
  final int revision;
  final int durableEpoch;
}

/// 按教务账号归属的私有读穿缓存内核（成绩 / 考试共用）。
///
/// 语义（任何一条都不得放松）：
/// - 落盘为**固定 storage key** 上的单条原子 [PrivateCacheEnvelope]
///   （owner + updatedAt + 持久 epoch + payload）；
/// - 展示（[cached]）要求内存记录的 owner 等于当前已验证教务账号，且其 epoch
///   仍是当前有效持久 epoch；身份变化 / 登出监听同步清空内存；
/// - 恢复（[restore]）在 auth 同域锁内、且会话仍是该账号该 epoch 时才采纳，
///   旧纪元 / 他人 / 损坏记录一律不采纳；旧多 key 格式直接舍弃；
/// - 抓取以 `sessionRevision` + generation 守卫：登出 / 换号 / 同账号重登后，
///   旧请求的迟到结果被丢弃；落盘只在持久会话 active + 账号 + epoch 仍匹配时
///   于同域锁内发生（`withCurrentSession`），否则 fail closed；
/// - 同一最新请求共享 inflight，force 不被较旧的非 force 请求短路。
///
/// 内核**不**做账号入参校验与异常类型选择：调用方先完成「已登录 / 显式账号
/// 一致」检查，并把「会话过期」「登录状态已变化」两种失败以工厂回调注入，
/// 以保留各功能自己的异常类型。
class PrivateOwnerCache<T extends Object> {
  PrivateOwnerCache({
    required this._store,
    required this.refreshWindow,
    required this._encode,
    required this._decode,
    this._legacyKeys = const <String>[],
  }) {
    _lastAuthIdentity = (
      ZhengfangAuth.instance.currentStudentId,
      ZhengfangAuth.instance.isLoggedIn,
    );
    ZhengfangAuth.instance.addListener(_onAuthChanged);
  }

  /// 缓存有效期。
  final Duration refreshWindow;

  final PrivateCacheStore _store;
  final Object? Function(T value) _encode;
  final T? Function(Object? payload) _decode;

  /// 旧多 key / 旧无 epoch 格式：无法证明属于哪个持久身份纪元，安全舍弃。
  final List<String> _legacyKeys;

  T? _cached;
  DateTime? _lastSavedAt;
  String? _cachedOwner;
  int? _cachedEpoch;

  /// 当前有效的持久身份纪元（最近一次读到 durable session 的 epoch）。
  /// 采纳缓存时与 [_cachedEpoch] 同步；身份变化 / 登出清空。
  int? _validEpoch;

  _InFlight<T>? _inFlight;
  int _latestGeneration = 0;

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障，
  /// 用于在锁前推进 epoch 以验证 restore 竞态。
  Future<void> Function()? debugRestoreBarrier;

  /// 上一次已清空内存缓存时看到的教务身份，用于识别登出 / 换号。
  (String?, bool) _lastAuthIdentity = (null, false);

  /// 教务身份修订号：登录 / 登出 / 换号 / 恢复时递增，异步期间发生
  /// 变化的旧结果一律丢弃。仅进程内有效。
  int get _authRevision => ZhengfangAuth.instance.sessionRevision;

  String? get _currentStudentId => ZhengfangAuth.instance.verifiedStudentId;

  /// 身份变化时清空内存缓存；[cached] 另有归属校验兜底。
  void _onAuthChanged() {
    final auth = ZhengfangAuth.instance;
    final identity = (auth.currentStudentId, auth.isLoggedIn);
    if (identity == _lastAuthIdentity) return;
    _lastAuthIdentity = identity;
    _clearMemoryCache();
    _validEpoch = null;
    _inFlight = null;
    _latestGeneration++;
  }

  void _clearMemoryCache() {
    _cached = null;
    _lastSavedAt = null;
    _cachedOwner = null;
    _cachedEpoch = null;
  }

  /// 记录当前 durable epoch；若与已采纳记录的 epoch 不一致，说明身份纪元已
  /// 推进（登出/同账号重登/其它 isolate），立即失效内存缓存（fail closed）。
  void _observeDurableEpoch(int epoch) {
    if (_cachedEpoch != null && _cachedEpoch != epoch) {
      _clearMemoryCache();
    }
    _validEpoch = epoch;
  }

  DateTime? get updatedAt => _lastSavedAt;

  bool get isFresh {
    if (_lastSavedAt == null) return false;
    return DateTime.now().difference(_lastSavedAt!) < refreshWindow;
  }

  bool get isStale => !isFresh;

  /// 只在缓存归属与当前教务账号一致、且 epoch 仍是当前有效持久 epoch 时可见。
  T? get cached {
    final cached = _cached;
    if (cached == null) return null;
    final owner = _cachedOwner;
    if (owner == null || owner != _currentStudentId) return null;
    if (_cachedEpoch == null || _cachedEpoch != _validEpoch) return null;
    return cached;
  }

  /// 持久身份快照：必须 active 且账号与 [account] 一致，否则 fail closed。
  Future<CredentialSessionEnvelope?> _readDurableSession(String account) async {
    final durable = await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.academic,
    );
    if (!durable.active) return null;
    if (durable.account?.trim() != account) return null;
    return durable;
  }

  /// 从磁盘恢复当前已验证教务账号、当前持久纪元的缓存；采纳返回 true。
  Future<bool> restore() async {
    await _cleanupLegacyCache();

    final current = _currentStudentId;
    if (current == null) return false;

    final durable = await _readDurableSession(current);
    if (durable == null) return false;
    final capturedEpoch = durable.epoch;
    _observeDurableEpoch(capturedEpoch);
    final capturedRevision = _authRevision;
    final capturedGeneration = _latestGeneration;

    // 测试注入点：可在获取同域锁之前推进持久 epoch，验证 restore 竞态。
    await debugRestoreBarrier?.call();

    // 读 + 采纳都在 auth 同域锁内、且当前会话仍是该账号该 epoch 时执行；
    // 锁内只做本地 cache IO 与本地字段校验，不反调 auth / 不发网络。
    final adopted = await AuthSessionPersistence.instance
        .withCurrentSession<bool>(
          CredentialSessionDomain.academic,
          account: current,
          expectedEpoch: capturedEpoch,
          action: () async {
            if (_currentStudentId != current) return false;
            if (_authRevision != capturedRevision) return false;
            if (_latestGeneration != capturedGeneration) return false;

            final envelope = await _store.read();
            if (envelope == null) return false;
            // 旧无 epoch 记录解析为 null；epoch 不匹配说明是旧身份纪元的记录。
            if (!envelope.belongsTo(current, capturedEpoch)) return false;

            final value = _decodeSafely(envelope.payload);
            if (value == null) return false;

            _cached = value;
            _lastSavedAt = envelope.updatedAt;
            _cachedOwner = current;
            _cachedEpoch = capturedEpoch;
            _validEpoch = capturedEpoch;
            return true;
          },
        );

    return adopted == true;
  }

  /// 解码器抛异常也按「无有效记录」处理（fail closed）。
  T? _decodeSafely(Object? payload) {
    try {
      return _decode(payload);
    } catch (_) {
      return null;
    }
  }

  /// 旧多 key 格式无法证明属于哪个持久身份纪元，直接清掉，下次刷新。
  Future<void> _cleanupLegacyCache() async {
    if (_legacyKeys.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (!_legacyKeys.any(prefs.containsKey)) return;
    for (final key in _legacyKeys) {
      await prefs.remove(key);
    }
  }

  /// 缓存优先读取。[owner] 必须已由调用方校验为当前已验证教务账号。
  ///
  /// - 无有效持久会话 → 抛 [authExpired]；
  /// - 缓存新鲜且身份仍当前 → 直接返回缓存；
  /// - 否则（或 [forceRefresh]）经 [fetch] 抓取并在身份 receipt 通过后落盘；
  ///   身份中途变化抛 [identityChanged]，持久纪元已推进抛 [authExpired]。
  Future<T> load({
    required String owner,
    required bool forceRefresh,
    required Object Function() authExpired,
    required Object Function() identityChanged,
    required Future<PrivateCacheFetched<T>> Function(PrivateCacheRun run)
    fetch,
  }) async {
    final auth = ZhengfangAuth.instance;

    // 请求开始即固定持久身份（active + 账号 + epoch）。
    final durable = await _readDurableSession(owner);
    if (durable == null) throw authExpired();
    _observeDurableEpoch(durable.epoch);
    final guard = _Guard(
      revision: auth.sessionRevision,
      owner: owner,
      durableEpoch: durable.epoch,
    );

    final cached = _cached;
    if (!forceRefresh &&
        cached != null &&
        _cachedOwner == owner &&
        _cachedEpoch == durable.epoch &&
        isFresh &&
        _isGuardCurrent(guard)) {
      return cached;
    }

    final existing = _inFlight;
    if (existing != null &&
        existing.generation == _latestGeneration &&
        existing.revision == guard.revision &&
        existing.owner == guard.owner) {
      // 同一最新请求直接共享；force 不被较旧的非 force 请求短路。
      if (!forceRefresh || existing.force) return existing.future;
    }

    final generation = ++_latestGeneration;
    final future = _run(
      guard: guard,
      generation: generation,
      authExpired: authExpired,
      identityChanged: identityChanged,
      fetch: fetch,
    );
    final inFlight = _InFlight<T>(
      revision: guard.revision,
      owner: guard.owner,
      generation: generation,
      force: forceRefresh,
      future: future,
    );
    _inFlight = inFlight;
    return future.whenComplete(() {
      if (identical(_inFlight, inFlight)) _inFlight = null;
    });
  }

  Future<T> _run({
    required _Guard guard,
    required int generation,
    required Object Function() authExpired,
    required Object Function() identityChanged,
    required Future<PrivateCacheFetched<T>> Function(PrivateCacheRun run)
    fetch,
  }) async {
    final owner = guard.owner;
    final fetched = await fetch(
      PrivateCacheRun._(
        owner: owner,
        revision: guard.revision,
        durableEpoch: guard.durableEpoch,
        ensureCurrent: () {
          if (!_isGuardCurrent(guard)) throw identityChanged();
        },
      ),
    );

    final settledGuard = _Guard(
      revision: fetched.revision,
      owner: owner,
      durableEpoch: fetched.durableEpoch,
    );
    final value = fetched.value;

    // 内存身份 / 纪元变化必须丢弃；已被更新请求淘汰的旧结果不提交。
    if (!_isGuardCurrent(settledGuard)) throw identityChanged();
    if (generation != _latestGeneration) return value;

    final now = DateTime.now();
    final committed = await AuthSessionPersistence.instance
        .withCurrentSession<bool>(
          CredentialSessionDomain.academic,
          account: owner,
          expectedEpoch: settledGuard.durableEpoch,
          action: () async {
            // 锁内仅本地 cache IO，不反调 auth / 不发网络。
            if (generation != _latestGeneration) return false;
            await _store.write(
              PrivateCacheEnvelope(
                owner: owner,
                updatedAt: now,
                epoch: settledGuard.durableEpoch,
                payload: _encode(value),
              ),
            );
            return true;
          },
        );

    // 持久 epoch 已推进（登出 / 同账号重登 / 其它 isolate 撤销）：fail closed。
    if (committed == null) throw authExpired();
    // 写后内存身份 / generation 又变化：不 notify、不覆盖 memory。
    if (committed &&
        _isGuardCurrent(settledGuard) &&
        generation == _latestGeneration) {
      _cached = value;
      _lastSavedAt = now;
      _cachedOwner = owner;
      _cachedEpoch = settledGuard.durableEpoch;
      _validEpoch = settledGuard.durableEpoch;
      CampusDataChangeBus.instance.notifyChanged();
    }
    return value;
  }

  bool _isGuardCurrent(_Guard guard) {
    if (guard.revision != _authRevision) return false;
    return ZhengfangAuth.instance.currentStudentId?.trim() == guard.owner;
  }

  void debugReset() {
    _clearMemoryCache();
    _validEpoch = null;
    _inFlight = null;
    _latestGeneration = 0;
    debugRestoreBarrier = null;
    _lastAuthIdentity = (
      ZhengfangAuth.instance.currentStudentId,
      ZhengfangAuth.instance.isLoggedIn,
    );
  }
}

class _Guard {
  const _Guard({
    required this.revision,
    required this.owner,
    required this.durableEpoch,
  });

  final int revision;
  final String owner;
  final int durableEpoch;
}

class _InFlight<T> {
  const _InFlight({
    required this.revision,
    required this.owner,
    required this.generation,
    required this.force,
    required this.future,
  });

  final int revision;
  final String owner;
  final int generation;
  final bool force;
  final Future<T> future;
}
