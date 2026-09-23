import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/academic_auth_guard.dart';
import '../auth/zhengfang_auth.dart';
import '../logging/app_logger.dart';
import '../network/dio_client.dart';
import 'schedule_term_context.dart';

/// [CurrentTermResolver.resolveWithStatus] 的解析结果。
///
/// [context] 是识别出的当前学年学期；[authExpired] 明确表示教务登录态失效
/// （901 / 302 / 303 / 401 / 403 或返回正方登录页）。两者互斥：认证过期时
/// [context] 必为 null；未登录、身份不符或非认证失败时 [authExpired] 为
/// false。
class CurrentTermResolution {
  const CurrentTermResolution({this.context, this.authExpired = false});

  /// 识别出的当前学期；null 表示未识别。
  final ScheduleTermContext? context;

  /// 是否明确命中教务登录态失效。
  final bool authExpired;
}

/// 从教务系统解析真实的当前学年学期。
///
/// 课表查询首页 `/kbcx/xskbcx_cxXskbcxIndex.html` 的 `#xnm` / `#xqm`
/// 下拉框中带 `selected` 的选项，即教务系统认定的当前学年学期。
/// 解析失败（未登录、网络异常、页面结构变化）时返回 null，
/// 由调用方回退到 [ScheduleTermContext.current] 的日期推算。
///
/// 缓存与请求绑定「当前已登录教务账号（owner）+ 身份修订号
/// [ZhengfangAuth.sessionRevision]」：显式传入的 `studentId` 必须与当前
/// 已登录账号一致才允许复用缓存或发起请求；登出 / 切账号后旧 owner 的
/// 内存与持久缓存一律不可见，await 边界之后身份变化的迟到响应既不落盘
/// 也不返回。持久 envelope 只做 owner 归属校验（进程内 revision 不跨
/// 进程持久化），不宣称跨 isolate 的即时一致。
class CurrentTermResolver {
  CurrentTermResolver._();

  static final CurrentTermResolver instance = CurrentTermResolver._();

  static const _storageKey = 'zjxu_current_term_context_v1';
  static const _cacheTtl = Duration(hours: 12);

  /// 学期代码只接受正方约定值：3（第一学期）、12（第二学期）。
  static const _knownTermCodes = {3, 12};

  /// 持久 envelope 的账号归属字段；缺失即旧格式记录，一律失效（fail closed）。
  static const _ownerKey = 'owner';

  _MemoryTermEntry? _memory;
  _InFlightTermRequest? _inflight;
  String? _persistedJson;
  bool _restored = false;

  Dio get _dio => ZhengfangAuth.instance.academicDio;

  /// 已识别的当前学期（仅内存缓存，同步读取，不触发网络）。
  ///
  /// 只返回当前已登录账号自身、且身份修订号仍匹配的缓存值：
  /// 登出 / 切账号后立即返回 null，不会展示旧 owner 的学期。
  ScheduleTermContext? get knownCurrentTerm {
    final identity = _currentIdentity();
    if (identity == null) {
      _memory = null;
      return null;
    }
    final entry = _memory;
    if (entry == null) return null;
    if (entry.owner != identity.owner || entry.revision != identity.revision) {
      _memory = null;
      return null;
    }
    if (DateTime.now().difference(entry.resolvedAt) >= _cacheTtl) {
      _memory = null;
      return null;
    }
    return entry.context;
  }

  /// 解析当前学年学期（兼容入口）：内存缓存 -> 未过期的持久缓存 -> 在线解析。
  ///
  /// 全部失败（未登录、身份不符、网络 / 页面结构异常、认证过期）时返回
  /// null。需要区分「认证过期」时改用 [resolveWithStatus]。
  Future<ScheduleTermContext?> resolve({
    String? studentId,
    bool forceRefresh = false,
  }) async {
    final resolution = await resolveWithStatus(
      studentId: studentId,
      forceRefresh: forceRefresh,
    );
    return resolution.context;
  }

  /// 解析当前学年学期并返回状态。
  ///
  /// - [CurrentTermResolution.context] 非空表示识别成功（缓存命中或在线解析）。
  /// - [CurrentTermResolution.authExpired] 为 true 表示教务明确返回登录态
  ///   失效（901 / 302 / 303 / 401 / 403 或 200 登录页），调用方应引导重新
  ///   登录；此时 context 为 null。
  /// - 未登录、显式 `studentId` 与当前已登录账号不一致、网络 / 页面结构
  ///   异常等一律返回 `context == null && authExpired == false`。
  ///
  /// 显式 `studentId` 与当前账号不一致时既不复用缓存也不发起请求；身份在
  /// await 边界变化后，迟到结果不会写入内存 / 持久缓存，也不会返回给新账号。
  Future<CurrentTermResolution> resolveWithStatus({
    String? studentId,
    bool forceRefresh = false,
  }) async {
    final identity = _currentIdentity();
    if (identity == null) return const CurrentTermResolution();

    final requested = studentId?.trim();
    if (requested != null &&
        requested.isNotEmpty &&
        requested != identity.owner) {
      return const CurrentTermResolution();
    }

    final owner = identity.owner;
    final revision = identity.revision;

    if (!forceRefresh) {
      final memory = _memoryCache(owner: owner, revision: revision);
      if (memory != null) return CurrentTermResolution(context: memory);

      final persisted = await _persistedCache(owner: owner, revision: revision);
      if (persisted != null) return CurrentTermResolution(context: persisted);
      // 读取持久缓存期间的 await 边界：身份变化后不再复用 / 发请求。
      if (!_isIdentityCurrent(owner: owner, revision: revision)) {
        return const CurrentTermResolution();
      }

      final existing = _inflight;
      if (existing != null &&
          existing.owner == owner &&
          existing.revision == revision) {
        return existing.future;
      }
    }

    final request = _InFlightTermRequest(
      owner: owner,
      revision: revision,
      future: _fetchCurrentTerm(owner: owner, revision: revision),
    );
    _inflight = request;
    unawaited(
      request.future.whenComplete(() {
        if (identical(_inflight, request)) _inflight = null;
      }),
    );
    return request.future;
  }

  ({String owner, int revision})? _currentIdentity() {
    final auth = ZhengfangAuth.instance;
    if (!auth.isLoggedIn) return null;
    final owner = auth.currentStudentId?.trim();
    if (owner == null || owner.isEmpty) return null;
    return (owner: owner, revision: auth.sessionRevision);
  }

  bool _isIdentityCurrent({required String owner, required int revision}) {
    final current = _currentIdentity();
    return current != null &&
        current.owner == owner &&
        current.revision == revision;
  }

  ScheduleTermContext? _memoryCache({
    required String owner,
    required int revision,
  }) {
    final entry = _memory;
    if (entry == null) return null;
    if (entry.owner != owner || entry.revision != revision) return null;
    if (DateTime.now().difference(entry.resolvedAt) >= _cacheTtl) return null;
    return entry.context;
  }

  Future<ScheduleTermContext?> _persistedCache({
    required String owner,
    required int revision,
  }) async {
    try {
      await _ensureRestored();
      if (!_isIdentityCurrent(owner: owner, revision: revision)) return null;
      final persisted = _fromPersisted(owner: owner);
      if (persisted == null) return null;
      if (DateTime.now().difference(persisted.resolvedAt) >= _cacheTtl) {
        return null;
      }
      _memory = _MemoryTermEntry(
        context: persisted.context,
        resolvedAt: persisted.resolvedAt.toLocal(),
        owner: owner,
        revision: revision,
      );
      return persisted.context;
    } catch (_) {
      // 缓存读取失败按未命中处理，不阻断在线解析。
      AppLogger.instance.debug('教务学期缓存读取失败，按未识别处理');
      return null;
    }
  }

  ({ScheduleTermContext context, DateTime resolvedAt})? _fromPersisted({
    required String owner,
  }) {
    // 由 [_ensureRestored] 预先解码到 [_persistedJson]。
    final raw = _persistedJson;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      // 无 owner 的旧格式记录与换号后的记录一律失效，不得跨账号复用。
      if (decoded[_ownerKey] != owner) return null;
      final context = ScheduleTermContext.fromJson(decoded);
      if (!_isValidContext(context)) return null;
      final resolvedAtMillis = decoded['resolvedAt'] as int?;
      if (resolvedAtMillis == null) return null;
      return (
        context: context,
        resolvedAt: DateTime.fromMillisecondsSinceEpoch(resolvedAtMillis),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureRestored() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    _persistedJson = prefs.getString(_storageKey);
    _restored = true;
  }

  Future<CurrentTermResolution> _fetchCurrentTerm({
    required String owner,
    required int revision,
  }) async {
    try {
      await DioClient.instance.ensureInitialized();
    } catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务学期解析初始化失败，回退日期推算',
        error: error,
      );
      return const CurrentTermResolution();
    }
    if (!_isIdentityCurrent(owner: owner, revision: revision)) {
      return const CurrentTermResolution();
    }

    try {
      final resp = await _dio.get<String>(
        ZhengfangAuth.instance.buildPortalUrl(
          '/kbcx/xskbcx_cxXskbcxIndex.html',
        ),
        queryParameters: {'gnmkdm': 'N2151', 'layout': 'default', 'su': owner},
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 1000,
          headers: {
            'Referer': ZhengfangAuth.instance.academicServiceUrl,
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );

      // await 边界：身份已变化时丢弃迟到响应，不落盘也不返回。
      if (!_isIdentityCurrent(owner: owner, revision: revision)) {
        return const CurrentTermResolution();
      }
      // 本域 GET 不走 guardRequest（不触发自动登录 / OCR），只识别过期状态。
      if (AcademicAuthGuard.isAuthExpiredResponse(resp)) {
        AppLogger.instance.debug(
          '教务学期解析跳过（登录态失效，HTTP ${resp.statusCode ?? 0}）',
        );
        return const CurrentTermResolution(authExpired: true);
      }
      final statusCode = resp.statusCode ?? 0;
      if (statusCode != 200) {
        AppLogger.instance.warn('教务学期解析失败（HTTP $statusCode），回退日期推算');
        return const CurrentTermResolution();
      }

      final context = parseCurrentTermFromIndexHtml(resp.data ?? '');
      if (context == null) {
        AppLogger.instance.warn('教务学期解析失败（页面结构变化），回退日期推算');
        return const CurrentTermResolution();
      }

      await _store(context: context, owner: owner, revision: revision);
      if (!_isIdentityCurrent(owner: owner, revision: revision)) {
        return const CurrentTermResolution();
      }
      AppLogger.instance.info('教务系统当前学期识别成功: ${context.key}');
      return CurrentTermResolution(context: context);
    } on DioException catch (error) {
      if (!_isIdentityCurrent(owner: owner, revision: revision)) {
        return const CurrentTermResolution();
      }
      final response = error.response;
      if (response != null &&
          AcademicAuthGuard.isAuthExpiredResponse(response)) {
        AppLogger.instance.debug('教务学期解析跳过（登录态失效）');
        return const CurrentTermResolution(authExpired: true);
      }
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务学期解析网络异常，回退日期推算',
        error: error,
      );
      return const CurrentTermResolution();
    } catch (error) {
      if (!_isIdentityCurrent(owner: owner, revision: revision)) {
        return const CurrentTermResolution();
      }
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务学期解析异常，回退日期推算',
        error: error,
      );
      return const CurrentTermResolution();
    }
  }

  Future<void> _store({
    required ScheduleTermContext context,
    required String owner,
    required int revision,
  }) async {
    final now = DateTime.now();
    if (!_isIdentityCurrent(owner: owner, revision: revision)) return;

    _memory = _MemoryTermEntry(
      context: context,
      resolvedAt: now,
      owner: owner,
      revision: revision,
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      // await 后复核身份：登出 / 切账号后的迟到结果不得覆盖持久缓存。
      if (!_isIdentityCurrent(owner: owner, revision: revision)) return;
      final encoded = jsonEncode({
        ...context.toJson(),
        'resolvedAt': now.millisecondsSinceEpoch,
        _ownerKey: owner,
      });
      _persistedJson = encoded;
      _restored = true;
      await prefs.setString(_storageKey, encoded);
    } catch (error) {
      // 持久化失败仅内存生效，不影响本次返回值。
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务学期缓存写入失败（仅内存生效）',
        error: error,
      );
    }
  }

  bool _isValidContext(ScheduleTermContext context) {
    final year = context.academicYear;
    if (year < 2000 || year > 2100) return false;
    return _knownTermCodes.contains(context.term);
  }

  /// 从课表首页 HTML 中提取当前学年学期（纯函数，便于单元测试）。
  ///
  /// 优先解析 `#xnm` / `#xqm` 下拉框中带 `selected` 的选项；
  /// 部分部署用 jQuery 赋值（`jQuery("#xnm").val("2026")`），作为次选。
  @visibleForTesting
  static ScheduleTermContext? parseCurrentTermFromIndexHtml(String html) {
    if (html.isEmpty) return null;

    final academicYear =
        _extractSelectedValue(html, 'xnm') ?? _extractJsVal(html, 'xnm');
    final term =
        _extractSelectedValue(html, 'xqm') ?? _extractJsVal(html, 'xqm');
    if (academicYear == null || term == null) return null;

    final year = int.tryParse(academicYear);
    final termCode = int.tryParse(term);
    if (year == null || termCode == null) return null;

    final context = ScheduleTermContext(academicYear: year, term: termCode);
    if (year < 2000 || year > 2100) return null;
    if (!_knownTermCodes.contains(termCode)) return null;
    return context;
  }

  /// 提取 `<select id="xxx">` 内带 `selected` 属性的 `<option>` 值。
  static String? _extractSelectedValue(String html, String selectId) {
    final blockPattern = RegExp(
      '<select[^>]*id\\s*=\\s*["\']?$selectId["\']?(?=[\\s>])[\\s\\S]*?</select>',
      caseSensitive: false,
    );
    final block = blockPattern.firstMatch(html)?.group(0);
    if (block == null) return null;

    final optionPattern = RegExp(r'<option\b[^>]*>', caseSensitive: false);
    final valuePattern = RegExp(
      r'\bvalue\s*=\s*[\x22\x27]?([^\x22\x27 >]+)',
      caseSensitive: false,
    );
    for (final match in optionPattern.allMatches(block)) {
      final tag = match.group(0)!;
      if (!RegExp(r'\bselected\b', caseSensitive: false).hasMatch(tag)) {
        continue;
      }
      final value = valuePattern.firstMatch(tag)?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// 兜底：提取 `$("#xxx").val("123")` / `jQuery("#xxx").val("123")` 赋值。
  static String? _extractJsVal(String html, String selectId) {
    final pattern = RegExp(
      '[\'"]?#$selectId[\'"]?\\s*\\)\\s*\\.val\\(\\s*[\'"](\\d+)[\'"]',
      caseSensitive: false,
    );
    return pattern.firstMatch(html)?.group(1);
  }

  /// 清空内存 / 持久缓存与在途请求标记（测试钩子）。
  ///
  /// 重置后允许重新从磁盘读取（便于测试预置持久 envelope）。
  @visibleForTesting
  Future<void> debugReset() async {
    _memory = null;
    _inflight = null;
    _persistedJson = null;
    _restored = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}

class _MemoryTermEntry {
  const _MemoryTermEntry({
    required this.context,
    required this.resolvedAt,
    required this.owner,
    required this.revision,
  });

  final ScheduleTermContext context;
  final DateTime resolvedAt;
  final String owner;
  final int revision;
}

class _InFlightTermRequest {
  const _InFlightTermRequest({
    required this.owner,
    required this.revision,
    required this.future,
  });

  final String owner;
  final int revision;
  final Future<CurrentTermResolution> future;
}
