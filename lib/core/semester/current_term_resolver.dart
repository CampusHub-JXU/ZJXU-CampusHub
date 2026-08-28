import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/zhengfang_auth.dart';
import '../logging/app_logger.dart';
import '../network/dio_client.dart';
import 'schedule_term_context.dart';

/// 从教务系统解析真实的当前学年学期。
///
/// 课表查询首页 `/kbcx/xskbcx_cxXskbcxIndex.html` 的 `#xnm` / `#xqm`
/// 下拉框中带 `selected` 的选项，即教务系统认定的当前学年学期。
/// 解析失败（未登录、网络异常、页面结构变化）时返回 null，
/// 由调用方回退到 [ScheduleTermContext.current] 的日期推算。
class CurrentTermResolver {
  CurrentTermResolver._();

  static final CurrentTermResolver instance = CurrentTermResolver._();

  static const _storageKey = 'zjxu_current_term_context_v1';
  static const _cacheTtl = Duration(hours: 12);

  /// 学期代码只接受正方约定值：3（第一学期）、12（第二学期）。
  static const _knownTermCodes = {3, 12};

  ScheduleTermContext? _cached;
  DateTime? _cachedAt;
  Future<ScheduleTermContext?>? _inflight;
  bool _restored = false;

  Dio get _dio => ZhengfangAuth.instance.academicDio;

  /// 已识别的当前学期（仅内存缓存，同步读取，不触发网络）。
  /// 供无法异步等待的场景（如首页恢复状态）使用；null 表示尚未识别。
  ScheduleTermContext? get knownCurrentTerm => _memoryCache(DateTime.now());

  /// 解析当前学年学期：内存缓存 -> 未过期的持久缓存 -> 在线解析。
  /// 全部失败时返回 null。
  Future<ScheduleTermContext?> resolve({
    String? studentId,
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh) {
      final memory = _memoryCache(now);
      if (memory != null) return memory;
      final persisted = await _persistedCache(now);
      if (persisted != null) return persisted;
    }

    final resolvedId =
        studentId?.trim() ??
        ZhengfangAuth.instance.currentStudentId?.trim() ??
        '';
    if (resolvedId.isEmpty || !ZhengfangAuth.instance.isLoggedIn) {
      return null;
    }

    final existing = forceRefresh ? null : _inflight;
    final future = existing ?? _fetchCurrentTerm(resolvedId);
    if (existing == null) {
      _inflight = future;
      unawaited(
        future.whenComplete(() {
          if (identical(_inflight, future)) _inflight = null;
        }),
      );
    }
    return future;
  }

  ScheduleTermContext? _memoryCache(DateTime now) {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (cached == null || cachedAt == null) return null;
    if (now.difference(cachedAt) >= _cacheTtl) return null;
    return cached;
  }

  Future<ScheduleTermContext?> _persistedCache(DateTime now) async {
    await _ensureRestored();
    final persisted = _fromPersisted();
    if (persisted == null) return null;
    if (now.difference(persisted.resolvedAt) >= _cacheTtl) return null;
    _cached = persisted.context;
    _cachedAt = persisted.resolvedAt.toLocal();
    return persisted.context;
  }

  ({ScheduleTermContext context, DateTime resolvedAt})? _fromPersisted() {
    // 由 [_ensureRestored] 预先解码到 [_persistedJson]。
    final raw = _persistedJson;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
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

  String? _persistedJson;

  Future<void> _ensureRestored() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    _persistedJson = prefs.getString(_storageKey);
    _restored = true;
  }

  Future<ScheduleTermContext?> _fetchCurrentTerm(String studentId) async {
    await DioClient.instance.ensureInitialized();
    try {
      final resp = await _dio.get<String>(
        ZhengfangAuth.instance.buildPortalUrl(
          '/kbcx/xskbcx_cxXskbcxIndex.html',
        ),
        queryParameters: {
          'gnmkdm': 'N2151',
          'layout': 'default',
          'su': studentId,
        },
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 1000,
          headers: {
            'Referer': ZhengfangAuth.instance.academicServiceUrl,
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );

      final statusCode = resp.statusCode ?? 0;
      if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
        AppLogger.instance.debug('教务学期解析跳过（未登录或会话失效，HTTP $statusCode）');
        return null;
      }
      if (statusCode != 200) {
        AppLogger.instance.warn('教务学期解析失败（HTTP $statusCode），回退日期推算');
        return null;
      }

      final context = parseCurrentTermFromIndexHtml(resp.data ?? '');
      if (context != null) {
        await _store(context);
        AppLogger.instance.info('教务系统当前学期识别成功: ${context.key}');
      } else {
        AppLogger.instance.warn('教务学期解析失败（页面结构变化），回退日期推算');
      }
      return context;
    } on DioException catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务学期解析网络异常，回退日期推算',
        error: error,
      );
      return null;
    } catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务学期解析异常，回退日期推算',
        error: error,
      );
      return null;
    }
  }

  Future<void> _store(ScheduleTermContext context) async {
    final now = DateTime.now();
    _cached = context;
    _cachedAt = now;

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode({
      ...context.toJson(),
      'resolvedAt': now.millisecondsSinceEpoch,
    });
    _persistedJson = encoded;
    _restored = true;
    await prefs.setString(_storageKey, encoded);
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

  @visibleForTesting
  Future<void> debugReset() async {
    _cached = null;
    _cachedAt = null;
    _inflight = null;
    _persistedJson = null;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
