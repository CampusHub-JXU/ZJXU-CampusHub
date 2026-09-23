import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/academic_auth_guard.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/network/dio_client.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import 'schedule_cache_snapshot.dart';
import 'schedule_change_rule.dart';
import 'schedule_model.dart';
import 'schedule_term_context.dart';

export 'schedule_change_rule.dart';

part 'schedule_service_change_parser.dart';
part 'schedule_service_helpers.dart';

class ScheduleRequestException implements Exception {
  const ScheduleRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ScheduleAuthExpiredException extends ScheduleRequestException {
  const ScheduleAuthExpiredException({this.automaticLoginPaused = false})
    : super('登录状态已过期，请重新登录');

  /// 自动登录是否因连续身份失败被暂停。为 true 时页面应提示用户手动登录
  /// 一次（登录成功后会由登录控件重新武装自动登录）。
  final bool automaticLoginPaused;
}

class ScheduleLoadResult {
  const ScheduleLoadResult({
    this.snapshot,
    this.message,
    this.requiresLogin = false,
    this.usedCache = false,
    this.didRefresh = false,
    this.effectiveTermContext,
    this.automaticLoginPaused = false,
    this.settledRevision,
  });

  final ScheduleCacheSnapshot? snapshot;
  final String? message;
  final bool requiresLogin;
  final bool usedCache;
  final bool didRefresh;

  /// 自动识别发生学期回退时，实际展示课表的学期上下文；
  /// null 表示与请求时的学期一致。
  final ScheduleTermContext? effectiveTermContext;

  /// 本次 require 登录是否由「自动登录已暂停」触发；仅影响未登录引导文案。
  final bool automaticLoginPaused;

  /// guard 恢复 / 自动登录后本次加载被证实为当前身份的 revision。
  ///
  /// null 表示本次未发生身份推进（沿用调用方请求开始时的 revision）。
  /// 调用方做后续 notify / 上一学期 fallback 时必须使用该值，不能用请求
  /// 开始时的旧 revision，否则合法恢复会被误判为身份已变化。
  final int? settledRevision;

  bool get hasData => snapshot?.hasData ?? false;
}

class ScheduleService {
  ScheduleService._();

  static final ScheduleService instance = ScheduleService._();

  static const _cacheStorageKey = 'zjxu_schedule_cache_snapshots_v1';
  // Keep a conservative pre-semester window so advance notices are not hidden.
  // This affects display only; it does not prove a message's term or alter courses.
  static const _notificationPreSemesterWindow = Duration(days: 60);

  final Map<String, ScheduleCacheSnapshot> _snapshots = {};
  final Map<String, Future<ScheduleLoadResult>> _inflightLoads = {};

  SharedPreferences? _prefs;
  bool _restored = false;

  /// 同 isolate 内整 map 持久写入的串行链，见 [_persistSnapshot]。
  Future<void> _persistWriteChain = Future<void>.value();

  Dio get _dio => ZhengfangAuth.instance.academicDio;

  String _academicUrl(String path) =>
      ZhengfangAuth.instance.buildPortalUrl(path);

  int getCurrentWeek() {
    return SemesterCalendar.instance.weekForDate(DateTime.now());
  }

  ScheduleTermContext getCurrentTermContext([DateTime? now]) {
    return ScheduleTermContext.current(now);
  }

  String? get preferredStudentId {
    return _resolveStudentId();
  }

  Future<void> restoreCache() async {
    _prefs = await SharedPreferences.getInstance();
    _snapshots.clear();

    final raw = _prefs!.getString(_cacheStorageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map<String, dynamic>) {
              _snapshots[entry.key] = ScheduleCacheSnapshot.fromJson(value);
            }
          }
        }
      } catch (_) {
        _snapshots.clear();
      }
    }

    // 恢复只把磁盘快照读入内存，**不**据「上次学号」复活任何展示：读取入口
    // （preferredSnapshot / loadScheduleSnapshot / 网络请求）一律要求当前
    // 已登录身份。
    //
    // 边界：持久缓存是单个 JSON 字符串（整张 map 的 read-modify-write），
    // 不保证跨 isolate 的原子写入；同步 getter 也只在下次 `restoreCache()`
    // 或本地写入后才知道别的 isolate 的外部变更。这里不宣称跨 isolate 即时
    // 一致，只做同 isolate 的 owner 归属与 revision 校验。
    _restored = true;
  }

  ScheduleCacheSnapshot? preferredSnapshot({
    ScheduleTermContext? termContext,
    String? studentId,
  }) {
    final resolvedStudentId = _resolveStudentId(studentId);
    if (resolvedStudentId == null || resolvedStudentId.isEmpty) return null;
    final context =
        termContext ??
        CurrentTermResolver.instance.knownCurrentTerm ??
        getCurrentTermContext();
    final snapshot = _snapshots[_cacheKeyFor(resolvedStudentId, context)];
    if (snapshot == null) return null;
    return _snapshotForDisplay(snapshot);
  }

  Future<ScheduleLoadResult> loadScheduleSnapshot({
    ScheduleTermContext? termContext,
    String? studentId,
    bool forceRefresh = false,
  }) async {
    await _ensureRestored();

    // 身份是准入前提：无当前已登录身份（或显式学号与当前账号不符）一律
    // requiresLogin，零请求、零私有展示，绝不回退到旧学号快照。
    final identity = _currentIdentity();
    if (identity == null) {
      return const ScheduleLoadResult(requiresLogin: true, message: '请先登录教务系统');
    }
    final requested = studentId?.trim();
    if (requested != null &&
        requested.isNotEmpty &&
        requested != identity.owner) {
      return const ScheduleLoadResult(
        requiresLogin: true,
        message: '学号与当前登录身份不一致，请重新登录',
      );
    }
    final owner = identity.owner;
    final revision = identity.revision;

    final autoResolveTerm = termContext == null;
    final ScheduleTermContext context;
    if (autoResolveTerm) {
      final resolution = await _resolveAutoTermContext(
        owner: owner,
        revision: revision,
      );
      if (resolution.identityChanged) return _identityChangedResult();
      context = resolution.context;
    } else {
      context = termContext;
    }
    if (!_isIdentityCurrent(owner, revision)) {
      return _identityChangedResult();
    }

    final result = await _loadSnapshotForContext(
      studentId: owner,
      context: context,
      forceRefresh: forceRefresh,
      allowChangeRules: _canFetchChangeRulesFor(context),
      owner: owner,
      revision: revision,
    );
    // guard 恢复 / 自动登录成功会推进 revision；notify 与上一学期 fallback
    // 必须以本次已被验证的 settled revision 判定，而不是请求开始时的旧值，
    // 否则合法恢复会被当作身份变化而丢弃数据。
    final settledRevision = result.settledRevision ?? revision;
    if (result.didRefresh && _isIdentityCurrent(owner, settledRevision)) {
      CampusDataChangeBus.instance.notifyChanged();
    }

    // 未显式指定学期且当前学期没有课表数据（常见于新学期开学前），
    // 回退展示上一学期，避免假期里打开课表是一片空白。
    // 认证过期 / 身份失效时 result.requiresLogin 为真且不含快照，直接返回，
    // 不借上一学期缓存绕过隐私策略。
    //
    // 恢复预算：整次加载（当前学期 + 上一学期回退）至多一轮 guard/OCR。
    // 当前学期刷新已经用过 guard，因此回退**绝不**再经 `_loadSnapshotForContext`
    // 触发第二轮 guard/自动登录；回退只允许 owner + revision 核验过的本地缓存，
    // 或在缓存不可用时一次不带 guard 的原始查询，且明确失效时 fail closed。
    if (!autoResolveTerm ||
        result.requiresLogin ||
        (result.snapshot?.hasData ?? false)) {
      return result;
    }
    if (!_isIdentityCurrent(owner, settledRevision)) {
      return _identityChangedResult();
    }
    final previousContext = context.previous();
    final fallback = await _loadPreviousTermFallback(
      studentId: owner,
      context: previousContext,
      owner: owner,
      revision: settledRevision,
    );
    if (fallback.snapshot?.hasData != true) {
      return result;
    }
    final requiresLogin = result.requiresLogin || fallback.requiresLogin;
    return ScheduleLoadResult(
      snapshot: fallback.snapshot,
      requiresLogin: requiresLogin,
      usedCache: true,
      didRefresh: fallback.didRefresh,
      effectiveTermContext: previousContext,
      automaticLoginPaused:
          result.automaticLoginPaused || fallback.automaticLoginPaused,
      settledRevision: fallback.settledRevision ?? settledRevision,
      message: requiresLogin
          ? '当前学期暂无课表，已显示上一学期课表，刷新需要重新登录教务'
          : '当前学期暂无课表，已显示上一学期课表',
    );
  }

  /// 自动识别当前学期：优先以教务系统解析结果为准，失败时按日期推算。
  ///
  /// term GET 明确命中认证过期时不把登录页当正常空数据，仅沿日期兜底，
  /// 把**唯一一次**恢复/自动登录机会留给主课表 POST 的 guard。
  Future<({ScheduleTermContext context, bool identityChanged})>
  _resolveAutoTermContext({
    required String owner,
    required int revision,
  }) async {
    try {
      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: owner,
      );
      if (!_isIdentityCurrent(owner, revision)) {
        return (context: getCurrentTermContext(), identityChanged: true);
      }
      if (resolution.authExpired) {
        // 明确过期：只沿日期兜底，不把登录页解析成正常学期/空数据。
        return (context: getCurrentTermContext(), identityChanged: false);
      }
      if (resolution.context != null) {
        return (context: resolution.context!, identityChanged: false);
      }
    } catch (_) {
      // 解析失败时回退到日期推算。
    }
    if (!_isIdentityCurrent(owner, revision)) {
      return (context: getCurrentTermContext(), identityChanged: true);
    }
    return (context: getCurrentTermContext(), identityChanged: false);
  }

  Future<ScheduleLoadResult> _loadSnapshotForContext({
    required String studentId,
    required ScheduleTermContext context,
    required bool forceRefresh,
    required bool allowChangeRules,
    required String owner,
    required int revision,
  }) async {
    if (!_isIdentityCurrent(owner, revision) || owner != studentId) {
      return _identityChangedResult();
    }
    final cacheKey = _cacheKeyFor(studentId, context);
    var cachedSnapshot =
        _snapshots[cacheKey] ??
        ScheduleCacheSnapshot.empty(studentId: studentId, termContext: context);

    final shouldRefreshChangeRules =
        allowChangeRules &&
        (forceRefresh ||
            cachedSnapshot.needsChangeRulesRefresh(DateTime.now()));
    if (!forceRefresh && cachedSnapshot.hasData && !shouldRefreshChangeRules) {
      return ScheduleLoadResult(
        snapshot: _snapshotForDisplay(cachedSnapshot),
        usedCache: true,
      );
    }

    final shouldRefreshSchedule =
        forceRefresh || cachedSnapshot.needsScheduleRefresh(DateTime.now());
    final needsRefresh = shouldRefreshSchedule || shouldRefreshChangeRules;

    if (!needsRefresh) {
      return ScheduleLoadResult(
        snapshot: cachedSnapshot.hasData
            ? _snapshotForDisplay(cachedSnapshot)
            : null,
        usedCache: cachedSnapshot.hasData,
      );
    }

    // 只有当前已登录、且账号与请求一致时才刷新；否则不展示任何历史快照。
    final canRefresh =
        _isIdentityCurrent(owner, revision) && owner == studentId;
    if (!canRefresh) {
      return _identityChangedResult();
    }

    return _loadOrJoin(
      _inflightKeyFor(studentId, context, revision),
      () => _refreshSnapshot(
        existingSnapshot: cachedSnapshot,
        studentId: studentId,
        termContext: context,
        refreshSchedule: shouldRefreshSchedule,
        refreshChangeRules: shouldRefreshChangeRules,
        allowChangeRules: allowChangeRules,
        owner: owner,
        revision: revision,
      ),
    );
  }

  /// 上一学期回退：在「整次加载至多一轮 guard/OCR」的预算内取回退数据。
  ///
  /// 与 [_loadSnapshotForContext] 不同，本方法**绝不**经
  /// [AcademicAuthGuard.guardRequest]，因此不会触发第二次会话恢复 / 静默
  /// 自动登录（OCR）：
  /// - 优先使用经 owner + revision 核验、且展示态确有数据的本地缓存；
  /// - 缓存无数据时才做至多一次不带 guard 的原始查询；
  /// - 原始查询命中认证失效 / 身份变化一律 fail closed：不展示、不落盘、
  ///   也**不**二次 `markLoggedOut`（当前学期主 POST 的 guard 已处理终态）。
  Future<ScheduleLoadResult> _loadPreviousTermFallback({
    required String studentId,
    required ScheduleTermContext context,
    required String owner,
    required int revision,
  }) async {
    if (!_isIdentityCurrent(owner, revision) || owner != studentId) {
      return _identityChangedResult();
    }
    final cached = _snapshots[_cacheKeyFor(studentId, context)];
    if (cached != null) {
      final display = _snapshotForDisplay(cached);
      if (display.hasData) {
        return ScheduleLoadResult(
          snapshot: display,
          usedCache: true,
          settledRevision: revision,
        );
      }
    }

    try {
      final raw = await _rawSchedulePost(
        studentId: studentId,
        year: context.academicYear,
        term: context.term,
      );
      if (!_isIdentityCurrent(owner, revision) || owner != studentId) {
        return _identityChangedResult();
      }
      final courses = _parseScheduleCourses(raw);
      if (courses.isEmpty) {
        return const ScheduleLoadResult();
      }
      final snapshot = ScheduleCacheSnapshot(
        studentId: studentId,
        termContext: context,
        courses: courses,
        scheduleUpdatedAt: DateTime.now(),
      );
      final persisted = await _persistSnapshot(
        snapshot,
        owner: owner,
        revision: revision,
      );
      if (!persisted) return _identityChangedResult();
      return ScheduleLoadResult(
        snapshot: _snapshotForDisplay(snapshot),
        didRefresh: true,
        settledRevision: revision,
      );
    } on ScheduleAuthExpiredException {
      // 回退查询明确认证失效：fail closed，不展示、不落盘、不二次登出。
      return const ScheduleLoadResult();
    } on ScheduleRequestException catch (error) {
      return ScheduleLoadResult(
        message: error.message,
        settledRevision: revision,
      );
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      return ScheduleLoadResult(
        message: code == null ? '网络请求失败，请稍后重试' : '网络请求失败（状态码：$code）',
        settledRevision: revision,
      );
    } catch (_) {
      return const ScheduleLoadResult();
    }
  }

  /// 主课表查询 POST（当前学期课表）。
  ///
  /// 认证链路：请求经 [AcademicAuthGuard.guardRequest] 执行，guard 闭包每次
  /// 调用都按当前直连/WebVPN 模式重建 URL 与 Referer；guard 最多做一次会话
  /// 恢复 / 静默自动登录与一次内部重试，终态 `markLoggedOut` 由 guard 内部
  /// 完成，本方法不重复标记。manualRequired 的 `automaticLoginPaused` 会透传
  /// 到 [ScheduleAuthExpiredException]。
  ///
  /// 身份修订：guard 返回后若 [ZhengfangAuth.sessionRevision] 相比请求开始时
  /// 变化，则**不**盲收旧响应（无法证明该响应属于当前账号）。仅当当前账号仍
  /// 相同且 active 时，用一次不带 guard 的原始查询 POST 在新的 revision 下
  /// 重新获取并校验，以该响应解析。再次身份变化 / 认证失效即拒绝，不再做额外
  /// OCR、重试或重复副作用。
  ///
  /// 该额外 POST 仅用于本只读查询接口；服务端幂等性未在真实设备上证实。
  Future<List<CourseEntry>> fetchSchedule(
    String studentId,
    int year,
    int term,
  ) async {
    return (await _fetchScheduleForIdentity(studentId, year, term)).courses;
  }

  Future<({List<CourseEntry> courses, int revision})> _fetchScheduleForIdentity(
    String studentId,
    int year,
    int term,
  ) async {
    final identity = _currentIdentity();
    if (identity == null || identity.owner != studentId) {
      throw const ScheduleAuthExpiredException();
    }
    final startRevision = identity.revision;
    await DioClient.instance.ensureInitialized();
    if (!_isIdentityCurrent(studentId, startRevision)) {
      throw const ScheduleAuthExpiredException();
    }

    Response<dynamic> guarded;
    try {
      guarded = await _guardedSchedulePost(
        studentId: studentId,
        year: year,
        term: term,
      );
    } on AcademicAuthExpiredException catch (error) {
      // guard 的 manualRequired 以 AcademicAuthExpiredException 子类抛出，
      // 透传暂停语义；guard 内部终态已 markLoggedOut，此处不再标记。
      throw ScheduleAuthExpiredException(
        automaticLoginPaused: error.automaticLoginPaused,
      );
    }

    final afterGuard = _currentIdentity();
    if (afterGuard == null || afterGuard.owner != studentId) {
      throw const ScheduleAuthExpiredException();
    }
    if (afterGuard.revision == startRevision) {
      final courses = _parseScheduleCourses(guarded);
      return (courses: courses, revision: startRevision);
    }

    // revision 变化（guard 自动登录/恢复或同账号重登）：旧响应不可盲收。
    final retryRevision = afterGuard.revision;
    final raw = await _rawSchedulePost(
      studentId: studentId,
      year: year,
      term: term,
    );
    if (!_isIdentityCurrent(studentId, retryRevision)) {
      throw const ScheduleAuthExpiredException();
    }
    final courses = _parseScheduleCourses(raw);
    return (courses: courses, revision: retryRevision);
  }

  Future<Response<dynamic>> _guardedSchedulePost({
    required String studentId,
    required int year,
    required int term,
  }) {
    return AcademicAuthGuard.guardRequest<dynamic>(
      authExpiredException: const ScheduleAuthExpiredException(),
      request: () =>
          _postScheduleQuery(studentId: studentId, year: year, term: term),
    );
  }

  /// 不带 guard 的原始查询 POST，仅在 guard 后 revision 变化时用于有界再校验。
  Future<Response<dynamic>> _rawSchedulePost({
    required String studentId,
    required int year,
    required int term,
  }) {
    return _postScheduleQuery(studentId: studentId, year: year, term: term);
  }

  /// 每次调用都按当前模式重建 URL / Referer（guard 恢复可能切换直连/WebVPN）。
  Future<Response<dynamic>> _postScheduleQuery({
    required String studentId,
    required int year,
    required int term,
  }) {
    final referer = ZhengfangAuth.instance.buildPortalUrl(
      '/kbcx/xskbcx_cxXskbcxIndex.html',
      queryParameters: {
        'gnmkdm': 'N2151',
        'layout': 'default',
        'su': studentId,
      },
    );
    return _dio.post<dynamic>(
      _academicUrl('/kbcx/xskbcx_cxXsKb.html'),
      queryParameters: {'gnmkdm': 'N2151', 'su': studentId},
      data: 'xnm=$year&xqm=$term&kzlx=ck',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );
  }

  List<CourseEntry> _parseScheduleCourses(Response<dynamic> resp) {
    final statusCode = resp.statusCode ?? 0;
    if (AcademicAuthGuard.isAuthExpiredResponse(resp)) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('课表接口异常（状态码：$statusCode）');
    }

    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      final raw = data?.toString() ?? '';
      if (_looksLikeLoginExpired(raw)) {
        throw const ScheduleAuthExpiredException();
      }
      throw const ScheduleRequestException('课表返回数据格式异常');
    }

    final message = data['message']?.toString() ?? '';
    if (_looksLikeLoginExpired(message)) {
      throw const ScheduleAuthExpiredException();
    }

    final kbList = data['kbList'] as List<dynamic>? ?? [];
    return kbList
        .whereType<Map<String, dynamic>>()
        .map(CourseEntry.fromJson)
        .toList();
  }

  Future<List<CourseChangeRule>> fetchCourseChangeRules(
    String studentId, {
    required ScheduleTermContext termContext,
  }) async {
    // 两个消息源都没有学期参数；历史学期直接禁止访问无作用域消息。
    if (!_canFetchChangeRulesFor(termContext)) {
      return const [];
    }
    final identity = _currentIdentity();
    if (identity == null || identity.owner != studentId) {
      throw const ScheduleAuthExpiredException();
    }
    final revision = identity.revision;

    await DioClient.instance.ensureInitialized();
    if (!_isIdentityCurrent(studentId, revision)) {
      throw const ScheduleAuthExpiredException();
    }
    final messages = <ScheduleChangeMessage>[];
    messages.addAll(await _fetchInboxChangeMessages());
    // inbox 过期即停止：不再发 AreaThree（不再套 guard / OCR）。
    if (!_isIdentityCurrent(studentId, revision)) {
      throw const ScheduleAuthExpiredException();
    }

    final referer = ZhengfangAuth.instance.academicServiceUrl;
    final resp = await _dio.post<String>(
      _academicUrl('/xtgl/index_cxAreaThree.html'),
      queryParameters: {
        'localeKey': 'zh_CN',
        'gnmkdm': 'index',
        'su': studentId,
      },
      options: Options(
        responseType: ResponseType.plain,
        contentType: 'application/x-www-form-urlencoded;charset=UTF-8',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    if (!_isIdentityCurrent(studentId, revision)) {
      throw const ScheduleAuthExpiredException();
    }
    final statusCode = resp.statusCode ?? 0;
    if (AcademicAuthGuard.isAuthExpiredResponse(resp)) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('课表调停课接口异常（状态码：$statusCode）');
    }

    final html = resp.data ?? '';
    if (_looksLikeLoginExpired(html)) {
      throw const ScheduleAuthExpiredException();
    }

    messages.addAll(extractScheduleChangeMessageEntriesFromAreaThreeHtml(html));
    return parseScheduleChangeMessageEntries(messages);
  }

  Future<List<ScheduleChangeMessage>> _fetchInboxChangeMessages() async {
    await DioClient.instance.ensureInitialized();
    final resp = await _dio.post<dynamic>(
      _academicUrl('/xtgl/index_cxDbsy.html'),
      queryParameters: {'flag': '1'},
      options: Options(
        validateStatus: (status) => status != null && status < 1000,
        headers: {
          'Referer': ZhengfangAuth.instance.academicServiceUrl,
          'X-Requested-With': 'XMLHttpRequest',
        },
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (AcademicAuthGuard.isAuthExpiredResponse(resp)) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('教学消息接口异常（状态码：$statusCode）');
    }

    final data = resp.data;
    if (data is String) {
      return extractScheduleChangeMessageEntriesFromAreaThreeHtml(data);
    }
    if (data is! Map<String, dynamic>) {
      final raw = data?.toString() ?? '';
      if (_looksLikeLoginExpired(raw)) {
        throw const ScheduleAuthExpiredException();
      }
      return const [];
    }

    final items = data['items'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(
          (item) =>
              item['TKXX']?.toString() ??
              item['XXNR']?.toString() ??
              item['XXBT']?.toString() ??
              '',
        )
        .map((message) => _decodeHtmlEntities(message).trim())
        .where((message) => message.isNotEmpty)
        .map((message) => ScheduleChangeMessage(message: message))
        .toList();
  }

  List<CourseEntry> buildEffectiveWeekCourses({
    required List<CourseEntry> courses,
    required int week,
    List<CourseChangeRule> changeRules = const [],
    ScheduleTermContext? termContext,
  }) {
    final applicableRules = changeRules.where(
      (rule) =>
          rule.termContext != null &&
          (termContext == null || rule.termContext == termContext) &&
          !_isProtectedByAuthoritativeCourse(rule, courses),
    );
    final effectiveCourses = courses
        .where((course) => course.isInWeek(week))
        .where(
          (course) =>
              !applicableRules.any((rule) => rule.removesCourse(course, week)),
        )
        .toList();

    for (final rule in applicableRules.where(
      (rule) => rule.addsCourseToWeek(week),
    )) {
      final syntheticCourse = _buildSyntheticCourse(
        rule: rule,
        week: week,
        courses: courses,
      );
      if (syntheticCourse != null) {
        effectiveCourses.add(syntheticCourse);
      }
    }

    final deduped = <CourseEntry>[];
    final seen = <String>{};
    for (final course in effectiveCourses) {
      final signature = [
        course.courseName,
        course.teacherName,
        course.weekday,
        course.startLesson,
        course.endLesson,
        course.classroom,
        course.weekRange,
      ].join('|');
      if (seen.add(signature)) {
        deduped.add(course);
      }
    }

    return deduped;
  }

  /// 将按周解析出的规则按原文合并，供通知列表展示。
  List<CourseChangeNotice> buildCourseChangeNotices({
    required List<CourseEntry> courses,
    required List<CourseChangeRule> changeRules,
    required ScheduleTermContext termContext,
    DateTime? now,
  }) {
    final grouped = <String, List<CourseChangeRule>>{};
    for (final rule in changeRules) {
      if (!_isVisibleCourseChangeRule(
        rule,
        termContext,
        now ?? DateTime.now(),
      )) {
        continue;
      }
      grouped.putIfAbsent(rule.noticeSignature, () => []).add(rule);
    }

    return [
      for (final rules in grouped.values)
        _buildCourseChangeNotice(rules, courses),
    ];
  }

  bool _isVisibleCourseChangeRule(
    CourseChangeRule rule,
    ScheduleTermContext termContext,
    DateTime now,
  ) {
    // A message's explicit term always outranks its publication date.
    if (rule.termContext != null) return rule.termContext == termContext;

    final publishedAt = rule.publishedAt;
    if (publishedAt == null) return true;

    final currentTerm =
        CurrentTermResolver.instance.knownCurrentTerm ??
        getCurrentTermContext(now);
    // Do not use today's date to censor notices while viewing a history term.
    if (termContext != currentTerm) return true;

    final configuredStart = _normalizeDate(
      SemesterCalendar.instance.semesterStartDate.value,
    );
    // ScheduleTermContext.current is a month-based heuristic only.  It is used
    // here to reject an unrelated global calendar setting, never as term proof.
    if (ScheduleTermContext.current(configuredStart) != termContext) {
      return true;
    }

    final semesterStart = configuredStart;
    final earliestVisible = semesterStart.subtract(
      _notificationPreSemesterWindow,
    );
    return !_normalizeDate(publishedAt).isBefore(earliestVisible);
  }

  static DateTime _normalizeDate(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  CourseChangeNotice _buildCourseChangeNotice(
    List<CourseChangeRule> rules,
    List<CourseEntry> courses,
  ) {
    if (rules.isNotEmpty &&
        rules.every((rule) => _findReflectedCourse(rule, courses) != null)) {
      return CourseChangeNotice(
        rule: rules.first,
        status: CourseChangeNoticeStatus.reflected,
        effectiveCourse: _findReflectedCourse(rules.first, courses),
      );
    }
    return CourseChangeNotice(
      rule: rules.first,
      status: CourseChangeNoticeStatus.unapplied,
    );
  }

  CourseEntry? _findReflectedCourse(
    CourseChangeRule rule,
    List<CourseEntry> courses,
  ) {
    final lesson = rule.targetLesson ?? rule.originalLesson;
    if (lesson == null) return null;

    for (final course in courses) {
      if (!course.hasScheduleChange ||
          course.weekday != lesson.weekday ||
          course.startLesson != lesson.startLesson ||
          course.endLesson != lesson.endLesson) {
        continue;
      }
      if (!course.isInWeek(lesson.week)) continue;
      if (!_matchesCourseName(course.courseName, rule.courseName ?? '')) {
        continue;
      }
      final teacher = rule.teacherName?.trim() ?? '';
      if (teacher.isEmpty || course.teacherName.trim() != teacher) {
        continue;
      }
      final classroom = rule.classroom?.trim() ?? '';
      if (classroom.isEmpty || course.classroom.trim() != classroom) {
        continue;
      }
      return course;
    }
    return null;
  }

  bool _isProtectedByAuthoritativeCourse(
    CourseChangeRule rule,
    List<CourseEntry> courses,
  ) {
    final lesson = rule.targetLesson ?? rule.originalLesson;
    if (lesson == null) return false;

    // 即使通知只覆盖了部分节次，权威课表的调课标记也不能被通知反向覆盖。
    for (final course in courses) {
      if (!course.hasScheduleChange || !course.isInWeek(lesson.week)) {
        continue;
      }
      if (course.weekday != lesson.weekday ||
          !lesson.overlaps(course) ||
          !_matchesCourseName(course.courseName, rule.courseName ?? '')) {
        continue;
      }
      final teacher = rule.teacherName?.trim() ?? '';
      if (teacher.isEmpty || course.teacherName.trim() == teacher) return true;
    }
    return false;
  }

  CourseEntry? _buildSyntheticCourse({
    required CourseChangeRule rule,
    required int week,
    required List<CourseEntry> courses,
  }) {
    final targetLesson = rule.targetLesson;
    if (targetLesson == null || targetLesson.week != week) return null;

    final template = _findTemplateCourse(rule, courses);
    final courseName = (rule.courseName?.trim().isNotEmpty ?? false)
        ? rule.courseName!.trim()
        : template?.courseName ?? '调课课程';
    final teacherName = (rule.teacherName?.trim().isNotEmpty ?? false)
        ? rule.teacherName!.trim()
        : template?.teacherName ?? '';
    final classroom = (rule.classroom?.trim().isNotEmpty ?? false)
        ? rule.classroom!.trim()
        : template?.classroom ?? '';

    return CourseEntry(
      courseName: courseName,
      teacherName: teacherName,
      weekday: targetLesson.weekday,
      startLesson: targetLesson.startLesson,
      endLesson: targetLesson.endLesson,
      weekRange: '$week周',
      classroom: classroom,
      campus: template?.campus ?? '',
      typeSymbol: template?.typeSymbol ?? '',
    );
  }

  CourseEntry? _findTemplateCourse(
    CourseChangeRule rule,
    List<CourseEntry> courses,
  ) {
    final lesson = rule.originalLesson;
    final ruleCourseName = rule.courseName?.trim() ?? '';

    if (lesson != null) {
      for (final course in courses) {
        if (!course.isInWeek(lesson.week) || !lesson.overlaps(course)) {
          continue;
        }
        if (ruleCourseName.isEmpty ||
            _matchesCourseName(course.courseName, ruleCourseName)) {
          return course;
        }
      }
    }

    if (ruleCourseName.isNotEmpty) {
      for (final course in courses) {
        if (_matchesCourseName(course.courseName, ruleCourseName)) {
          return course;
        }
      }
    }

    return null;
  }

  @visibleForTesting
  Future<void> debugClearCache() async {
    await _ensureRestored();
    _snapshots.clear();
    _restored = true;
    // 测试隔离：丢弃上一条用例可能遗留的写入链，避免被阻塞的写入把后续用例
    // 永久排队。仅测试入口调用；生产路径不重置。
    _persistWriteChain = Future<void>.value();
    await _prefs?.remove(_cacheStorageKey);
  }

  /// 测试注入：在整 map 写入落盘前调用，便于可控阻塞 / 失败注入。
  /// 仅用于测试；null 时走真实 `SharedPreferences`。
  @visibleForTesting
  static Future<void> Function()? debugBeforePersistWrite;

  /// 测试入口：直接驱动在途请求登记 / 清理逻辑（[_loadOrJoin]）。
  @visibleForTesting
  Future<ScheduleLoadResult> debugLoadOrJoin(
    String key,
    Future<ScheduleLoadResult> Function() loader,
  ) => _loadOrJoin(key, loader);

  @visibleForTesting
  void debugSetSnapshot(ScheduleCacheSnapshot snapshot) {
    _snapshots[_cacheKeyFor(snapshot.studentId, snapshot.termContext)] =
        snapshot;
    _restored = true;
  }

  Future<void> _ensureRestored() async {
    if (_restored) return;
    await restoreCache();
  }

  Future<ScheduleLoadResult> _loadOrJoin(
    String key,
    Future<ScheduleLoadResult> Function() loader,
  ) {
    final existing = _inflightLoads[key];
    if (existing != null) return existing;

    final future = loader();
    _inflightLoads[key] = future;
    // 清理必须同时监听成功与失败：只监听成功（或 `whenComplete` 返回一个无人
    // 监听的 Future）会在 loader 抛异常时留下未处理的 Future 异常。这里用带
    // onError 的 `then` 吞掉清理分支的异常，保证既不 unhandled，又总能清理登记。
    future.then<void>(
      (_) {
        // 只清理本次登记的 future，绝不删除随后登记的新 future。
        if (identical(_inflightLoads[key], future)) {
          _inflightLoads.remove(key);
        }
      },
      onError: (Object _) {
        if (identical(_inflightLoads[key], future)) {
          _inflightLoads.remove(key);
        }
      },
    );
    return future;
  }

  Future<ScheduleLoadResult> _refreshSnapshot({
    required ScheduleCacheSnapshot existingSnapshot,
    required String studentId,
    required ScheduleTermContext termContext,
    required bool refreshSchedule,
    required bool refreshChangeRules,
    required bool allowChangeRules,
    required String owner,
    required int revision,
  }) async {
    if (!_isIdentityCurrent(owner, revision) || owner != studentId) {
      return _identityChangedResult();
    }

    var nextSnapshot = existingSnapshot;
    var didRefresh = false;
    // 后续请求使用的期望 revision；guard 自动登录成功后会被刷新为 settled 值。
    var expectedRevision = revision;
    final warnings = <String>[];

    /// guard 恢复 / 自动登录可能已推进 revision 但随后请求失败；失败分支必须
    /// 先把 expectedRevision 与当前身份对齐，否则合法恢复会被误判为身份变化。
    /// 仅在同一 owner 且 revision 前进时对齐，绝不接受切号或回退。
    bool ownerStillCurrent() {
      final current = _currentIdentity();
      if (current != null &&
          current.owner == owner &&
          current.revision > expectedRevision) {
        expectedRevision = current.revision;
      }
      return _isIdentityCurrent(owner, expectedRevision);
    }

    if (refreshSchedule) {
      try {
        final settled = await _fetchScheduleForIdentity(
          studentId,
          termContext.academicYear,
          termContext.term,
        );
        if (!_isIdentityCurrent(owner, settled.revision) ||
            owner != studentId) {
          return _identityChangedResult();
        }
        expectedRevision = settled.revision;
        nextSnapshot = nextSnapshot.copyWith(
          courses: settled.courses,
          scheduleUpdatedAt: DateTime.now(),
        );
        didRefresh = true;
      } on ScheduleAuthExpiredException catch (error) {
        // guard 内部终态已 markLoggedOut；此处不得二次标记，也绝不登出新账号。
        // 认证过期无法安全区分主动退出与安全 owner，保守隐藏旧课表。
        return ScheduleLoadResult(
          requiresLogin: true,
          automaticLoginPaused: error.automaticLoginPaused,
          message: '教务登录已过期，请重新登录',
        );
      } on ScheduleRequestException catch (error) {
        if (!ownerStillCurrent()) {
          return _identityChangedResult();
        }
        if (!existingSnapshot.hasData) {
          return ScheduleLoadResult(
            message: error.message,
            settledRevision: expectedRevision,
          );
        }
        warnings.add('课表刷新失败，显示的是缓存数据');
      } on DioException catch (error) {
        if (!ownerStillCurrent()) {
          return _identityChangedResult();
        }
        if (!existingSnapshot.hasData) {
          final code = error.response?.statusCode;
          return ScheduleLoadResult(
            message: code == null ? '网络请求失败，请稍后重试' : '网络请求失败（状态码：$code）',
            settledRevision: expectedRevision,
          );
        }
        warnings.add('课表刷新失败，显示的是缓存数据');
      } catch (_) {
        if (!ownerStillCurrent()) {
          return _identityChangedResult();
        }
        if (!existingSnapshot.hasData) {
          return ScheduleLoadResult(
            message: '获取课表失败，请稍后重试',
            settledRevision: expectedRevision,
          );
        }
        warnings.add('课表刷新失败，显示的是缓存数据');
      }
    }

    final shouldLoadChangeRules =
        allowChangeRules &&
        refreshChangeRules &&
        nextSnapshot.courses.isNotEmpty;
    if (shouldLoadChangeRules) {
      // 调课链路不走 guard。固定它自己的身份与持久 epoch；主课表 guard
      // 可能已合法恢复并推进 revision，但调课开始后再发生的同账号重登
      // 不能被旧 inbox/AreaThree 的失效响应追认为新会话过期。
      final rulesRevision = expectedRevision;
      final rulesEpoch = await ZhengfangAuth.instance
          .durableAcademicEpochOrUnknown();
      if (!_isIdentityCurrent(owner, rulesRevision)) {
        return _identityChangedResult();
      }
      try {
        final fetchedRules = await fetchCourseChangeRules(
          studentId,
          termContext: termContext,
        );
        if (!_isIdentityCurrent(owner, expectedRevision) ||
            owner != studentId) {
          return _identityChangedResult();
        }
        nextSnapshot = nextSnapshot.copyWith(
          changeRules: fetchedRules,
          changeRulesUpdatedAt: DateTime.now(),
          changeRulesCurrentScoped: true,
          changeRulesDateAware: true,
        );
        final notices = buildCourseChangeNotices(
          courses: nextSnapshot.courses,
          changeRules: fetchedRules,
          termContext: termContext,
        );
        final unappliedCount = notices
            .where((notice) => notice.isUnapplied)
            .length;
        if (unappliedCount > 0) {
          warnings.add('有$unappliedCount条调课提醒未在当前课表体现');
        }
        didRefresh = true;
      } on ScheduleAuthExpiredException catch (error) {
        if (!_isIdentityCurrent(owner, rulesRevision)) {
          return _identityChangedResult();
        }
        // 仅本次调课发起时的身份/持久 epoch 可被条件撤销。期间同账号
        // 重登、换号或新 epoch 提交都不得被旧请求踢掉。
        await ZhengfangAuth.instance.revokeExpiredSessionIfCurrent(
          revision: rulesRevision,
          account: owner,
          expectedEpoch: rulesEpoch,
        );
        return ScheduleLoadResult(
          requiresLogin: true,
          automaticLoginPaused: error.automaticLoginPaused,
          message: '教务登录已过期，请重新登录',
        );
      } on ScheduleRequestException {
        warnings.add('调课提醒刷新失败，继续使用缓存');
      } on DioException {
        warnings.add('调课提醒刷新失败，继续使用缓存');
      } catch (_) {
        warnings.add('调课提醒刷新失败，继续使用缓存');
      }
    }

    if (!_isIdentityCurrent(owner, expectedRevision) || owner != studentId) {
      return _identityChangedResult();
    }
    if (didRefresh) {
      final persisted = await _persistSnapshot(
        nextSnapshot,
        owner: owner,
        revision: expectedRevision,
      );
      if (!persisted) return _identityChangedResult();
    }

    final visibleNextSnapshot = _snapshotForDisplay(nextSnapshot);
    final visibleExistingSnapshot = _snapshotForDisplay(existingSnapshot);
    final snapshot = visibleNextSnapshot.hasData
        ? visibleNextSnapshot
        : (visibleExistingSnapshot.hasData ? visibleExistingSnapshot : null);
    return ScheduleLoadResult(
      snapshot: snapshot,
      message: warnings.isEmpty ? null : warnings.join('，'),
      usedCache: existingSnapshot.hasData,
      didRefresh: didRefresh,
      settledRevision: expectedRevision,
    );
  }

  /// 身份 / 账号不一致时的统一结果：不展示任何历史快照、零副作用。
  ScheduleLoadResult _identityChangedResult() {
    return const ScheduleLoadResult(
      requiresLogin: true,
      message: '登录状态已变化，请重新登录',
    );
  }

  /// 落盘前复核身份：owner / revision 任一变化即拒绝写入。
  ///
  /// 同一 isolate 内对同一 storage key 的**整 map** 写入必须串行化：缓存是
  /// 单个 JSON 字符串，若两次 read-modify-write 交叠，先发起者的旧整 map 可能
  /// 晚于后来者的写落盘并覆盖新账号数据。这里用 [_persistWriteChain] 把写入
  /// 排队，且在真正提交前于临界区内重新编码当前 map，避免使用陈旧 encoded。
  ///
  /// 边界：仅保证**同 isolate** 的写入顺序；持久层是单个字符串，不保证跨
  /// isolate 原子写，也不宣称跨 isolate 即时一致。
  Future<bool> _persistSnapshot(
    ScheduleCacheSnapshot snapshot, {
    required String owner,
    required int revision,
  }) {
    final task = _persistWriteChain.then(
      (_) => _persistSnapshotSerialized(
        snapshot,
        owner: owner,
        revision: revision,
      ),
    );
    // 链本身必须始终以成功收尾：单次写入失败（含异常）不得永久阻塞后续写入，
    // 也不得产生未处理异常。
    _persistWriteChain = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<bool> _persistSnapshotSerialized(
    ScheduleCacheSnapshot snapshot, {
    required String owner,
    required int revision,
  }) async {
    if (!_isIdentityCurrent(owner, revision) || snapshot.studentId != owner) {
      return false;
    }
    await _ensureRestored();
    if (!_isIdentityCurrent(owner, revision) || snapshot.studentId != owner) {
      return false;
    }
    final cacheKey = _cacheKeyFor(snapshot.studentId, snapshot.termContext);
    final previous = _snapshots[cacheKey];
    void rollbackMemoryWrite() {
      if (previous == null) {
        _snapshots.remove(cacheKey);
      } else {
        _snapshots[cacheKey] = previous;
      }
    }

    _snapshots[cacheKey] = snapshot;
    // 在当前临界区内基于最新 map 重新编码，绝不复用临界区外的陈旧 encoded。
    final encoded = jsonEncode(
      _snapshots.map((key, value) => MapEntry(key, value.toJson())),
    );
    if (!_isIdentityCurrent(owner, revision)) {
      // 身份在提交边界已变化：回滚本次内存写入并拒绝提交。
      rollbackMemoryWrite();
      return false;
    }
    final write = debugBeforePersistWrite;
    if (write != null) {
      await write();
      // 阻塞期间身份可能已变化：实际落盘前再复核一次，绝不把旧 map 写入。
      if (!_isIdentityCurrent(owner, revision)) {
        rollbackMemoryWrite();
        return false;
      }
    }
    await _prefs?.setString(_cacheStorageKey, encoded);
    // await 之后复核：期间切号 / 同账号重登 / 登出则拒绝返回旧可见状态。
    if (!_isIdentityCurrent(owner, revision) || snapshot.studentId != owner) {
      return false;
    }
    return true;
  }

  /// 当前已登录教务身份（active + 非空账号）；未登录 / 空白账号返回 null。
  ({String owner, int revision})? _currentIdentity() {
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) return null;
    final owner = auth.currentStudentId?.trim();
    if (owner == null || owner.isEmpty) return null;
    return (owner: owner, revision: auth.sessionRevision);
  }

  bool _isIdentityCurrent(String owner, int revision) {
    final current = _currentIdentity();
    return current != null &&
        current.owner == owner &&
        current.revision == revision;
  }

  String? _resolveStudentId([String? studentId]) {
    final identity = _currentIdentity();
    if (identity == null) return null;
    final explicit = studentId?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      // 显式学号必须与当前登录账号一致，绝不回退到其它账号的历史缓存。
      return explicit == identity.owner ? explicit : null;
    }
    return identity.owner;
  }

  String _cacheKeyFor(String studentId, ScheduleTermContext termContext) {
    return '$studentId|${termContext.academicYear}|${termContext.term}';
  }

  /// 在途请求键：额外绑定 revision，同账号重登（revision 变化）也不 join。
  String _inflightKeyFor(
    String studentId,
    ScheduleTermContext termContext,
    int revision,
  ) {
    return '${_cacheKeyFor(studentId, termContext)}|r$revision';
  }

  bool _canFetchChangeRulesFor(ScheduleTermContext context) {
    final current =
        CurrentTermResolver.instance.knownCurrentTerm ??
        getCurrentTermContext();
    return context == current;
  }

  ScheduleCacheSnapshot _snapshotForDisplay(ScheduleCacheSnapshot snapshot) {
    final scopedRules = snapshot.changeRules
        .where(
          (rule) =>
              rule.termContext == null ||
              rule.termContext == snapshot.termContext,
        )
        .toList();
    if (scopedRules.length == snapshot.changeRules.length &&
        (scopedRules.isNotEmpty || snapshot.changeRulesUpdatedAt == null)) {
      return snapshot;
    }
    return snapshot.copyWith(
      changeRules: scopedRules,
      clearChangeRulesUpdatedAt: scopedRules.isEmpty,
    );
  }
}
