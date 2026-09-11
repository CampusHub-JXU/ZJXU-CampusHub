import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

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
  const ScheduleAuthExpiredException() : super('登录状态已过期，请重新登录');
}

class ScheduleLoadResult {
  const ScheduleLoadResult({
    this.snapshot,
    this.message,
    this.requiresLogin = false,
    this.usedCache = false,
    this.didRefresh = false,
    this.effectiveTermContext,
  });

  final ScheduleCacheSnapshot? snapshot;
  final String? message;
  final bool requiresLogin;
  final bool usedCache;
  final bool didRefresh;

  /// 自动识别发生学期回退时，实际展示课表的学期上下文；
  /// null 表示与请求时的学期一致。
  final ScheduleTermContext? effectiveTermContext;

  bool get hasData => snapshot?.hasData ?? false;
}

class ScheduleService {
  ScheduleService._();

  static final ScheduleService instance = ScheduleService._();

  static const _cacheStorageKey = 'zjxu_schedule_cache_snapshots_v1';
  static const _lastStudentStorageKey = 'zjxu_schedule_last_student_id_v1';
  // Keep a conservative pre-semester window so advance notices are not hidden.
  // This affects display only; it does not prove a message's term or alter courses.
  static const _notificationPreSemesterWindow = Duration(days: 60);

  final Map<String, ScheduleCacheSnapshot> _snapshots = {};
  final Map<String, Future<ScheduleLoadResult>> _inflightLoads = {};

  SharedPreferences? _prefs;
  bool _restored = false;
  String? _lastStudentId;

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

    _lastStudentId =
        _prefs!.getString(_lastStudentStorageKey) ?? _deriveLastStudentId();
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

    final resolvedStudentId = _resolveStudentId(studentId);
    if (resolvedStudentId == null || resolvedStudentId.isEmpty) {
      return const ScheduleLoadResult(requiresLogin: true, message: '请先登录教务系统');
    }

    final autoResolveTerm = termContext == null;
    final context =
        termContext ?? await _resolveAutoTermContext(resolvedStudentId);
    final result = await _loadSnapshotForContext(
      studentId: resolvedStudentId,
      context: context,
      forceRefresh: forceRefresh,
      allowChangeRules: _canFetchChangeRulesFor(context),
    );
    if (result.didRefresh) {
      CampusDataChangeBus.instance.notifyChanged();
    }

    // 未显式指定学期且当前学期没有课表数据（常见于新学期开学前），
    // 回退展示上一学期，避免假期里打开课表是一片空白。
    if (!autoResolveTerm || (result.snapshot?.hasData ?? false)) {
      return result;
    }
    final previousContext = context.previous();
    final fallback = await _loadSnapshotForContext(
      studentId: resolvedStudentId,
      context: previousContext,
      forceRefresh: false,
      allowChangeRules: false,
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
      message: requiresLogin
          ? '当前学期暂无课表，已显示上一学期课表，刷新需要重新登录教务'
          : '当前学期暂无课表，已显示上一学期课表',
    );
  }

  /// 自动识别当前学期：优先以教务系统解析结果为准，失败时按日期推算。
  Future<ScheduleTermContext> _resolveAutoTermContext(String studentId) async {
    try {
      final resolved = await CurrentTermResolver.instance.resolve(
        studentId: studentId,
      );
      if (resolved != null) return resolved;
    } catch (_) {
      // 解析失败时回退到日期推算。
    }
    return getCurrentTermContext();
  }

  Future<ScheduleLoadResult> _loadSnapshotForContext({
    required String studentId,
    required ScheduleTermContext context,
    required bool forceRefresh,
    required bool allowChangeRules,
  }) async {
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

    final canRefresh =
        ZhengfangAuth.instance.isLoggedIn &&
        ZhengfangAuth.instance.currentStudentId == studentId;
    if (!canRefresh) {
      if (cachedSnapshot.hasData) {
        return ScheduleLoadResult(
          snapshot: _snapshotForDisplay(cachedSnapshot),
          requiresLogin: true,
          usedCache: true,
          message: '显示的是本地缓存课表，刷新需要重新登录教务',
        );
      }
      return const ScheduleLoadResult(requiresLogin: true, message: '请先登录教务系统');
    }

    return _loadOrJoin(
      cacheKey,
      () => _refreshSnapshot(
        existingSnapshot: cachedSnapshot,
        studentId: studentId,
        termContext: context,
        refreshSchedule: shouldRefreshSchedule,
        refreshChangeRules: shouldRefreshChangeRules,
        allowChangeRules: allowChangeRules,
      ),
    );
  }

  Future<List<CourseEntry>> fetchSchedule(
    String studentId,
    int year,
    int term,
  ) async {
    await DioClient.instance.ensureInitialized();
    final referer = ZhengfangAuth.instance.buildPortalUrl(
      '/kbcx/xskbcx_cxXskbcxIndex.html',
      queryParameters: {
        'gnmkdm': 'N2151',
        'layout': 'default',
        'su': studentId,
      },
    );

    final resp = await _dio.post<dynamic>(
      _academicUrl('/kbcx/xskbcx_cxXsKb.html'),
      queryParameters: {'gnmkdm': 'N2151', 'su': studentId},
      data: 'xnm=$year&xqm=$term&kzlx=ck',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
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

    await DioClient.instance.ensureInitialized();
    final messages = <ScheduleChangeMessage>[];
    messages.addAll(await _fetchInboxChangeMessages());

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

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
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
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
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
    _lastStudentId = null;
    _restored = true;
    await _prefs?.remove(_cacheStorageKey);
    await _prefs?.remove(_lastStudentStorageKey);
  }

  @visibleForTesting
  void debugSetSnapshot(ScheduleCacheSnapshot snapshot) {
    _snapshots[_cacheKeyFor(snapshot.studentId, snapshot.termContext)] =
        snapshot;
    _lastStudentId = snapshot.studentId;
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
    future.whenComplete(() => _inflightLoads.remove(key));
    return future;
  }

  Future<ScheduleLoadResult> _refreshSnapshot({
    required ScheduleCacheSnapshot existingSnapshot,
    required String studentId,
    required ScheduleTermContext termContext,
    required bool refreshSchedule,
    required bool refreshChangeRules,
    required bool allowChangeRules,
  }) async {
    var nextSnapshot = existingSnapshot;
    var didRefresh = false;
    final warnings = <String>[];

    if (refreshSchedule) {
      try {
        final courses = await fetchSchedule(
          studentId,
          termContext.academicYear,
          termContext.term,
        );
        nextSnapshot = nextSnapshot.copyWith(
          courses: courses,
          scheduleUpdatedAt: DateTime.now(),
        );
        didRefresh = true;
      } on ScheduleAuthExpiredException {
        await ZhengfangAuth.instance.markLoggedOut();
        return _buildAuthExpiredResult(existingSnapshot, nextSnapshot);
      } on ScheduleRequestException catch (error) {
        if (!existingSnapshot.hasData) {
          return ScheduleLoadResult(message: error.message);
        }
        warnings.add('课表刷新失败，显示的是缓存数据');
      } on DioException catch (error) {
        if (!existingSnapshot.hasData) {
          final code = error.response?.statusCode;
          return ScheduleLoadResult(
            message: code == null ? '网络请求失败，请稍后重试' : '网络请求失败（状态码：$code）',
          );
        }
        warnings.add('课表刷新失败，显示的是缓存数据');
      } catch (_) {
        if (!existingSnapshot.hasData) {
          return const ScheduleLoadResult(message: '获取课表失败，请稍后重试');
        }
        warnings.add('课表刷新失败，显示的是缓存数据');
      }
    }

    final shouldLoadChangeRules =
        allowChangeRules &&
        refreshChangeRules &&
        nextSnapshot.courses.isNotEmpty;
    if (shouldLoadChangeRules) {
      try {
        final fetchedRules = await fetchCourseChangeRules(
          studentId,
          termContext: termContext,
        );
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
      } on ScheduleAuthExpiredException {
        await ZhengfangAuth.instance.markLoggedOut();
        if (didRefresh) {
          await _persistSnapshot(nextSnapshot);
        }
        return ScheduleLoadResult(
          snapshot: nextSnapshot.hasData
              ? _snapshotForDisplay(nextSnapshot)
              : _snapshotForDisplay(existingSnapshot),
          requiresLogin: true,
          usedCache: (nextSnapshot.hasData || existingSnapshot.hasData),
          didRefresh: didRefresh,
          message: '教务登录已过期，调课提醒继续使用缓存',
        );
      } on ScheduleRequestException {
        warnings.add('调课提醒刷新失败，继续使用缓存');
      } on DioException {
        warnings.add('调课提醒刷新失败，继续使用缓存');
      } catch (_) {
        warnings.add('调课提醒刷新失败，继续使用缓存');
      }
    }

    if (didRefresh) {
      await _persistSnapshot(nextSnapshot);
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
    );
  }

  ScheduleLoadResult _buildAuthExpiredResult(
    ScheduleCacheSnapshot existingSnapshot,
    ScheduleCacheSnapshot updatedSnapshot,
  ) {
    final visibleUpdatedSnapshot = _snapshotForDisplay(updatedSnapshot);
    final visibleExistingSnapshot = _snapshotForDisplay(existingSnapshot);
    final snapshot = visibleUpdatedSnapshot.hasData
        ? visibleUpdatedSnapshot
        : (visibleExistingSnapshot.hasData ? visibleExistingSnapshot : null);

    if (snapshot != null) {
      return ScheduleLoadResult(
        snapshot: snapshot,
        requiresLogin: true,
        usedCache: true,
        message: '教务登录已过期，显示的是本地缓存课表',
      );
    }

    return const ScheduleLoadResult(
      requiresLogin: true,
      message: '教务登录已过期，请重新登录',
    );
  }

  Future<void> _persistSnapshot(ScheduleCacheSnapshot snapshot) async {
    await _ensureRestored();
    _snapshots[_cacheKeyFor(snapshot.studentId, snapshot.termContext)] =
        snapshot;
    _lastStudentId = snapshot.studentId;

    final encoded = jsonEncode(
      _snapshots.map((key, value) => MapEntry(key, value.toJson())),
    );
    await _prefs?.setString(_cacheStorageKey, encoded);
    await _prefs?.setString(_lastStudentStorageKey, snapshot.studentId);
  }

  String? _resolveStudentId([String? studentId]) {
    final explicit = studentId?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final current = ZhengfangAuth.instance.currentStudentId?.trim();
    if (current != null && current.isNotEmpty) return current;

    final cached = _lastStudentId?.trim();
    if (cached != null && cached.isNotEmpty) return cached;

    return null;
  }

  String _cacheKeyFor(String studentId, ScheduleTermContext termContext) {
    return '$studentId|${termContext.academicYear}|${termContext.term}';
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

  String? _deriveLastStudentId() {
    final snapshots = _snapshots.values.toList()
      ..sort((left, right) {
        final leftAt = left.lastUpdatedAt?.millisecondsSinceEpoch ?? 0;
        final rightAt = right.lastUpdatedAt?.millisecondsSinceEpoch ?? 0;
        return rightAt.compareTo(leftAt);
      });
    return snapshots.isEmpty ? null : snapshots.first.studentId;
  }
}
