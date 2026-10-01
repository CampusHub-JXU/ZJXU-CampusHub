import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/academic/academic_exceptions.dart';
import '../../core/academic/exam_model.dart';
import '../../core/academic/zhengfang_query_post.dart';
import '../../core/auth/academic_auth_guard.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/private_cache_store.dart';
import '../../core/cache/private_owner_cache.dart';
import '../../core/network/dio_client.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/schedule_term_context.dart';

class ExamService {
  ExamService._();

  static final ExamService instance = ExamService._();

  /// 考试缓存有效期：15 分钟（供 resume 协调）。
  static const refreshWindow = Duration(minutes: 15);

  /// 单条原子 JSON envelope（owner + updatedAt + durable epoch + payload）。
  static const cacheKey = 'exam_private_cache_v1';

  /// 私有缓存内核（归属 / epoch / TTL / inflight / 条件落盘），与成绩共用。
  /// 缓存值始终按考试日期排序（恢复与抓取一致）。
  final PrivateOwnerCache<List<ExamEntry>> _cache =
      PrivateOwnerCache<List<ExamEntry>>(
        store: SharedPreferencesPrivateCacheStore(cacheKey),
        refreshWindow: refreshWindow,
        encode: (exams) => exams.map((e) => e.toJson()).toList(),
        decode: _decodeEntries,
        // 旧多 key / 旧无 epoch 格式：无法证明属于哪个持久身份纪元，安全舍弃。
        legacyKeys: const [
          'exam_cached_data',
          'exam_cached_at',
          'exam_cached_owner',
        ],
      );

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障。
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
  ///
  /// 缓存按教务 studentId 隔离；当前考试数据不分学期（`fetchExams` 无 term
  /// 入参），因此不把 term 写进归属，避免自造维度。
  List<ExamEntry>? get cachedExams => _cache.cached;

  ExamEntry? get nextExam {
    final exams = cachedExams;
    if (exams == null) return null;
    for (final exam in exams) {
      if (exam.hasDate && !exam.isPast) return exam;
    }
    return null;
  }

  /// Restore exam cache from disk for the current explicit student identity.
  Future<bool> restoreCache() => _cache.restore();

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

    return _cache.load(
      owner: current,
      forceRefresh: forceRefresh,
      authExpired: () => const ExamAuthExpiredException(),
      identityChanged: () => const ExamRequestException('登录状态已变化，请重新查询'),
      fetch: (run) => _fetchExamsRemote(run),
    );
  }

  Future<PrivateCacheFetched<List<ExamEntry>>> _fetchExamsRemote(
    PrivateCacheRun run,
  ) async {
    final resolvedId = run.owner;
    await DioClient.instance.ensureInitialized();

    // 与课表一致：优先以教务系统解析的当前学期为准，失败时按日期推算。
    final termContext =
        await CurrentTermResolver.instance.resolve(studentId: resolvedId) ??
        ScheduleTermContext.current();
    final academicYear = termContext.academicYear;
    final term = termContext.term;
    final ts = DateTime.now().millisecondsSinceEpoch;

    try {
      run.ensureCurrent();
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

      final exams =
          query.items
              .cast<Map<String, dynamic>>()
              .map(ExamEntry.fromJson)
              .toList()
            ..sort(_compareExams);
      return PrivateCacheFetched(
        value: exams,
        revision: guarded.revision,
        durableEpoch: guarded.epoch!,
      );
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

  static List<ExamEntry>? _decodeEntries(Object? payload) {
    if (payload is! List) return null;
    try {
      return payload
          .cast<Map<String, dynamic>>()
          .map(ExamEntry.fromJson)
          .toList()
        ..sort(_compareExams);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  void debugReset() => _cache.debugReset();
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
