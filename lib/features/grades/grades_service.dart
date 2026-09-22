import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/academic_auth_guard.dart';
import '../../core/auth/auth_session_persistence.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/private_cache_store.dart';
import '../../core/network/dio_client.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import 'grades_model.dart';

class GradesService {
  GradesService._() {
    ZhengfangAuth.instance.addListener(_onAuthChanged);
  }

  static final GradesService instance = GradesService._();

  /// 成绩缓存有效期：15 分钟（与考试一致，供 resume 协调）。
  static const refreshWindow = Duration(minutes: 15);

  /// 单条原子 JSON envelope（owner + updatedAt + durable epoch + payload）。
  static const cacheKey = 'grades_private_cache_v1';

  // 旧多 key / 旧无 epoch 格式：无法证明属于哪个持久身份纪元，安全舍弃。
  static const _legacyDataKey = 'grades_cached_data';
  static const _legacyTimeKey = 'grades_cached_at';
  static const _legacyOwnerKey = 'grades_cached_owner';

  static final PrivateCacheStore _store = SharedPreferencesPrivateCacheStore(
    cacheKey,
  );

  List<GradeEntry>? _cachedGrades;
  DateTime? _lastSavedAt;
  String? _cachedOwner;
  int? _cachedEpoch;

  /// 当前有效的持久身份纪元（最近一次读到 durable session 的 epoch）。
  /// 采纳缓存时与 [_cachedEpoch] 同步；身份变化 / 登出清空。
  int? _validEpoch;

  _GradesInFlight? _inFlight;
  int _latestGeneration = 0;

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障，
  /// 用于在锁前推进 epoch 以验证 restore 竞态。
  @visibleForTesting
  Future<void> Function()? debugRestoreBarrier;

  /// 上一次已清空内存缓存时看到的教务身份，用于识别登出 / 换号。
  (String?, bool) _lastAuthIdentity = (null, false);

  /// 教务身份修订号：登录 / 登出 / 换号 / 恢复时递增，异步期间发生
  /// 变化的旧结果一律丢弃。仅进程内有效。
  int get _authRevision => ZhengfangAuth.instance.sessionRevision;

  String? get _currentStudentId {
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) return null;
    final id = auth.currentStudentId?.trim();
    return (id == null || id.isEmpty) ? null : id;
  }

  /// 身份变化时清空内存缓存；getter 另有归属校验兜底。
  void _onAuthChanged() {
    final auth = ZhengfangAuth.instance;
    final identity = (auth.currentStudentId, auth.isLoggedIn);
    if (identity == _lastAuthIdentity) return;
    _lastAuthIdentity = identity;
    _clearMemoryCache();
    _validEpoch = null;
  }

  void _clearMemoryCache() {
    _cachedGrades = null;
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

  bool get isCacheFresh {
    if (_lastSavedAt == null) return false;
    return DateTime.now().difference(_lastSavedAt!) < refreshWindow;
  }

  bool get isStale => !isCacheFresh;

  /// 只在缓存归属与当前教务账号一致、且 epoch 仍是当前有效持久 epoch 时可见。
  List<GradeEntry>? get cachedGrades {
    final cached = _cachedGrades;
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

  Future<bool> restoreCache() async {
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

            final list = _decodeEntries(envelope.payload);
            if (list == null) return false;

            _cachedGrades = list;
            _lastSavedAt = envelope.updatedAt;
            _cachedOwner = current;
            _cachedEpoch = capturedEpoch;
            _validEpoch = capturedEpoch;
            return true;
          },
        );

    return adopted == true;
  }

  /// 旧多 key 格式无法证明属于哪个持久身份纪元，直接清掉，下次刷新。
  Future<void> _cleanupLegacyCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final hasLegacy =
        prefs.containsKey(_legacyDataKey) ||
        prefs.containsKey(_legacyTimeKey) ||
        prefs.containsKey(_legacyOwnerKey);
    if (!hasLegacy) return;
    await prefs.remove(_legacyDataKey);
    await prefs.remove(_legacyTimeKey);
    await prefs.remove(_legacyOwnerKey);
  }

  Future<List<GradeEntry>> fetchGrades(
    String studentId, {
    bool forceRefresh = false,
  }) async {
    final owner = studentId.trim();
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) throw const GradesAuthExpiredException();
    final current = auth.currentStudentId?.trim();
    if (owner.isEmpty ||
        current == null ||
        current.isEmpty ||
        owner != current) {
      throw const GradesRequestException('学号与当前登录身份不一致，请重新查询');
    }

    // 请求开始即固定持久身份（active + 账号 + epoch）。
    final durable = await _readDurableSession(owner);
    if (durable == null) throw const GradesAuthExpiredException();
    _observeDurableEpoch(durable.epoch);
    final guard = _GradesGuard(
      revision: auth.sessionRevision,
      owner: owner,
      durableEpoch: durable.epoch,
    );

    if (!forceRefresh &&
        _cachedGrades != null &&
        _cachedOwner == owner &&
        _cachedEpoch == durable.epoch &&
        isCacheFresh &&
        _isGuardCurrent(guard)) {
      return _cachedGrades!;
    }

    final existing = _inFlight;
    if (existing != null && existing.generation == _latestGeneration) {
      // 同一最新请求直接共享；force 不被较旧的非 force 请求短路。
      if (!forceRefresh || existing.force) return existing.future;
    }

    final generation = ++_latestGeneration;
    final future = _fetchGradesRemote(
      owner: owner,
      guard: guard,
      generation: generation,
    );
    final inFlight = _GradesInFlight(
      generation: generation,
      force: forceRefresh,
      future: future,
    );
    _inFlight = inFlight;
    return future.whenComplete(() {
      if (identical(_inFlight, inFlight)) _inFlight = null;
    });
  }

  Future<List<GradeEntry>> _fetchGradesRemote({
    required String owner,
    required _GradesGuard guard,
    required int generation,
  }) async {
    await DioClient.instance.ensureInitialized();
    final dio = ZhengfangAuth.instance.academicDio;
    final ts = DateTime.now().millisecondsSinceEpoch;
    try {
      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        authExpiredException: const GradesAuthExpiredException(),
        request: () => dio.post<Map<String, dynamic>>(
          ZhengfangAuth.instance.buildPortalUrl('/cjcx/cjcx_cxDgXscj.html'),
          queryParameters: {
            'doType': 'query',
            'gnmkdm': 'N305005',
            'su': owner,
          },
          data:
              'xnm=&xqm=&_search=false&nd=$ts'
              '&queryModel.showCount=100&queryModel.currentPage=1'
              '&queryModel.sortName=&queryModel.sortOrder=asc&time=1',
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            headers: {
              'Referer': ZhengfangAuth.instance.academicServiceUrl,
              'X-Requested-With': 'XMLHttpRequest',
            },
          ),
        ),
      );

      final items = resp.data?['items'] as List<dynamic>? ?? [];
      final grades = items
          .cast<Map<String, dynamic>>()
          .map(GradeEntry.fromJson)
          .toList();

      // 内存身份 / 纪元变化必须丢弃；已被更新请求淘汰的旧结果不提交。
      _ensureGuard(guard);
      if (generation != _latestGeneration) return grades;

      final now = DateTime.now();
      final committed = await AuthSessionPersistence.instance
          .withCurrentSession<bool>(
            CredentialSessionDomain.academic,
            account: owner,
            expectedEpoch: guard.durableEpoch,
            action: () async {
              // 锁内仅本地 cache IO，不反调 auth / 不发网络。
              if (generation != _latestGeneration) {
                return false;
              }
              await _store.write(
                PrivateCacheEnvelope(
                  owner: owner,
                  updatedAt: now,
                  epoch: guard.durableEpoch,
                  payload: grades.map((e) => e.toJson()).toList(),
                ),
              );
              return true;
            },
          );

      // 持久 epoch 已推进（登出 / 同账号重登 / 其它 isolate 撤销）：fail closed。
      if (committed == null) throw const GradesAuthExpiredException();
      // 写后内存身份 / generation 又变化：不 notify、不覆盖 memory。
      if (committed &&
          _isGuardCurrent(guard) &&
          generation == _latestGeneration) {
        _cachedGrades = grades;
        _lastSavedAt = now;
        _cachedOwner = owner;
        _cachedEpoch = guard.durableEpoch;
        _validEpoch = guard.durableEpoch;
        CampusDataChangeBus.instance.notifyChanged();
      }
      return grades;
    } on GradesAuthExpiredException {
      rethrow;
    } on AcademicAuthExpiredException catch (e) {
      // 自动登录被暂停（连续身份失败）时透传该语义，供页面区分「需要手动登录」。
      throw GradesAuthExpiredException(
        automaticLoginPaused: e.automaticLoginPaused,
      );
    }
  }

  bool _isGuardCurrent(_GradesGuard guard) {
    if (guard.revision != _authRevision) return false;
    return ZhengfangAuth.instance.currentStudentId?.trim() == guard.owner;
  }

  void _ensureGuard(_GradesGuard guard) {
    if (_isGuardCurrent(guard)) return;
    throw const GradesRequestException('登录状态已变化，请重新查询');
  }

  static List<GradeEntry>? _decodeEntries(Object? payload) {
    if (payload is! List) return null;
    try {
      return payload
          .cast<Map<String, dynamic>>()
          .map(GradeEntry.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
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

/// 一次抓取开始时固定的教务身份与持久纪元。
class _GradesGuard {
  const _GradesGuard({
    required this.revision,
    required this.owner,
    required this.durableEpoch,
  });

  final int revision;
  final String owner;
  final int durableEpoch;
}

class _GradesInFlight {
  const _GradesInFlight({
    required this.generation,
    required this.force,
    required this.future,
  });

  final int generation;
  final bool force;
  final Future<List<GradeEntry>> future;
}

class GradesRequestException implements Exception {
  const GradesRequestException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GradesAuthExpiredException extends GradesRequestException {
  const GradesAuthExpiredException({this.automaticLoginPaused = false})
    : super('登录状态已过期，请重新登录');

  /// 自动登录是否因连续身份失败被暂停。为 true 时页面应提示用户手动登录
  /// 一次（登录成功后会由登录控件重新武装自动登录）。
  final bool automaticLoginPaused;
}
