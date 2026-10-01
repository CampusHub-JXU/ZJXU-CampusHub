import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/cas_routed_access.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/network/dio_client.dart';
import 'changxing_jiada_exceptions.dart';
import 'changxing_jiada_token_binding.dart';
import 'changxing_sso_urls.dart';

/// API 响应命中统一认证 / WebVPN 网关登录页（会话或网关 Cookie 缺失）。
class ChangxingApiLoginBounce implements Exception {
  const ChangxingApiLoginBounce();
}

/// 一次 API 选路结果（绑定发起时身份）。
class _RouteLease {
  const _RouteLease({
    required this.route,
    required this.owner,
    required this.revision,
    required this.at,
  });

  final CasRoute route;
  final String? owner;
  final int revision;
  final DateTime at;
}

class _RouteFlight {
  const _RouteFlight(this.owner, this.revision, this.future);

  final String? owner;
  final int revision;
  final Future<CasRoute> future;
}

/// 畅行嘉大 API 请求管线：选路缓存、token 头重定向白名单、响应分类、
/// 身份 / 绑定复核。由 [ChangxingJiadaService] 持有；登录流程
/// （`changxing_cas_login.dart`）与各业务接口共用同一份选路状态。
class ChangxingApiClient {
  ChangxingApiClient(this.tokenBinding);

  /// 直连形态的基址；实际请求一律经 [CasRoute.url] 按本次选路重建
  /// （校外自动改写为 WebVPN 代理地址），不读写全局 `ZhengfangAuth.mode`。
  static const baseUrl = 'https://zhx.zjxu.edu.cn/api';
  static const casLoginUrl = '$baseUrl/cas_wap_login';

  /// 选路缓存有效期：API 调用不必每次重验 CAS service / 网关会话。
  static const _routeTtl = Duration(seconds: 60);

  /// GET 手动跟随重定向的最大跳数。
  static const _maxApiRedirects = 5;

  /// token 的 owner 绑定 / 持久化（fail closed），见 [ChangxingTokenBinding]。
  final ChangxingTokenBinding tokenBinding;

  /// 最近一次成功的选路（绑定发起时身份，短期有效）。
  _RouteLease? _routeLease;

  /// 同身份并发 API 调用合并到同一次 prepare，避免重复建网关会话。
  _RouteFlight? _routeFlight;

  /// 本次选路已被完整链路验证：供后续 API 调用短期复用。
  void rememberRoute({
    required CasRoute route,
    required String? owner,
    required int revision,
  }) {
    _routeLease = _RouteLease(
      route: route,
      owner: owner,
      revision: revision,
      at: DateTime.now(),
    );
  }

  /// 丢弃选路缓存（下次重建网关会话）；不动在途 prepare。
  void invalidateRouteLease() {
    _routeLease = null;
  }

  void reset() {
    _routeLease = null;
    _routeFlight = null;
  }

  /// API 请求统一选项：不跟随重定向（登录 bounce 必须可见），2xx/3xx 交由
  /// [_jsonOrBounce] 分类，4xx/5xx 仍按原样抛 [DioException]。
  Options apiOptions({
    String? method,
    String? contentType,
    Map<String, String>? headers,
  }) => Options(
    method: method,
    contentType: contentType,
    headers: headers,
    responseType: ResponseType.json,
    followRedirects: false,
    validateStatus: (status) => status != null && status >= 200 && status < 400,
  );

  /// 把 API 响应解码为 JSON map；命中统一认证 / 网关登录页（302 或 200 HTML）
  /// 抛 [ChangxingApiLoginBounce]，其它非 JSON 响应抛 [ChangxingCasLoginException]。
  Map<String, dynamic> jsonOrBounce(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final location = response.headers.value('location') ?? '';
      final resolved = location.isEmpty
          ? ''
          : response.requestOptions.uri.resolve(location).toString();
      if (_isLoginBounceUrl(resolved)) throw const ChangxingApiLoginBounce();
      throw ChangxingCasLoginException('服务返回了意外的重定向，请稍后重试');
    }
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    final realUrl = response.realUri.toString();
    if (isZhengfangGatewayLoginUrl(realUrl) ||
        (data is String &&
            (isChangxingUnifiedAuthLoginFormResponse(realUrl, data) ||
                looksLikeUnifiedAuthLoginHtml(data)))) {
      throw const ChangxingApiLoginBounce();
    }
    if (data == null) return <String, dynamic>{};
    throw ChangxingCasLoginException('服务响应异常，请稍后重试');
  }

  /// Location / 最终 URL 是否为统一认证 / 网关登录页。WebVPN 下网关把 newca
  /// 登录页代理成 `/https/<enc>/cas/login`，先 [normalizeSsoRedirectUrl]
  /// 还原再判定（与 [_fetchTokenId] 一致）。
  bool _isLoginBounceUrl(String url) {
    if (url.isEmpty) return false;
    final normalized = normalizeChangxingSsoRedirectUrl(url);
    return isUnifiedAuthLoginEntryUrl(normalized) ||
        isZhengfangGatewayLoginUrl(normalized) ||
        isZhengfangGatewayLoginUrl(url);
  }

  /// 把 GET 重定向的下一跳映射到本次路由下允许的目标；不允许返回 null——
  /// 绝不把 `token` 头带到非畅行目标。判定同时校验 scheme / 端口 / 主机 / 路径：
  /// - 一律要求 https + 默认端口（拒绝 http 降级与替代端口）；
  /// - 直连：主机必须恰为 `zhx.zjxu.edu.cn`；
  /// - WebVPN：目标必须位于 zhx 的代理前缀（`route.url` 对 zhx 源产生的
  ///   `/https/<enc>/`）之下，其它代理前缀（别的站点 / 别的端口）一律拒绝；
  ///   出现直连 https zhx 地址时按路由改写回代理地址。
  Uri? _mapApiRedirect(CasRoute route, Uri current, Uri next) {
    if (next.scheme != 'https' || (next.hasPort && next.port != 443)) {
      return null;
    }
    final host = next.host.toLowerCase();
    if (!route.isWebVpn) {
      return host == _changxingHost ? next : null;
    }
    if (host == _changxingHost) {
      final mapped = Uri.tryParse(route.url('$next'));
      return mapped != null && _isChangxingWebVpnProxyUri(route, mapped)
          ? mapped
          : null;
    }
    return _isChangxingWebVpnProxyUri(route, next) ? next : null;
  }

  static const _changxingHost = 'zhx.zjxu.edu.cn';

  /// [uri] 是否位于 zhx（https，默认端口）的 WebVPN 代理前缀之下。
  bool _isChangxingWebVpnProxyUri(CasRoute route, Uri uri) {
    if (uri.scheme != 'https' || (uri.hasPort && uri.port != 443)) {
      return false;
    }
    final expected = Uri.tryParse(route.url('https://$_changxingHost/'));
    if (expected == null ||
        expected.host.isEmpty ||
        expected.host.toLowerCase() == _changxingHost) {
      return false; // 没有代理映射：无法证明前缀，fail closed。
    }
    if (uri.host.toLowerCase() != expected.host.toLowerCase()) return false;
    final prefix = expected.pathSegments.where((s) => s.isNotEmpty).toList();
    final segments = uri.pathSegments;
    if (prefix.isEmpty || segments.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (segments[i] != prefix[i]) return false;
    }
    return true;
  }

  /// 发送 API 请求。GET 最多手动跟随 [_maxApiRedirects] 跳（逐跳做登录页
  /// bounce 检测与路由映射，`token` 头只随可信主机发出）；POST / 上传是
  /// 非幂等请求，不跟随、不重试。传输层失败时丢弃选路缓存，下次重新选路。
  Future<Response<dynamic>> sendApi(
    CasRoute route,
    Uri uri, {
    required String method,
    Object? data,
    String? contentType,
    Map<String, String>? headers,
  }) async {
    final follow = method.toUpperCase() == 'GET';
    var current = uri;
    try {
      for (var hop = 0; ; hop++) {
        final response = await DioClient.instance.unifiedAuthDio
            .requestUri<dynamic>(
              current,
              data: data,
              options: apiOptions(
                method: method,
                contentType: contentType,
                headers: headers,
              ),
            );
        final status = response.statusCode ?? 0;
        final location = response.headers.value('location') ?? '';
        if (!follow ||
            status < 300 ||
            status >= 400 ||
            location.isEmpty ||
            hop >= _maxApiRedirects) {
          return response;
        }
        final next = current.resolve(location);
        // 登录页 bounce 交给 _jsonOrBounce 归类；不可信目标同样原样返回。
        if (_isLoginBounceUrl('$next')) return response;
        final mapped = _mapApiRedirect(route, current, next);
        if (mapped == null) return response;
        current = mapped;
      }
    } on DioException catch (e) {
      _dropRouteOnTransportFailure(e);
      rethrow;
    }
  }

  /// 连接 / 超时类失败（例如离开校园 Wi-Fi）：丢弃选路缓存与在途 prepare，
  /// 下次调用重新选路。HTTP 状态类错误不动路由。
  void _dropRouteOnTransportFailure(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        _routeLease = null;
        _routeFlight = null;
      default:
        break;
    }
  }

  /// 取本次 API 调用的路由：同身份短期复用，并发合并为一次 prepare。
  /// [CasAuthExpiredException] / [TimeoutException] 由调用方映射成业务异常。
  Future<CasRoute> _routeFor(String? owner, int revision) {
    final lease = _routeLease;
    if (lease != null &&
        lease.owner == owner &&
        lease.revision == revision &&
        DateTime.now().difference(lease.at) < _routeTtl) {
      return Future.value(lease.route);
    }
    final flight = _routeFlight;
    if (flight != null &&
        flight.owner == owner &&
        flight.revision == revision) {
      return flight.future;
    }
    final future = CasRoutedAccess.prepare(
      service: CasService.changxing,
      targetUrl: casLoginUrl,
    );
    final created = _RouteFlight(owner, revision, future);
    _routeFlight = created;
    return future
        .then((route) {
          if (owner == null || tokenBinding.isCurrent(owner, revision)) {
            _routeLease = _RouteLease(
              route: route,
              owner: owner,
              revision: revision,
              at: DateTime.now(),
            );
          }
          return route;
        })
        .whenComplete(() {
          if (identical(_routeFlight, created)) _routeFlight = null;
        });
  }

  /// API 调用前选路；失败映射为业务异常（不清全局会话、不 markLoggedOut）。
  Future<CasRoute> routeForApi(String? owner, int revision) async {
    try {
      return await _routeFor(owner, revision);
    } on CasAuthExpiredException {
      throw ChangxingAuthExpiredException();
    } on TimeoutException catch (e) {
      throw ChangxingCasLoginException(e.message ?? '服务暂时无法连接，请稍后重试');
    }
  }

  Future<Map<String, dynamic>> get(
    String path, {
    bool requiresToken = true,
    Map<String, String>? query,
  }) async {
    return _request(
      path: path,
      method: 'GET',
      requiresToken: requiresToken,
      query: query,
    );
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    bool requiresToken = true,
  }) async {
    return _request(
      path: path,
      method: 'POST',
      requiresToken: requiresToken,
      data: body,
      contentType: Headers.jsonContentType,
    );
  }

  Future<Map<String, dynamic>> postForm(
    String path,
    Map<String, dynamic> body, {
    bool requiresToken = true,
  }) async {
    return _request(
      path: path,
      method: 'POST',
      requiresToken: requiresToken,
      data: body,
      contentType: Headers.formUrlEncodedContentType,
    );
  }

  Future<Map<String, dynamic>> _request({
    required String path,
    required String method,
    required bool requiresToken,
    Object? data,
    String? contentType,
    Map<String, String>? query,
  }) async {
    // 调用方发起时的身份：必须在任何 await 之前捕获。A 发起的请求（含表单
    // payload）在 ensureInitialized / restoreSession 期间身份切到 B 之后，
    // 绝不允许以 B 的 token 继续发出。
    final entryOwner = tokenBinding.currentOwner;
    final entryRevision = UnifiedAuthService.instance.sessionRevision;
    final identityCaptured = requiresToken && entryOwner != null;

    void ensureEntryIdentityCurrent() {
      if (!identityCaptured) return;
      if (tokenBinding.isCurrent(entryOwner, entryRevision)) return;
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    if (requiresToken && entryOwner == null) {
      // 没有可验证的调用方身份：与无 token 路径同分类，直接视为会话失效。
      throw ChangxingAuthExpiredException();
    }

    await DioClient.instance.ensureInitialized();
    ensureEntryIdentityCurrent();

    await tokenBinding.restore();
    ensureEntryIdentityCurrent();

    final token = tokenBinding.currentToken;
    if (requiresToken && token == null) {
      // 无 token / token 归属与当前 CAS 身份不一致 / 绑定 revision 已漂移
      // 一律视为没有可用会话（分类保持原样）。
      throw ChangxingAuthExpiredException();
    }
    if (identityCaptured &&
        !tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      // restore 恢复出来的绑定不属于调用方身份（恢复期间换号）。
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    // 选路（首次 / 过期时会确认 CAS service 并补 WebVPN 网关会话）；选路
    // 期间身份变化则放弃，绝不把 A 的 payload 经 B 的路由 / token 发出。
    final route = await routeForApi(entryOwner, entryRevision);
    ensureEntryIdentityCurrent();
    if (identityCaptured &&
        !tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final uri = Uri.parse(
      route.url(
        Uri.parse('$baseUrl$path').replace(queryParameters: query).toString(),
      ),
    );
    final headers = <String, String>{};
    if (requiresToken) {
      headers['token'] = token!;
    }

    // 发送前最后一次复核（URI / headers 构造是同步代码，无 await 间隙）：
    // 身份或绑定任一变化都不得把 A 的 payload 以 B 的 token 发出。
    ensureEntryIdentityCurrent();
    if (identityCaptured &&
        !tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final response = await sendApi(
      route,
      uri,
      method: method,
      data: data,
      contentType: contentType,
      headers: headers,
    );

    final Map<String, dynamic> json;
    try {
      json = jsonOrBounce(response);
    } on ChangxingApiLoginBounce {
      // 登录页 bounce：只丢弃选路缓存（下次重建网关会话），不清全局 CAS
      // 会话、不 markLoggedOut。
      _routeLease = null;
      throw ChangxingAuthExpiredException();
    }
    // 迟到结果守卫：等待期间身份 / token 绑定已变化，响应不属于当前会话，
    // 不得把旧身份数据返回给新会话；此后的 500001 也不得清掉新 token。
    if (identityCaptured &&
        (!tokenBinding.isCurrent(entryOwner, entryRevision) ||
            !tokenBinding.isBindingCurrent(entryOwner, entryRevision))) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    final code = extractCode(json);
    if (code == '500001') {
      if (identityCaptured) {
        await tokenBinding.clearIfCurrent(entryOwner, entryRevision);
      }
      throw ChangxingAuthExpiredException(
        extractMessage(json, fallback: '令牌错误，请重新登录'),
      );
    }
    return json;
  }

  String extractCode(Map<String, dynamic> json) {
    final data = extractDataMap(json);
    return data['code']?.toString() ?? json['code']?.toString() ?? '';
  }

  void ensureSuccess(Map<String, dynamic> json, {required String fallback}) {
    final code = extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        extractMessage(json, fallback: fallback),
      );
    }
  }

  String extractMessage(
    Map<String, dynamic> json, {
    required String fallback,
  }) {
    final data = extractDataMap(json);
    return data['msg']?.toString() ??
        data['errmsg']?.toString() ??
        json['msg']?.toString() ??
        fallback;
  }

  Map<String, dynamic> extractDataMap(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is Map<String, dynamic>) return data;
    return <String, dynamic>{};
  }
}
