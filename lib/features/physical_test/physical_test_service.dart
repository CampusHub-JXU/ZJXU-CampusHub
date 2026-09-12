import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/connect_mode_resolver.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'physical_test_html_parser.dart';
import 'physical_test_model.dart';

/// 体测成绩原生数据服务。
///
/// 站点是学校「学生服务平台」`http://jkjy.zjxu.edu.cn`（校内直连，校外经
/// WebVPN 代理）。查询协议 `/spQuery`：
/// * 当前成绩：`POST /spQuery`，body `method=healthscore&stuNo&schoolid`；
/// * 历年列表：`POST /spQuery?method=scoreTotal`，body `stuNo&schoolid`；
/// * 历年明细：`GET /spQuery?method=scoreDetails&schoolid&stuNo&year&term`。
///
/// 身份（hidden `stuNo` / `schoolid`）只从菜单页 `/weixin/main.jsp` 读取，
/// 不硬编码学号或学校号。CAS service 是 `/weixin/login.jsp`（[CasService]
/// 注册项）；菜单页与查询页都是资源 URL，经 [CasAuthBroker.getResource]
/// 逐跳兑换 ticket，绝不把资源 URL 当 service 传给 [CasSession.ensure]。
class PhysicalTestService {
  PhysicalTestService._() {
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
  }

  static final PhysicalTestService instance = PhysicalTestService._();

  /// 未接入时代的占位文案（页面空态仍引用；生产路径不再返回）。
  static const unavailableMessage = '体测成绩查询尚未接入';

  static const siteOrigin = 'http://jkjy.zjxu.edu.cn';
  static const _menuPath = '/weixin/main.jsp';
  static const _queryPath = '/spQuery';
  static const _yearListPath = '$_queryPath?method=$_methodYearList';
  static const _methodCurrent = 'healthscore';
  static const _methodYearList = 'scoreTotal';
  static const _methodDetail = 'scoreDetails';
  static const _siteHomeUrl = '$siteOrigin$_menuPath';

  /// 身份纪元：统一认证登录 / 登出 / 换号 / 会话恢复都递增，异步期间
  /// 发生变化的旧操作结果一律丢弃。
  int _authEpoch = 0;

  PhysicalTestSnapshot? _cachedSnapshot;
  _SessionGuard? _cachedGuard;

  /// 测试注入；生产为空时走真实抓取路径。
  @visibleForTesting
  Future<PhysicalTestSnapshot> Function()? debugSnapshotFetcher;

  Dio? _debugDio;

  @visibleForTesting
  void debugSetDio(Dio? dio) => _debugDio = dio;

  @visibleForTesting
  PhysicalTestSnapshot? get debugCachedSnapshot => _cachedSnapshot;

  void _onUnifiedAuthChanged() {
    _authEpoch++;
    _cachedSnapshot = null;
    _cachedGuard = null;
  }

  /// 拉取当前及可用历年成绩；同一会话未过期时命中内存缓存。
  ///
  /// 认证失败（无本地会话 / 明确失效 / bounce 重试后仍登录页）抛
  /// [CasAuthExpiredException]；网络未知原样抛出且不清理全局会话；异步
  /// 期间账号切换 / 登出的迟到结果不会返回。
  Future<PhysicalTestSnapshot> fetchSnapshot({
    bool forceRefresh = false,
  }) async {
    final fetcher = debugSnapshotFetcher;
    if (fetcher != null) return fetcher();

    final entryGuard = _captureGuard();
    if (!forceRefresh) {
      final cached = _readCache(entryGuard);
      if (cached != null) return cached;
    }
    return _fetchRemote();
  }

  Future<PhysicalTestSnapshot> _fetchRemote() async {
    // 先确认统一认证会话（未登录立即失败，不初始化网络层）。
    final mode = await _prepareSession();
    if (_debugDio == null) {
      await DioClient.instance.ensureInitialized();
    }
    final guard = _captureGuard();
    _ensureGuard(guard);

    final identity = await _fetchIdentity(guard, mode);

    final currentRecord = await _fetchCurrentRecord(guard, mode, identity);

    final yearEntries = await _fetchYearEntries(guard, mode, identity);

    final records = await _assembleRecords(
      guard: guard,
      mode: mode,
      identity: identity,
      currentRecord: currentRecord,
      yearEntries: yearEntries,
    );

    _ensureGuard(guard);
    final snapshot = PhysicalTestSnapshot(
      records: records,
      updatedAt: DateTime.now(),
    );
    _cachedSnapshot = snapshot;
    _cachedGuard = guard;
    AppLogger.instance.network(
      LogLevel.info,
      '体测成绩加载成功，共 ${records.length} 条学年记录',
    );
    return snapshot;
  }

  /// 会话与选路：CAS service 校验 → 直连/WebVPN 判定 → 必要时补网关会话。
  Future<ZhengfangMode> _prepareSession() async {
    final sessionStatus = await CasSession.ensure(
      CasService.physicalTest.serviceUrl,
      syncWebViewCookies: false,
    );
    if (sessionStatus == CasSessionStatus.inactive) {
      throw const CasAuthExpiredException();
    }
    if (sessionStatus == CasSessionStatus.unknown) {
      throw TimeoutException('统一认证暂时无法连接，请稍后重试');
    }

    final mode = await ConnectModeResolver.instance.resolve(
      targetUrl: _siteHomeUrl,
    );
    if (mode == null) {
      throw TimeoutException('体测服务暂时无法连接，请检查网络后重试');
    }
    if (mode == ZhengfangMode.webVpn) {
      final gateway = await ZhengfangAuth.instance
          .ensureWebVpnGatewaySessionResult(
            syncWebViewCookies: false,
            targetUrl: _siteHomeUrl,
          );
      if (gateway.ready == false) throw const CasAuthExpiredException();
      if (gateway.ready == null) {
        throw TimeoutException('体测服务暂时无法连接，请检查网络后重试');
      }
    }
    return mode;
  }

  /// 业务 bounce 后唯一一次恢复：重验 CAS service（含 WebVPN 网关）后重试。
  /// 明确失败抛 [CasAuthExpiredException]，但绝不调用 `markLoggedOut`。
  Future<void> _recoverSession(_SessionGuard guard, ZhengfangMode mode) async {
    if (mode == ZhengfangMode.webVpn) {
      final gateway = await ZhengfangAuth.instance
          .ensureWebVpnGatewaySessionResult(
            syncWebViewCookies: false,
            targetUrl: _siteHomeUrl,
          );
      if (gateway.ready == false) throw const CasAuthExpiredException();
      if (gateway.ready == null) {
        throw TimeoutException('体测服务暂时无法连接，请检查网络后重试');
      }
    }

    final sessionStatus = await CasSession.ensure(
      CasService.physicalTest.serviceUrl,
      restoreFromStore: false,
      syncWebViewCookies: false,
    );
    if (sessionStatus == CasSessionStatus.inactive) {
      throw const CasAuthExpiredException();
    }
    if (sessionStatus == CasSessionStatus.unknown) {
      throw TimeoutException('统一认证暂时无法连接，请稍后重试');
    }
    _ensureGuard(guard);
  }

  /// 有界认证重试：第一次命中登录页/登录跳转时恢复会话并重试一次；
  /// 仍然 bounce 则抛 [CasAuthExpiredException]。
  Future<Response<List<int>>> _withBoundedAuthRetry({
    required _SessionGuard guard,
    required ZhengfangMode mode,
    required Future<Response<List<int>>> Function() send,
  }) async {
    Future<Response<List<int>>> attempt() async {
      final response = await send();
      if (_looksLikeAuthBounce(response)) {
        throw const CasAuthExpiredException();
      }
      return response;
    }

    try {
      return await attempt();
    } on CasAuthExpiredException {
      _ensureGuard(guard);
      await _recoverSession(guard, mode);
      return attempt();
    }
  }

  Future<PhysicalTestIdentity> _fetchIdentity(
    _SessionGuard guard,
    ZhengfangMode mode,
  ) async {
    final response = await _getResource(guard, mode, _menuPath);
    final identity = parsePhysicalTestIdentity(_decodeHtml(response));
    _ensureGuard(guard);
    return identity;
  }

  /// 当前成绩；学校侧季节性「暂未开放查询」时返回 null（中性空 current），
  /// 由调用方继续抓取历年成绩，绝不让当前页空态阻断历史查询。
  Future<PhysicalTestRecord?> _fetchCurrentRecord(
    _SessionGuard guard,
    ZhengfangMode mode,
    PhysicalTestIdentity identity,
  ) async {
    final response = await _postQuery(
      guard: guard,
      mode: mode,
      pathAndQuery: _queryPath,
      body: {
        'method': _methodCurrent,
        'stuNo': identity.stuNo,
        'schoolid': identity.schoolid,
      },
    );
    final record = tryParsePhysicalTestScorePage(_decodeHtml(response));
    _ensureGuard(guard);
    return record;
  }

  Future<List<PhysicalTestYearEntry>> _fetchYearEntries(
    _SessionGuard guard,
    ZhengfangMode mode,
    PhysicalTestIdentity identity,
  ) async {
    final response = await _postQuery(
      guard: guard,
      mode: mode,
      pathAndQuery: _yearListPath,
      body: {'stuNo': identity.stuNo, 'schoolid': identity.schoolid},
    );
    final entries = parsePhysicalTestYearList(_decodeHtml(response));
    _ensureGuard(guard);
    return entries;
  }

  /// 当前成绩 + 历年明细；当前学期已由 `healthscore` 覆盖，不再重复抓取。
  /// `healthscore` 未开放（current 为 null）时仍继续抓取历年成绩。
  Future<List<PhysicalTestRecord>> _assembleRecords({
    required _SessionGuard guard,
    required ZhengfangMode mode,
    required PhysicalTestIdentity identity,
    required PhysicalTestRecord? currentRecord,
    required List<PhysicalTestYearEntry> yearEntries,
  }) async {
    final records = <PhysicalTestRecord>[];
    final seenYears = <String>{};
    if (currentRecord != null) {
      records.add(currentRecord);
      if (currentRecord.academicYear.isNotEmpty) {
        seenYears.add(currentRecord.academicYear);
      }
    }

    for (final entry in yearEntries) {
      _ensureGuard(guard);
      if (entry.academicYear.isEmpty || !seenYears.add(entry.academicYear)) {
        continue;
      }

      final validated = validatePhysicalTestDetailLink(
        href: entry.detailHref,
        stuNo: identity.stuNo,
        schoolid: identity.schoolid,
      );
      if (validated == null) {
        // 链接不在白名单：不跟随，保留列表页给出的学年汇总。
        records.add(
          PhysicalTestRecord(
            academicYear: entry.academicYear,
            totalScore: entry.totalScore,
            grade: entry.grade,
          ),
        );
        continue;
      }

      // 行内「学年」字段可信度高于链接参数：优先用它重建 year/term，
      // 白名单校验过的 href 参数只作兜底。
      final detail = _trustedDetailYearTerm(entry.academicYear) ?? validated;

      final detailPath = Uri(
        path: _queryPath,
        queryParameters: {
          'method': _methodDetail,
          'schoolid': identity.schoolid,
          'stuNo': identity.stuNo,
          'year': detail.year,
          'term': detail.term,
        },
      ).toString();
      final response = await _getResource(guard, mode, detailPath);
      final parsed = parsePhysicalTestScorePage(_decodeHtml(response));
      _ensureGuard(guard);
      records.add(
        PhysicalTestRecord(
          academicYear: parsed.academicYear.isEmpty
              ? entry.academicYear
              : parsed.academicYear,
          totalScore: parsed.totalScore.isEmpty
              ? entry.totalScore
              : parsed.totalScore,
          grade: parsed.grade.isEmpty ? entry.grade : parsed.grade,
          items: parsed.items,
        ),
      );
    }

    return List.unmodifiable(records);
  }

  /// 校验历年链接并返回重建参数。
  ///
  /// 白名单：源站同 origin 的 `/spQuery`，或同一 jkjy 站点的 WebVPN 代理
  /// 路径 `/http/<jkjy host hash>/spQuery`（真机抓包中代理页面输出的是这种
  /// 相对链接）；method 必须是 `scoreDetails`，学号 / 学校号必须与菜单身份
  /// 一致，year / term 必须非空且格式合法。
  ///
  /// 返回值仅用于重建 URL，绝不跟随原始 href；调用方应优先使用历年行的
  /// 可信学年字段（见 [_trustedDetailYearTerm]）重建。
  @visibleForTesting
  static ({String year, String term})? validatePhysicalTestDetailLink({
    required String href,
    required String stuNo,
    required String schoolid,
  }) {
    final raw = href.trim();
    if (raw.isEmpty) return null;
    try {
      for (final resolved in _detailLinkCandidates(raw)) {
        final detail = _validatedDetailLink(
          resolved,
          stuNo: stuNo,
          schoolid: schoolid,
        );
        if (detail != null) return detail;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// 直连页面的相对链接以源站为基准；代理页面的相对链接以 WebVPN 网关为基准。
  static Iterable<Uri> _detailLinkCandidates(String raw) sync* {
    yield Uri.parse(siteOrigin).resolve(raw);
    yield Uri.parse(buildResourceUrl(_queryPath, ZhengfangMode.webVpn))
        .resolve(raw);
  }

  static ({String year, String term})? _validatedDetailLink(
    Uri resolved, {
    required String stuNo,
    required String schoolid,
  }) {
    if (!_isAllowedDetailOrigin(resolved)) return null;
    final parameters = _rawQueryParameters(resolved);
    if (parameters['method'] != _methodDetail) return null;
    if (parameters['stuNo'] != stuNo) return null;
    if (parameters['schoolid'] != schoolid) return null;
    final year = parameters['year']?.trim() ?? '';
    final term = parameters['term']?.trim() ?? '';
    if (!_detailYearPattern.hasMatch(year)) return null;
    if (!_detailTermPattern.hasMatch(term)) return null;
    return (year: year, term: term);
  }

  /// 只接受源站 `/spQuery`，或本 App 为 jkjy 重建的 WebVPN 代理路径；
  /// 其他主机 / 路径（含 userinfo 伪装的跨域形态）一律拒绝。
  static bool _isAllowedDetailOrigin(Uri uri) {
    if (uri.userInfo.isNotEmpty) return false;
    final site = Uri.parse(siteOrigin);
    if (uri.scheme == site.scheme &&
        uri.host == site.host &&
        uri.port == site.port &&
        uri.path == _queryPath) {
      return true;
    }
    final proxy = Uri.parse(buildResourceUrl(_queryPath, ZhengfangMode.webVpn));
    return uri.scheme == proxy.scheme &&
        uri.host == proxy.host &&
        uri.port == proxy.port &&
        uri.path == proxy.path;
  }

  static final _detailYearPattern = RegExp(r'^\d{4}-\d{4}$');
  static final _detailTermPattern = RegExp(r'^\d+$');
  static final _academicYearDetailPattern = RegExp(r'^(\d{4}-\d{4})-(\d+)$');

  /// 历年行「学年」字段形如 `2025-2026-1`；解析出的 year/term 可信度高于
  /// href 参数。格式不含学期（如 `2025-2026`）时返回 null，由调用方回退。
  static ({String year, String term})? _trustedDetailYearTerm(
    String academicYear,
  ) {
    final match = _academicYearDetailPattern.firstMatch(academicYear.trim());
    if (match == null) return null;
    return (year: match.group(1)!, term: match.group(2)!);
  }

  /// 手写 query 解析：`Uri.decodeComponent` 不把 `+` 当空格，base64 学号
  /// （可能含 `+`）按原文比较。
  static Map<String, String> _rawQueryParameters(Uri uri) {
    final result = <String, String>{};
    for (final part in uri.query.split('&')) {
      if (part.isEmpty) continue;
      final separator = part.indexOf('=');
      final rawKey = separator < 0 ? part : part.substring(0, separator);
      final rawValue = separator < 0 ? '' : part.substring(separator + 1);
      final key = Uri.decodeComponent(rawKey);
      if (result.containsKey(key)) continue;
      result[key] = Uri.decodeComponent(rawValue);
    }
    return result;
  }

  Future<Response<List<int>>> _getResource(
    _SessionGuard guard,
    ZhengfangMode mode,
    String pathAndQuery,
  ) {
    final url = buildResourceUrl(pathAndQuery, mode);
    return _withBoundedAuthRetry(
      guard: guard,
      mode: mode,
      send: () => CasAuthBroker.getResource(url, dio: _debugDio),
    );
  }

  Future<Response<List<int>>> _postQuery({
    required _SessionGuard guard,
    required ZhengfangMode mode,
    required String pathAndQuery,
    required Map<String, String> body,
  }) {
    final url = Uri.parse(buildResourceUrl(pathAndQuery, mode));
    final dio = _debugDio ?? DioClient.instance.unifiedAuthDio;
    return _withBoundedAuthRetry(
      guard: guard,
      mode: mode,
      send: () => dio.postUri<List<int>>(
        url,
        data: body,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      ),
    );
  }

  /// 直连用业务 origin；WebVPN 模式经已登记的 host 映射改写到网关代理前缀。
  @visibleForTesting
  static String buildResourceUrl(String pathAndQuery, ZhengfangMode mode) {
    final direct = '$siteOrigin$pathAndQuery';
    if (mode == ZhengfangMode.webVpn) {
      return ZhengfangAuth.instance.buildWebVpnProxyUrl(direct);
    }
    return direct;
  }

  String _decodeHtml(Response<List<int>> response) {
    final data = response.data;
    if (data == null || data.isEmpty) {
      throw StateError('体测服务响应为空');
    }
    return utf8.decode(data, allowMalformed: true);
  }

  bool _looksLikeAuthBounce(Response<List<int>> response) {
    final data = response.data;
    return CasAuthBroker.isCasLoginExchange(
      realUrl: response.realUri.toString(),
      statusCode: response.statusCode,
      location: response.headers.value('location'),
      requestUri: response.requestOptions.uri,
      html: data == null || data.isEmpty
          ? null
          : utf8.decode(data, allowMalformed: true),
    );
  }

  _SessionGuard _captureGuard() =>
      _SessionGuard(UnifiedAuthService.instance.currentAccount, _authEpoch);

  void _ensureGuard(_SessionGuard guard) {
    final auth = UnifiedAuthService.instance;
    if (guard.epoch != _authEpoch ||
        guard.account != auth.currentAccount ||
        !auth.isLoggedIn) {
      throw StateError('统一认证会话已变化，请重试');
    }
  }

  PhysicalTestSnapshot? _readCache(_SessionGuard guard) {
    final cached = _cachedSnapshot;
    final cachedGuard = _cachedGuard;
    if (cached == null || cachedGuard == null) return null;
    if (cachedGuard.account != guard.account ||
        cachedGuard.epoch != guard.epoch) {
      return null;
    }
    return cached;
  }

  @visibleForTesting
  void debugReset() {
    debugSnapshotFetcher = null;
    _debugDio = null;
    _cachedSnapshot = null;
    _cachedGuard = null;
    _authEpoch = 0;
  }
}

/// 一次抓取操作开始时固定的身份与纪元。
class _SessionGuard {
  const _SessionGuard(this.account, this.epoch);

  final String? account;
  final int epoch;
}
