import 'package:flutter/foundation.dart';

import '../../core/academic/academic_exceptions.dart';
import '../../core/academic/zhengfang_query_post.dart';
import '../../core/auth/academic_auth_guard.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/private_cache_store.dart';
import '../../core/cache/private_owner_cache.dart';
import '../../core/network/dio_client.dart';
import 'grades_model.dart';

class GradesService {
  GradesService._();

  static final GradesService instance = GradesService._();

  /// 成绩缓存有效期：15 分钟（与考试一致，供 resume 协调）。
  static const refreshWindow = Duration(minutes: 15);

  /// 单条原子 JSON envelope（owner + updatedAt + durable epoch + payload）。
  static const cacheKey = 'grades_private_cache_v1';

  /// 私有缓存内核（归属 / epoch / TTL / inflight / 条件落盘），与考试共用。
  final PrivateOwnerCache<List<GradeEntry>> _cache =
      PrivateOwnerCache<List<GradeEntry>>(
        store: SharedPreferencesPrivateCacheStore(cacheKey),
        refreshWindow: refreshWindow,
        encode: (grades) => grades.map((e) => e.toJson()).toList(),
        decode: _decodeEntries,
        // 旧多 key / 旧无 epoch 格式：无法证明属于哪个持久身份纪元，安全舍弃。
        legacyKeys: const [
          'grades_cached_data',
          'grades_cached_at',
          'grades_cached_owner',
        ],
      );

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障，
  /// 用于在锁前推进 epoch 以验证 restore 竞态。
  @visibleForTesting
  Future<void> Function()? get debugRestoreBarrier =>
      _cache.debugRestoreBarrier;

  @visibleForTesting
  set debugRestoreBarrier(Future<void> Function()? barrier) =>
      _cache.debugRestoreBarrier = barrier;

  DateTime? get updatedAt => _cache.updatedAt;

  bool get isCacheFresh => _cache.isFresh;

  bool get isStale => _cache.isStale;

  /// 只在缓存归属与当前教务账号一致、且 epoch 仍是当前有效持久 epoch 时可见。
  List<GradeEntry>? get cachedGrades => _cache.cached;

  Future<bool> restoreCache() => _cache.restore();

  Future<List<GradeEntry>> fetchGrades(
    String studentId, {
    bool forceRefresh = false,
  }) async {
    final owner = studentId.trim();
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) throw const GradesAuthExpiredException();
    final current = auth.verifiedStudentId;
    if (owner.isEmpty || current == null || owner != current) {
      throw const GradesRequestException('学号与当前登录身份不一致，请重新查询');
    }

    return _cache.load(
      owner: owner,
      forceRefresh: forceRefresh,
      authExpired: () => const GradesAuthExpiredException(),
      identityChanged: () => const GradesRequestException('登录状态已变化，请重新查询'),
      fetch: (run) => _fetchGradesRemote(run),
    );
  }

  Future<PrivateCacheFetched<List<GradeEntry>>> _fetchGradesRemote(
    PrivateCacheRun run,
  ) async {
    final owner = run.owner;
    await DioClient.instance.ensureInitialized();
    final ts = DateTime.now().millisecondsSinceEpoch;
    try {
      run.ensureCurrent();
      final query = await postZhengfangQuery(
        path: '/cjcx/cjcx_cxDgXscj.html',
        gnmkdm: 'N305005',
        owner: owner,
        formBody:
            'xnm=&xqm=&_search=false&nd=$ts'
            '&queryModel.showCount=100&queryModel.currentPage=1'
            '&queryModel.sortName=&queryModel.sortOrder=asc&time=1',
        authExpiredException: const GradesAuthExpiredException(),
        unexpectedResponseException: const GradesRequestException(
          '成绩响应异常，保留上次成功数据',
        ),
      );
      final guarded = query.guarded;

      final grades = query.items
          .cast<Map<String, dynamic>>()
          .map(GradeEntry.fromJson)
          .toList();
      return PrivateCacheFetched(
        value: grades,
        revision: guarded.revision,
        durableEpoch: guarded.epoch!,
      );
    } on GradesAuthExpiredException {
      rethrow;
    } on AcademicAuthRecoveryPendingException {
      // 临时恢复失败交给前台调度退避；保留现有缓存，不触发强制登录 UI。
      rethrow;
    } on AcademicAuthExpiredException catch (e) {
      // 自动登录被暂停（连续身份失败）时透传该语义，供页面区分「需要手动登录」。
      throw GradesAuthExpiredException(
        automaticLoginPaused: e.automaticLoginPaused,
      );
    }
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
  void debugReset() => _cache.debugReset();
}

class GradesRequestException extends AcademicRequestException {
  const GradesRequestException(super.message);
}

class GradesAuthExpiredException extends GradesRequestException
    implements AcademicSessionExpired {
  const GradesAuthExpiredException({this.automaticLoginPaused = false})
    : super(academicSessionExpiredMessage);

  @override
  final bool automaticLoginPaused;
}
