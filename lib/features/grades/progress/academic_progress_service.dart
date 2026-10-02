import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/academic/academic_exceptions.dart';
import '../../../core/auth/academic_auth_guard.dart';
import '../../../core/auth/zhengfang_auth.dart';
import '../../../core/cache/private_cache_store.dart';
import '../../../core/cache/private_owner_cache.dart';
import '../../../core/network/dio_client.dart';
import 'academic_progress_model.dart';
import 'academic_progress_parser.dart';

/// 学生学业情况查询（gnmkdm N105515）。
///
/// 一次查询 = GET 首页 HTML（统计区 + 学分要求树 + 隐藏参数）+ 对每个末节点
/// 串行 POST 课程明细（与原页面一样逐个请求，避免并发触发反爬）。全程只读，
/// 经 [AcademicAuthGuard.guardWithSession] 做过期识别与有界恢复。
class AcademicProgressService {
  AcademicProgressService._();

  static final AcademicProgressService instance = AcademicProgressService._();

  static const gnmkdm = 'N105515';
  static const indexPath = '/xsxy/xsxyqk_cxXsxyqkIndex.html';
  static const planCoursesPath = '/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html';
  static const groupCoursesPath = '/xsxy/xsxyqk_cxJxzxjhxfyqFKcxx.html';

  static const refreshWindow = Duration(minutes: 15);
  static const cacheKey = 'academic_progress_private_cache_v1';

  final PrivateOwnerCache<AcademicProgressReport> _cache =
      PrivateOwnerCache<AcademicProgressReport>(
        store: SharedPreferencesPrivateCacheStore(cacheKey),
        refreshWindow: refreshWindow,
        encode: (report) => report.toJson(),
        decode: _decodeReport,
      );

  DateTime? get updatedAt => _cache.updatedAt;

  bool get isCacheFresh => _cache.isFresh;

  /// 只在缓存归属与当前教务账号一致时可见。
  AcademicProgressReport? get cachedReport => _cache.cached;

  Future<bool> restoreCache() => _cache.restore();

  Future<AcademicProgressReport> fetchReport({bool forceRefresh = false}) {
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) {
      throw const AcademicProgressAuthExpiredException();
    }
    final owner = auth.verifiedStudentId?.trim() ?? '';
    if (owner.isEmpty) {
      throw const AcademicProgressAuthExpiredException();
    }
    return _cache.load(
      owner: owner,
      forceRefresh: forceRefresh,
      authExpired: () => const AcademicProgressAuthExpiredException(),
      identityChanged: () =>
          const AcademicProgressRequestException('登录状态已变化，请重新查询'),
      fetch: _fetchRemote,
    );
  }

  Future<PrivateCacheFetched<AcademicProgressReport>> _fetchRemote(
    PrivateCacheRun run,
  ) async {
    final owner = run.owner;
    await DioClient.instance.ensureInitialized();
    try {
      run.ensureCurrent();
      final indexUrl = ZhengfangAuth.instance.buildPortalUrl(indexPath);
      final index = await _guard<String>(
        () => ZhengfangAuth.instance.academicDio.get<String>(
          indexUrl,
          queryParameters: {'gnmkdm': gnmkdm, 'layout': 'default', 'su': owner},
          options: Options(
            responseType: ResponseType.plain,
            headers: {'Referer': ZhengfangAuth.instance.academicServiceUrl},
          ),
        ),
        owner,
      );
      final html = index.response.data;
      if (index.response.statusCode != 200 || html == null) {
        throw const AcademicProgressRequestException('学业情况页面响应异常');
      }
      final page = parseAcademicProgressIndex(html);
      if (page == null) {
        throw const AcademicProgressRequestException('学业情况页面结构无法识别');
      }

      final courses = <String, List<AcademicProgressCourse>>{};
      final referer = ZhengfangAuth.instance.buildPortalUrl(
        indexPath,
        queryParameters: {'gnmkdm': gnmkdm, 'layout': 'default', 'su': owner},
      );
      for (final leaf in page.roots.expand((r) => r.leaves)) {
        if (!leaf.needsCourses) continue;
        run.ensureCurrent();
        courses[leaf.id] = await _fetchCourses(
          leaf,
          page.queryParams,
          owner: owner,
          referer: referer,
          expectedEpoch: index.epoch!,
        );
      }
      run.ensureCurrent();
      final report = AcademicProgressReport(
        summary: page.summary,
        roots: [for (final r in page.roots) _attachCourses(r, courses)],
      );
      return PrivateCacheFetched(
        value: report,
        revision: index.revision,
        durableEpoch: index.epoch!,
      );
    } on AcademicProgressAuthExpiredException {
      rethrow;
    } on AcademicAuthRecoveryPendingException {
      rethrow;
    } on AcademicAuthExpiredException catch (e) {
      throw AcademicProgressAuthExpiredException(
        automaticLoginPaused: e.automaticLoginPaused,
      );
    }
  }

  Future<List<AcademicProgressCourse>> _fetchCourses(
    RequirementNode leaf,
    Map<String, String> params, {
    required String owner,
    required String referer,
    required int expectedEpoch,
  }) async {
    final path = leaf.usesGroupEndpoint ? groupCoursesPath : planCoursesPath;
    final guarded = await _guard<dynamic>(
      () => ZhengfangAuth.instance.academicDio.post<dynamic>(
        ZhengfangAuth.instance.buildPortalUrl(path),
        queryParameters: {'gnmkdm': gnmkdm, 'su': owner},
        data: buildCourseQueryBody(leaf.id, params),
        options: Options(
          contentType: 'application/x-www-form-urlencoded;charset=UTF-8',
          headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
        ),
      ),
      owner,
    );
    // 课程请求中途若发生恢复登录，epoch 推进：整份结果不再属于同一会话。
    if (guarded.epoch != expectedEpoch) {
      throw const AcademicProgressAuthExpiredException();
    }
    var data = guarded.response.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        data = null;
      }
    }
    if (guarded.response.statusCode != 200 || data is! List) {
      throw const AcademicProgressRequestException('课程明细响应异常，保留上次成功数据');
    }
    return [
      for (final item in data)
        if (item is Map)
          AcademicProgressCourse.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<AcademicGuardedResponse<T>> _guard<T>(
    Future<Response<T>> Function() request,
    String owner,
  ) async {
    final guarded = await AcademicAuthGuard.guardWithSession<T>(
      authExpiredException: const AcademicProgressAuthExpiredException(),
      request: request,
    );
    if (guarded.account != owner || guarded.epoch == null) {
      throw const AcademicProgressAuthExpiredException();
    }
    return guarded;
  }

  static RequirementNode _attachCourses(
    RequirementNode node,
    Map<String, List<AcademicProgressCourse>> courses,
  ) {
    if (node.children.isEmpty) {
      final list = courses[node.id];
      return list == null ? node : node.copyWith(courses: list);
    }
    return node.copyWith(
      children: [for (final c in node.children) _attachCourses(c, courses)],
    );
  }

  static AcademicProgressReport? _decodeReport(Object? payload) {
    if (payload is! Map) return null;
    try {
      return AcademicProgressReport.fromJson(payload.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  void debugReset() => _cache.debugReset();
}

/// 课程明细 POST 的表单体：节点 ID + 首页隐藏参数（不传 `xh_id` / `csrftoken`）。
@visibleForTesting
String buildCourseQueryBody(String nodeId, Map<String, String> params) {
  final fields = <String, String>{
    'xfyqjd_id': nodeId,
    for (final key in academicProgressQueryKeys) key: params[key] ?? '',
  };
  return fields.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
}

class AcademicProgressRequestException extends AcademicRequestException {
  const AcademicProgressRequestException(super.message);
}

class AcademicProgressAuthExpiredException
    extends AcademicProgressRequestException
    implements AcademicSessionExpired {
  const AcademicProgressAuthExpiredException({
    this.automaticLoginPaused = false,
  }) : super(academicSessionExpiredMessage);

  @override
  final bool automaticLoginPaused;
}
