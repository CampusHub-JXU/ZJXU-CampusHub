import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/academic/academic_exceptions.dart';
import '../../core/academic/zhengfang_query_post.dart';
import '../../core/auth/academic_auth_guard.dart';
import '../../core/auth/auth_session_persistence.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/private_cache_store.dart';
import '../../core/network/dio_client.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import '../../core/academic/exam_model.dart';

class ExamService {
  ExamService._() {
    _lastAuthIdentity = (
      ZhengfangAuth.instance.currentStudentId,
      ZhengfangAuth.instance.isLoggedIn,
    );
    ZhengfangAuth.instance.addListener(_onAuthChanged);
  }

  static final ExamService instance = ExamService._();

  /// 考试缓存有效期：15 分钟（供 resume 协调）。
  static const refreshWindow = Duration(minutes: 15);

  /// 单条原子 JSON envelope（owner + updatedAt + durable epoch + payload）。
  static const cacheKey = 'exam_private_cache_v1';

  // 旧多 key / 旧无 epoch 格式：无法证明属于哪个持久身份纪元，安全舍弃。
  static const _legacyDataKey = 'exam_cached_data';
  static const _legacyTimeKey = 'exam_cached_at';
  static const _legacyOwnerKey = 'exam_cached_owner';

  static final PrivateCacheStore _store = SharedPreferencesPrivateCacheStore(
    cacheKey,
  );

  List<ExamEntry>? _cachedExams;
  DateTime? _lastSavedAt;
  String? _cachedOwner;
  int? _cachedEpoch;

  /// 当前有效的持久身份纪元（最近一次读到 durable session 的 epoch）。
  int? _validEpoch;

  _ExamInFlight? _inFlight;
  int _latestGeneration = 0;

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障。
  @visibleForTesting
  Future<void> Function()? debugRestoreBarrier;

  /// 上一次已清空内存缓存时看到的教务身份，用于识别登出 / 换号。
  (String?, bool) _lastAuthIdentity = (null, false);

  /// 教务身份修订号：登录 / 登出 / 换号 / 恢复时递增，异步期间发生
  /// 变化的旧结果一律丢弃。仅进程内有效。
  int get _authRevision => ZhengfangAuth.instance.sessionRevision;

  String? get _currentStudentId => ZhengfangAuth.instance.verifiedStudentId;

  /// 身份变化时清空内存缓存；getter 另有归属校验兜底。
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
    _cachedExams = null;
    _lastSavedAt = null;
    _cachedOwner = null;
    _cachedEpoch = null;
  }

  /// 记录当前 durable epoch；与已采纳记录 epoch 不一致即失效内存缓存。
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
  ///
  /// 缓存按教务 studentId 隔离；当前考试数据不分学期（`fetchExams` 无 term
  /// 入参），因此不把 term 写进归属，避免自造维度。
  List<ExamEntry>? get cachedExams {
    final cached = _cachedExams;
    if (cached == null) return null;
    final owner = _cachedOwner;
    if (owner == null || owner != _currentStudentId) return null;
    if (_cachedEpoch == null || _cachedEpoch != _validEpoch) return null;
    return cached;
  }

  ExamEntry? get nextExam {
    final exams = cachedExams;
    if (exams == null) return null;
    for (final exam in exams) {
      if (exam.hasDate && !exam.isPast) return exam;
    }
    return null;
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

  /// Restore exam cache from disk for the current explicit student identity.
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
            if (!envelope.belongsTo(current, capturedEpoch)) return false;

            final list = _decodeEntries(envelope.payload);
            if (list == null) return false;

            list.sort(_compareExams);
            _cachedExams = list;
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

  /// Fetch exams from network, with cache-first strategy.
  ///
  /// 必须已登录教务；显式 [studentId] 若提供，必须与当前登录身份一致。
  Future<List<ExamEntry>> fetchExams({
    String? studentId,
    bool forceRefresh = false,
  }) async {
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) throw const ExamAuthExpiredException();
    final current = auth.verifiedStudentId;
    if (current == null) throw const ExamAuthExpiredException();
    final provided = studentId?.trim();
    if (studentId != null && (provided == null || provided.isEmpty)) {
      throw const ExamRequestException('未获取到学号，请先登录教务系统');
    }
    if (provided != null && provided != current) {
      throw const ExamRequestException('学号与当前登录身份不一致，请重新查询');
    }
    final resolvedId = current;

    // 请求开始即固定持久身份（active + 账号 + epoch）。
    final durable = await _readDurableSession(resolvedId);
    if (durable == null) throw const ExamAuthExpiredException();
    _observeDurableEpoch(durable.epoch);
    final guard = _ExamGuard(
      revision: auth.sessionRevision,
      owner: resolvedId,
      durableEpoch: durable.epoch,
    );

    if (!forceRefresh &&
        _cachedExams != null &&
        _cachedOwner == resolvedId &&
        _cachedEpoch == durable.epoch &&
        isCacheFresh &&
        _isGuardCurrent(guard)) {
      return _cachedExams!;
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
    final future = _fetchExamsRemote(
      resolvedId: resolvedId,
      guard: guard,
      generation: generation,
    );
    final inFlight = _ExamInFlight(
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

  Future<List<ExamEntry>> _fetchExamsRemote({
    required String resolvedId,
    required _ExamGuard guard,
    required int generation,
  }) async {
    await DioClient.instance.ensureInitialized();

    // 与课表一致：优先以教务系统解析的当前学期为准，失败时按日期推算。
    final termContext =
        await CurrentTermResolver.instance.resolve(studentId: resolvedId) ??
        ScheduleTermContext.current();
    final academicYear = termContext.academicYear;
    final term = termContext.term;
    final ts = DateTime.now().millisecondsSinceEpoch;

    try {
      _ensureGuard(guard);
      final query = await postZhengfangQuery(
        path: '/kwgl/kscx_cxXsksxxIndex.html',
        gnmkdm: 'N358105',
        owner: resolvedId,
        formBody:
            'xnm=$academicYear&xqm=$term&ksmcdmb_id=&kch=&kc=&ksrq='
            '&kkbm_id=&ksmc=&_search=false&nd=$ts'
            '&queryModel.showCount=100&queryModel.currentPage=1'
            '&queryModel.sortName=&queryModel.sortOrder=asc&time=0',
        authExpiredException: const ExamAuthExpiredException(),
        unexpectedResponseException: const ExamRequestException(
          '考试响应异常，保留上次成功数据',
        ),
      );
      final guarded = query.guarded;

      final settledGuard = _ExamGuard(
        revision: guarded.revision,
        owner: resolvedId,
        durableEpoch: guarded.epoch!,
      );
      final exams =
          query.items
              .cast<Map<String, dynamic>>()
              .map(ExamEntry.fromJson)
              .toList()
            ..sort(_compareExams);

      // 内存身份 / 纪元变化必须丢弃；已被更新请求淘汰的旧结果不提交。
      _ensureGuard(settledGuard);
      if (generation != _latestGeneration) return exams;

      final now = DateTime.now();
      final committed = await AuthSessionPersistence.instance
          .withCurrentSession<bool>(
            CredentialSessionDomain.academic,
            account: resolvedId,
            expectedEpoch: settledGuard.durableEpoch,
            action: () async {
              // 锁内仅本地 cache IO，不反调 auth / 不发网络。
              if (generation != _latestGeneration) {
                return false;
              }
              await _store.write(
                PrivateCacheEnvelope(
                  owner: resolvedId,
                  updatedAt: now,
                  epoch: settledGuard.durableEpoch,
                  payload: exams.map((e) => e.toJson()).toList(),
                ),
              );
              return true;
            },
          );

      if (committed == null) throw const ExamAuthExpiredException();
      if (committed &&
          _isGuardCurrent(settledGuard) &&
          generation == _latestGeneration) {
        _cachedExams = exams;
        _lastSavedAt = now;
        _cachedOwner = resolvedId;
        _cachedEpoch = settledGuard.durableEpoch;
        _validEpoch = settledGuard.durableEpoch;
        CampusDataChangeBus.instance.notifyChanged();
      }
      return exams;
    } on ExamAuthExpiredException {
      rethrow;
    } on AcademicAuthRecoveryPendingException {
      // 临时恢复失败交给前台调度退避；保留现有缓存，不触发强制登录 UI。
      rethrow;
    } on AcademicAuthExpiredException catch (e) {
      // 自动登录被暂停（连续身份失败）时透传该语义，供页面区分「需要手动登录」。
      throw ExamAuthExpiredException(
        automaticLoginPaused: e.automaticLoginPaused,
      );
    } on DioException catch (e) {
      throw ExamRequestException('获取考试信息失败：${e.message}');
    }
  }

  static int _compareExams(ExamEntry a, ExamEntry b) {
    if (!a.hasDate && !b.hasDate) return 0;
    if (!a.hasDate) return 1;
    if (!b.hasDate) return -1;
    return a.examDate!.compareTo(b.examDate!);
  }

  bool _isGuardCurrent(_ExamGuard guard) {
    if (guard.revision != _authRevision) return false;
    return ZhengfangAuth.instance.currentStudentId?.trim() == guard.owner;
  }

  void _ensureGuard(_ExamGuard guard) {
    if (_isGuardCurrent(guard)) return;
    throw const ExamRequestException('登录状态已变化，请重新查询');
  }

  static List<ExamEntry>? _decodeEntries(Object? payload) {
    if (payload is! List) return null;
    try {
      return payload
          .cast<Map<String, dynamic>>()
          .map(ExamEntry.fromJson)
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
class _ExamGuard {
  const _ExamGuard({
    required this.revision,
    required this.owner,
    required this.durableEpoch,
  });

  final int revision;
  final String owner;
  final int durableEpoch;
}

class _ExamInFlight {
  const _ExamInFlight({
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
  final Future<List<ExamEntry>> future;
}

class ExamRequestException extends AcademicRequestException {
  const ExamRequestException(super.message);
}

class ExamAuthExpiredException extends ExamRequestException
    implements AcademicSessionExpired {
  const ExamAuthExpiredException({this.automaticLoginPaused = false})
    : super(academicSessionExpiredMessage);

  @override
  final bool automaticLoginPaused;
}
